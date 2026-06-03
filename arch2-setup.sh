#!/bin/bash
# =============================================================
# arch2-setup.sh - Cafe ECS Fargate Setup
# =============================================================
# Arquitectura:
#   /              -> cafe-node-web-app (Node.js, proveedores, ruta raiz)
#   /web*          -> cafe-static-web  (nginx, web estatica bakeada)
#   /images*       -> cafe-static-web  (nginx, imagenes referenciadas con ruta absoluta)
#   /products*     -> cafe-products-api (Flask + DynamoDB)
#   /create_report*-> cafe-report-service (Flask + Aurora + S3 + SNS)
#   /bean_products*-> cafe-report-service
#
# Cognito callback -> /web/callback.html (servido por nginx)
# Cognito usa HTTPS del ALB (certificado autofirmado importado en ACM).
# No se usa S3 para la web estatica.
#
# Configuracion previa:
#   1. Tener /resources y el .yaml en el mismo nivel que este script
#   2. export EMAIL="tu@email.com"
#   3. chmod +x arch2-setup.sh && ./arch2-setup.sh
# =============================================================
set -e

echo "============================================="
echo " Cafe ECS Fargate - Setup"
echo "============================================="

STACK_NAME="arch2"
REGION="us-east-1"
MYPASS="coffee_beans_for_all"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCES_DIR="$SCRIPT_DIR/resources"

# VPC y subnet se obtienen automaticamente desde los metadatos de la EC2
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

MAC=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/network/interfaces/macs/)

VPC_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/vpc-id")

SUBNET_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/subnet-id")

echo "VPC detectada:    $VPC_ID"
echo "Subnet detectada: $SUBNET_ID"

# ---------------------------------------------
# 0. Desplegar stack CloudFormation (si no existe)
# ---------------------------------------------
echo ""
echo ">>> Comprobando stack CloudFormation..."

STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].StackStatus" \
  --output text \
  --region "$REGION" 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$STACK_STATUS" = "DOES_NOT_EXIST" ]; then
  echo "  Stack no existe, desplegando..."
  
  # EMAIL debe estar configurado antes de ejecutar el script
  if [ -z "$EMAIL" ]; then
    echo "ERROR: variable EMAIL no definida. Ejecuta: export EMAIL="tu@email.com""
    exit 1
  fi

  LAB_ROLE_ARN=$(aws iam get-role \
    --role-name "LabRole" \
    --query "Role.Arn" --output text)

  aws cloudformation create-stack \
    --stack-name "$STACK_NAME" \
    --template-body file://$(dirname "$0")/arch2-deployment.yaml \
    --parameters \
        ParameterKey=VpcId,ParameterValue="$VPC_ID" \
        ParameterKey=PublicSubnetOne,ParameterValue="$SUBNET_ID" \
        ParameterKey=StudentEmail,ParameterValue="$EMAIL" \
        ParameterKey=LabRoleArn,ParameterValue="$LAB_ROLE_ARN" \
    --role-arn "$LAB_ROLE_ARN" \
    --region "$REGION"

  echo "  Stack lanzado, esperando CREATE_COMPLETE (puede tardar 8-15 min)..."
  aws cloudformation wait stack-create-complete \
    --stack-name "$STACK_NAME" \
    --region "$REGION"
  echo "  ✓ Stack desplegado"

elif [ "$STACK_STATUS" = "CREATE_COMPLETE" ] || \
     [ "$STACK_STATUS" = "UPDATE_COMPLETE" ]; then
  echo "  Stack ya existe y esta en estado $STACK_STATUS, continuando..."

else
  echo "ERROR: el stack existe pero esta en estado inesperado: $STACK_STATUS"
  echo "  Revisa la consola de CloudFormation antes de continuar."
  exit 1
fi

# ---------------------------------------------
# 1. Leer outputs del stack CloudFormation
# ---------------------------------------------
get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text \
    --region "$REGION"
}

echo ">>> Leyendo outputs del stack..."
ECS_CLUSTER=$(get_output "ECSClusterName")
AURORA_ENDPOINT=$(get_output "AuroraEndpoint")
S3_REPORTS_BUCKET=$(get_output "S3ReportsBucket")
SNS_TOPIC_ARN=$(get_output "SNSEmailTopicArn")
SQS_QUEUE_URL=$(get_output "SQSInventoryQueueUrl")
SHARED_ALB_DNS=$(get_output "SharedALBDNS")
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

MEMC_HOST=$(aws elasticache describe-cache-clusters \
  --cache-cluster-id "Memcached" \
  --show-cache-node-info \
  --query "CacheClusters[0].CacheNodes[0].Endpoint.Address" \
  --output text \
  --region "$REGION")

echo "ECS Cluster:    $ECS_CLUSTER"
echo "ALB DNS:        $SHARED_ALB_DNS"
echo "Aurora:         $AURORA_ENDPOINT"
echo "Memcached:      $MEMC_HOST"
echo "S3 reports:     $S3_REPORTS_BUCKET"
echo "SQS queue:      $SQS_QUEUE_URL"
echo "Cuenta:         $ACCOUNT_ID"

if [ -z "$ECS_CLUSTER" ] || [ -z "$AURORA_ENDPOINT" ] || \
   [ -z "$MEMC_HOST" ]   || [ -z "$SHARED_ALB_DNS" ]; then
  echo ""
  echo "ERROR: faltan variables criticas. Comprueba los outputs del stack."
  exit 1
fi

# ---------------------------------------------
# 2. Asociar route table publica a ExtraSubnet
# ---------------------------------------------
echo ""
echo ">>> Asociando route table publica a ExtraSubnet (AZ2)..."

EXTRA_SUBNET=$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK_NAME" \
  --query "StackResources[?LogicalResourceId=='ExtraSubnet'].PhysicalResourceId" \
  --output text)

RT_PUBLIC=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
            "Name=route.destination-cidr-block,Values=0.0.0.0/0" \
  --query "RouteTables[0].RouteTableId" \
  --output text)

echo "  ExtraSubnet: $EXTRA_SUBNET"
echo "  VPC:         $VPC_ID"
echo "  RT publica:  $RT_PUBLIC"

RT_ASSOC=$(aws ec2 describe-route-tables \
  --route-table-ids "$RT_PUBLIC" \
  --query "RouteTables[0].Associations[?SubnetId=='${EXTRA_SUBNET}'].RouteTableAssociationId" \
  --output text 2>/dev/null)

if [ -z "$RT_ASSOC" ] || [ "$RT_ASSOC" = "None" ]; then
  aws ec2 associate-route-table \
    --subnet-id "$EXTRA_SUBNET" \
    --route-table-id "$RT_PUBLIC"
  echo "  ✓ ExtraSubnet asociada a la route table publica"
else
  echo "  ExtraSubnet ya tiene la asociacion correcta (saltando)"
fi

# ---------------------------------------------
# 3. Instalar dependencias en el bastion
# ---------------------------------------------
echo ""
echo ">>> Instalando dependencias en el bastion..."
sudo dnf install -y docker mariadb105 python3-pip
pip3 install boto3
sudo systemctl start docker
sudo systemctl enable docker
sudo chmod 666 /var/run/docker.sock

# ---------------------------------------------
# 4. Login ECR
# ---------------------------------------------
echo ""
echo ">>> Login en ECR..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_BASE"

# ---------------------------------------------
# 5. Build y push - node-web-app (Node.js :3000)
# ---------------------------------------------
echo ""
echo ">>> Build node-web-app..."
cd "$RESOURCES_DIR/codebase_partner"

cat > Dockerfile <<'DOCKERFILE'
FROM node:11-alpine
RUN mkdir -p /usr/src/app
WORKDIR /usr/src/app
COPY . .
RUN npm install
EXPOSE 3000
CMD ["npm", "run", "start"]
DOCKERFILE

docker build --tag cafe/node-web-app .
docker tag cafe/node-web-app:latest "${ECR_BASE}/cafe/node-web-app:latest"
docker push "${ECR_BASE}/cafe/node-web-app"

# ---------------------------------------------
# 6. Build y push - products-api (Flask :5000)
# ---------------------------------------------
echo ""
echo ">>> Build products-api..."
cd "$RESOURCES_DIR/products_api"

docker build --tag cafe/products-api .
docker tag cafe/products-api:latest "${ECR_BASE}/cafe/products-api:latest"
docker push "${ECR_BASE}/cafe/products-api"

# ---------------------------------------------
# 7. Build y push - report-service (Flask :5000)
# ---------------------------------------------
echo ""
echo ">>> Build report-service..."
cd "$RESOURCES_DIR/report_service"

docker build --tag cafe/report-service .
docker tag cafe/report-service:latest "${ECR_BASE}/cafe/report-service:latest"
docker push "${ECR_BASE}/cafe/report-service"

# ---------------------------------------------
# 8. Build y push - static-web (nginx :80)
#
# nginx sirve bajo /web/ y tambien bajo /images/
# para las imagenes referenciadas con ruta absoluta.
# Cognito callback apunta a /web/callback.html.
# ---------------------------------------------
echo ""
echo ">>> Build static-web (nginx)..."

# Leer datos de Cognito - se reutilizan en pasos 14 y 15
USER_POOL_ID=$(aws cognito-idp list-user-pools \
  --max-results 1 --query "UserPools[0].Id" --output text)
COGNITO_CLIENT_ID=$(aws cognito-idp list-user-pool-clients \
  --user-pool-id "$USER_POOL_ID" --max-results 1 \
  --query "UserPoolClients[0].ClientId" --output text)
COGNITO_DOMAIN=$(aws cognito-idp describe-user-pool \
  --user-pool-id "$USER_POOL_ID" \
  --query "UserPool.Domain" --output text)

# Callback apunta a /web/callback.html - servido por nginx
CALLBACK_URL="https://${SHARED_ALB_DNS}/web/callback.html"
COGNITO_LOGIN_URL="https://${COGNITO_DOMAIN}.auth.${REGION}.amazoncognito.com/login?client_id=${COGNITO_CLIENT_ID}&response_type=token&scope=email+openid&redirect_uri=${CALLBACK_URL}"

cat > "$RESOURCES_DIR/website/config.js" << EOF
window.COFFEE_CONFIG = {
        API_GW_BASE_URL_STR: "https://${SHARED_ALB_DNS}",
        API_GW_REPORT_URL_STR: "https://${SHARED_ALB_DNS}",
        COGNITO_LOGIN_BASE_URL_STR: "${COGNITO_LOGIN_URL}"
}
EOF

echo "config.js generado:"
cat "$RESOURCES_DIR/website/config.js"

# Separar el montaje de la web estatica en otro directorio para el Dockerfile de nginx
mkdir -p "$RESOURCES_DIR/static_web/website"
cp -r "$RESOURCES_DIR/website/." \
  "$RESOURCES_DIR/static_web/website/"

# nginx sirve:
#   /web/*    -> assets bajo /usr/share/nginx/html/web/
#   /images/* -> imagenes referenciadas con ruta absoluta desde el HTML (root apunta a /web/ para que /images/ resuelva correctamente)
#   /         -> redireccion 301 a /web/
cat > "$RESOURCES_DIR/static_web/Dockerfile" << 'DOCKERFILE'
FROM nginx:alpine

COPY website/ /usr/share/nginx/html/web/

RUN find /usr/share/nginx/html -type d -exec chmod 755 {} \; \
 && find /usr/share/nginx/html -type f -exec chmod 644 {} \;

RUN printf 'server {\n\
    listen 80;\n\
    location /web/ {\n\
        root /usr/share/nginx/html;\n\
        try_files $uri $uri/ /web/index.html;\n\
    }\n\
    location /images/ {\n\
        root /usr/share/nginx/html/web;\n\
        try_files $uri =404;\n\
    }\n\
    location = / {\n\
        return 301 /web/;\n\
    }\n\
}\n' > /etc/nginx/conf.d/default.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
DOCKERFILE

cd "$RESOURCES_DIR/static_web"
docker build --tag cafe/static-web .
docker tag cafe/static-web:latest "${ECR_BASE}/cafe/static-web:latest"
docker push "${ECR_BASE}/cafe/static-web"

# ---------------------------------------------
# 9. Esperar instancia Aurora y poblar la BD
# ---------------------------------------------
echo ""
echo ">>> Esperando instancia Aurora..."
aws rds wait db-instance-available \
  --db-instance-identifier supplierdb-instance-1
echo "  ✓ Instancia Aurora disponible"

echo ""
echo ">>> Poblando Aurora RDS..."
mysql -h "$AURORA_ENDPOINT" -P 3306 -u admin -p"$MYPASS" <<EOF
CREATE USER IF NOT EXISTS 'nodeapp' IDENTIFIED WITH mysql_native_password BY 'coffee';
CREATE DATABASE IF NOT EXISTS COFFEE;
GRANT ALL PRIVILEGES ON COFFEE.* TO 'nodeapp'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, RELOAD, PROCESS, REFERENCES,
  INDEX, ALTER, SHOW DATABASES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE,
  REPLICATION SLAVE, REPLICATION CLIENT, CREATE VIEW, SHOW VIEW,
  CREATE ROUTINE, ALTER ROUTINE, CREATE USER, EVENT, TRIGGER
  ON *.* TO 'nodeapp'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

mysql -h "$AURORA_ENDPOINT" -P 3306 -u admin -p"$MYPASS" COFFEE \
  < "$RESOURCES_DIR/coffee_db_dump.sql"
echo "Aurora poblada."

# ---------------------------------------------
# 10. Poblar DynamoDB
# ---------------------------------------------
echo ""
echo ">>> Poblando DynamoDB con productos..."
python3 "$RESOURCES_DIR/seed.py"
echo "DynamoDB poblado."

# ---------------------------------------------
# 11. Registrar task definitions con valores reales
# ---------------------------------------------
echo ""
echo ">>> Registrando task definitions..."

register_task_def() {
  aws ecs register-task-definition \
    --cli-input-json "$1" \
    --query "taskDefinition.taskDefinitionArn" \
    --output text \
    --region "$REGION"
}

LAB_ROLE_ARN=$(aws iam get-role \
  --role-name "LabRole" \
  --query "Role.Arn" --output text)
echo "LabRole ARN: $LAB_ROLE_ARN"

# --- node-web-app ---
NODE_WEBAPP_TD_ARN=$(register_task_def "{
  \"family\": \"cafe-node-web-app\",
  \"cpu\": \"512\",
  \"memory\": \"1024\",
  \"networkMode\": \"awsvpc\",
  \"requiresCompatibilities\": [\"FARGATE\"],
  \"executionRoleArn\": \"${LAB_ROLE_ARN}\",
  \"taskRoleArn\": \"${LAB_ROLE_ARN}\",
  \"containerDefinitions\": [{
    \"name\": \"node-web-app\",
    \"image\": \"${ECR_BASE}/cafe/node-web-app:latest\",
    \"essential\": true,
    \"portMappings\": [{\"containerPort\": 3000, \"protocol\": \"tcp\"}],
    \"environment\": [
      {\"name\": \"APP_DB_HOST\", \"value\": \"${AURORA_ENDPOINT}\"},
      {\"name\": \"MEMC_HOST\",   \"value\": \"${MEMC_HOST}:11211\"}
    ],
    \"logConfiguration\": {
      \"logDriver\": \"awslogs\",
      \"options\": {
        \"awslogs-group\":         \"/ecs/cafe-node-web-app\",
        \"awslogs-region\":        \"${REGION}\",
        \"awslogs-stream-prefix\": \"ecs\"
      }
    }
  }]
}")
echo "  node-web-app TD:   $NODE_WEBAPP_TD_ARN"

# --- static-web ---
STATIC_WEB_TD_ARN=$(register_task_def "{
  \"family\": \"cafe-static-web\",
  \"cpu\": \"256\",
  \"memory\": \"512\",
  \"networkMode\": \"awsvpc\",
  \"requiresCompatibilities\": [\"FARGATE\"],
  \"executionRoleArn\": \"${LAB_ROLE_ARN}\",
  \"taskRoleArn\": \"${LAB_ROLE_ARN}\",
  \"containerDefinitions\": [{
    \"name\": \"static-web\",
    \"image\": \"${ECR_BASE}/cafe/static-web:latest\",
    \"essential\": true,
    \"portMappings\": [{\"containerPort\": 80, \"protocol\": \"tcp\"}],
    \"logConfiguration\": {
      \"logDriver\": \"awslogs\",
      \"options\": {
        \"awslogs-group\":         \"/ecs/cafe-static-web\",
        \"awslogs-region\":        \"${REGION}\",
        \"awslogs-stream-prefix\": \"ecs\"
      }
    }
  }]
}")
echo "  static-web TD:     $STATIC_WEB_TD_ARN"

# --- products-api ---
PRODUCTS_API_TD_ARN=$(register_task_def "{
  \"family\": \"cafe-products-api\",
  \"cpu\": \"256\",
  \"memory\": \"512\",
  \"networkMode\": \"awsvpc\",
  \"requiresCompatibilities\": [\"FARGATE\"],
  \"executionRoleArn\": \"${LAB_ROLE_ARN}\",
  \"taskRoleArn\": \"${LAB_ROLE_ARN}\",
  \"containerDefinitions\": [{
    \"name\": \"products-api\",
    \"image\": \"${ECR_BASE}/cafe/products-api:latest\",
    \"essential\": true,
    \"portMappings\": [{\"containerPort\": 5000, \"protocol\": \"tcp\"}],
    \"environment\": [
      {\"name\": \"AWS_DEFAULT_REGION\", \"value\": \"${REGION}\"},
      {\"name\": \"DYNAMODB_TABLE\",     \"value\": \"FoodProducts\"},
      {\"name\": \"DYNAMODB_INDEX\",     \"value\": \"special_GSI\"}
    ],
    \"logConfiguration\": {
      \"logDriver\": \"awslogs\",
      \"options\": {
        \"awslogs-group\":         \"/ecs/cafe-products-api\",
        \"awslogs-region\":        \"${REGION}\",
        \"awslogs-stream-prefix\": \"ecs\"
      }
    }
  }]
}")
echo "  products-api TD:   $PRODUCTS_API_TD_ARN"

# --- report-service ---
REPORT_SERVICE_TD_ARN=$(register_task_def "{
  \"family\": \"cafe-report-service\",
  \"cpu\": \"256\",
  \"memory\": \"512\",
  \"networkMode\": \"awsvpc\",
  \"requiresCompatibilities\": [\"FARGATE\"],
  \"executionRoleArn\": \"${LAB_ROLE_ARN}\",
  \"taskRoleArn\": \"${LAB_ROLE_ARN}\",
  \"containerDefinitions\": [{
    \"name\": \"report-service\",
    \"image\": \"${ECR_BASE}/cafe/report-service:latest\",
    \"essential\": true,
    \"portMappings\": [{\"containerPort\": 5000, \"protocol\": \"tcp\"}],
    \"environment\": [
      {\"name\": \"AWS_DEFAULT_REGION\",      \"value\": \"${REGION}\"},
      {\"name\": \"REPORT_BUCKET_NAME\",       \"value\": \"${S3_REPORTS_BUCKET}\"},
      {\"name\": \"SNS_TOPIC_ARN\",            \"value\": \"${SNS_TOPIC_ARN}\"},
      {\"name\": \"REPORT_KEY\",               \"value\": \"report.html\"},
      {\"name\": \"PRESIGNED_EXPIRY_SECONDS\", \"value\": \"3600\"},
      {\"name\": \"DB_HOST\",                  \"value\": \"${AURORA_ENDPOINT}\"},
      {\"name\": \"DB_USER\",                  \"value\": \"admin\"},
      {\"name\": \"DB_PASSWORD\",              \"value\": \"${MYPASS}\"},
      {\"name\": \"DB_NAME\",                  \"value\": \"COFFEE\"}
    ],
    \"logConfiguration\": {
      \"logDriver\": \"awslogs\",
      \"options\": {
        \"awslogs-group\":         \"/ecs/cafe-report-service\",
        \"awslogs-region\":        \"${REGION}\",
        \"awslogs-stream-prefix\": \"ecs\"
      }
    }
  }]
}")
echo "  report-service TD: $REPORT_SERVICE_TD_ARN"

# --- sqs-worker ---
SQS_WORKER_TD_ARN=$(register_task_def "{
  \"family\": \"cafe-sqs-worker\",
  \"cpu\": \"256\",
  \"memory\": \"512\",
  \"networkMode\": \"awsvpc\",
  \"requiresCompatibilities\": [\"FARGATE\"],
  \"executionRoleArn\": \"${LAB_ROLE_ARN}\",
  \"taskRoleArn\": \"${LAB_ROLE_ARN}\",
  \"containerDefinitions\": [{
    \"name\": \"sqs-worker\",
    \"image\": \"${ECR_BASE}/cafe/report-service:latest\",
    \"essential\": true,
    \"command\": [\"python3\", \"sqs_worker.py\"],
    \"environment\": [
      {\"name\": \"AWS_DEFAULT_REGION\", \"value\": \"${REGION}\"},
      {\"name\": \"SQS_QUEUE_URL\",      \"value\": \"${SQS_QUEUE_URL}\"},
      {\"name\": \"DB_HOST\",            \"value\": \"${AURORA_ENDPOINT}\"},
      {\"name\": \"DB_USER\",            \"value\": \"admin\"},
      {\"name\": \"DB_PASSWORD\",        \"value\": \"${MYPASS}\"},
      {\"name\": \"DB_NAME\",            \"value\": \"COFFEE\"},
      {\"name\": \"MEMC_HOST\",          \"value\": \"${MEMC_HOST}:11211\"}
    ],
    \"logConfiguration\": {
      \"logDriver\": \"awslogs\",
      \"options\": {
        \"awslogs-group\":         \"/ecs/cafe-sqs-worker\",
        \"awslogs-region\":        \"${REGION}\",
        \"awslogs-stream-prefix\": \"ecs\"
      }
    }
  }]
}")
echo "  sqs-worker TD:     $SQS_WORKER_TD_ARN"

# Actualizar de paso el placeholder del script de envio de inventario a SNS
# Se lee el fichero .template y se sobreescribe el .py con el valor real del SNS_TOPIC_ARN
sed "s|<SNS_TOPIC_ARN>|${SNS_TOPIC_ARN}|g" \
  "$RESOURCES_DIR/sqs-sns/send_beans_update.py.template" \
  > "$RESOURCES_DIR/sqs-sns/send_beans_update.py"


# ---------------------------------------------
# 12. Actualizar servicios ECS
# ---------------------------------------------
echo ""
echo ">>> Actualizando servicios ECS..."

update_service() {
  local SVC="$1"
  local TD_ARN="$2"
  aws ecs update-service \
    --cluster "$ECS_CLUSTER" \
    --service "$SVC" \
    --task-definition "$TD_ARN" \
    --desired-count 1 \
    --force-new-deployment \
    --query "service.serviceName" \
    --output text \
    --region "$REGION"
  echo "  ✓ $SVC actualizado"
}

update_service "cafe-node-web-app"   "$NODE_WEBAPP_TD_ARN"
update_service "cafe-static-web"     "$STATIC_WEB_TD_ARN"
update_service "cafe-products-api"   "$PRODUCTS_API_TD_ARN"
update_service "cafe-report-service" "$REPORT_SERVICE_TD_ARN"
update_service "cafe-sqs-worker"     "$SQS_WORKER_TD_ARN"

# ---------------------------------------------
# 13. Esperar estabilizacion de servicios ECS
# ---------------------------------------------
echo ""
echo ">>> Esperando estabilizacion de servicios ECS (puede tardar 3-5 min)..."

for SVC in cafe-node-web-app cafe-static-web cafe-products-api \
           cafe-report-service cafe-sqs-worker; do
  echo "  Esperando: $SVC..."
  aws ecs wait services-stable \
    --cluster "$ECS_CLUSTER" \
    --services "$SVC" \
    --region "$REGION"
  echo "  ✓ $SVC estable"
done

# ---------------------------------------------
# 14. Certificado autofirmado + listener HTTPS:443
#
# El listener HTTPS replica las mismas reglas
# que el listener HTTP:80 del CloudFormation,
# añadiendo tambien /images* -> static-web.
# ---------------------------------------------
echo ""
echo ">>> Generando certificado autofirmado e importando en ACM..."

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /tmp/cafe-key.pem \
  -out    /tmp/cafe-cert.pem \
  -days   365 \
  -subj   "/CN=${SHARED_ALB_DNS}/O=CafeLab/C=US" \
  -addext "subjectAltName=DNS:${SHARED_ALB_DNS}"

CERT_ARN=$(aws acm import-certificate \
  --certificate fileb:///tmp/cafe-cert.pem \
  --private-key  fileb:///tmp/cafe-key.pem \
  --query "CertificateArn" \
  --output text \
  --region "$REGION")
echo "  Certificado ACM: $CERT_ARN"

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "cafe-shared-alb" \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text)

TG_NODE_ARN=$(aws elbv2 describe-target-groups \
  --names "cafe-node-web-app-tg" \
  --query "TargetGroups[0].TargetGroupArn" --output text)
TG_STATIC_ARN=$(aws elbv2 describe-target-groups \
  --names "cafe-static-web-tg" \
  --query "TargetGroups[0].TargetGroupArn" --output text)
TG_PRODUCTS_ARN=$(aws elbv2 describe-target-groups \
  --names "cafe-products-api-tg" \
  --query "TargetGroups[0].TargetGroupArn" --output text)
TG_REPORT_ARN=$(aws elbv2 describe-target-groups \
  --names "cafe-report-service-tg" \
  --query "TargetGroups[0].TargetGroupArn" --output text)

echo "  Creando listener HTTPS:443 (default: node-web-app)..."
HTTPS_LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query "Listeners[?Port==\`443\`].ListenerArn | [0]" \
  --output text 2>/dev/null)

if [ -z "$HTTPS_LISTENER_ARN" ] || [ "$HTTPS_LISTENER_ARN" = "None" ]; then
  HTTPS_LISTENER_ARN=$(aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTPS --port 443 \
    --certificates "CertificateArn=${CERT_ARN}" \
    --ssl-policy "ELBSecurityPolicy-2016-08" \
    --default-actions "Type=forward,TargetGroupArn=${TG_NODE_ARN}" \
    --query "Listeners[0].ListenerArn" \
    --output text)
  echo "  Listener HTTPS creado: $HTTPS_LISTENER_ARN"
else
  echo "  Listener HTTPS ya existe (saltando)"
fi

# Añadir reglas al listener HTTPS (idempotente)
add_https_rule() {
  local PRIORITY="$1"
  local PATTERN="$2"
  local TG_ARN="$3"
  local EXISTS
  EXISTS=$(aws elbv2 describe-rules \
    --listener-arn "$HTTPS_LISTENER_ARN" \
    --query "Rules[?Priority==\`${PRIORITY}\`].RuleArn | [0]" \
    --output text 2>/dev/null)
  if [ -z "$EXISTS" ] || [ "$EXISTS" = "None" ]; then
    aws elbv2 create-rule \
      --listener-arn "$HTTPS_LISTENER_ARN" \
      --priority "$PRIORITY" \
      --conditions "Field=path-pattern,Values='${PATTERN}'" \
      --actions "Type=forward,TargetGroupArn=${TG_ARN}" \
      --query "Rules[0].RuleArn" --output text
    echo "  Regla HTTPS prio ${PRIORITY} (${PATTERN}) creada"
  else
    echo "  Regla HTTPS prio ${PRIORITY} ya existe (saltando)"
  fi
}

# Mismas prioridades que HTTP + /images* para las imagenes absolutas
add_https_rule 10 "/products*"      "$TG_PRODUCTS_ARN"
add_https_rule 20 "/create_report*" "$TG_REPORT_ARN"
add_https_rule 30 "/bean_products*" "$TG_REPORT_ARN"
add_https_rule 40 "/web*"           "$TG_STATIC_ARN"
add_https_rule 50 "/images*"        "$TG_STATIC_ARN"

echo "  ✓ ALB HTTPS configurado"

# ---------------------------------------------
# 15. Actualizar Cognito con la callback HTTPS
#
# Callback -> /web/callback.html (servido por nginx)
# USER_POOL_ID, COGNITO_CLIENT_ID y COGNITO_DOMAIN
# se definieron en el paso 8 - no se repiten.
# ---------------------------------------------
echo ""
echo ">>> Actualizando Cognito (callback HTTPS)..."

CALLBACK_URL="https://${SHARED_ALB_DNS}/web/callback.html"

aws cognito-idp update-user-pool-client \
  --user-pool-id "$USER_POOL_ID" \
  --client-id "$COGNITO_CLIENT_ID" \
  --allowed-o-auth-flows implicit \
  --allowed-o-auth-flows-user-pool-client \
  --allowed-o-auth-scopes email openid \
  --callback-urls "$CALLBACK_URL" \
  --default-redirect-uri "$CALLBACK_URL" \
  --logout-urls "$CALLBACK_URL" \
  --supported-identity-providers COGNITO
echo "  ✓ Cognito callback actualizado a $CALLBACK_URL"

# ---------------------------------------------
# 16. Crear usuario Cognito "frank"
# ---------------------------------------------
echo ""
echo ">>> Creando usuario Cognito 'frank'..."

aws cognito-idp admin-create-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "frank" \
  --message-action SUPPRESS \
  --temporary-password '!CoffeeIsGreat34' \
  --user-attributes \
      Name=email,Value="$EMAIL" \
      Name=email_verified,Value=true \
  2>/dev/null && echo "  Usuario frank creado" \
             || echo "  frank ya existe, continuando"

aws cognito-idp admin-set-user-password \
  --user-pool-id "$USER_POOL_ID" \
  --username "frank" \
  --password '!CoffeeIsGreat35' \
  --permanent
echo "  Contraseña permanente establecida"

# ---------------------------------------------
# 17. Tagging de recursos - Stack: arch2ll (Learner Lab)
# ---------------------------------------------
echo ""
echo ">>> Aplicando tags Stack=arch2ll a todos los recursos..."

TAG_KEY="Stack"
TAG_VALUE="arch2ll"

# --- ALB ---
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "cafe-shared-alb" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text)
aws elbv2 add-tags \
  --resource-arns "$ALB_ARN" \
  --tags "Key=${TAG_KEY},Value=${TAG_VALUE}"

# --- Target Groups ---
for TG_NAME in cafe-node-web-app-tg cafe-static-web-tg \
               cafe-products-api-tg cafe-report-service-tg; do
  TG_ARN=$(aws elbv2 describe-target-groups \
    --names "$TG_NAME" \
    --query "TargetGroups[0].TargetGroupArn" --output text)
  aws elbv2 add-tags \
    --resource-arns "$TG_ARN" \
    --tags "Key=${TAG_KEY},Value=${TAG_VALUE}"
done

# --- ECS Cluster ---
ECS_CLUSTER_ARN=$(aws ecs describe-clusters \
  --clusters "cafe-cluster" \
  --query "clusters[0].clusterArn" --output text)
aws ecs tag-resource \
  --resource-arn "$ECS_CLUSTER_ARN" \
  --tags "key=${TAG_KEY},value=${TAG_VALUE}"

# --- ECS Services ---
for SVC in cafe-node-web-app cafe-static-web cafe-products-api \
           cafe-report-service cafe-sqs-worker; do
  SVC_ARN=$(aws ecs describe-services \
    --cluster "cafe-cluster" \
    --services "$SVC" \
    --query "services[0].serviceArn" --output text)
  aws ecs tag-resource \
    --resource-arn "$SVC_ARN" \
    --tags "key=${TAG_KEY},value=${TAG_VALUE}"
done

# --- Task Definitions (ultima revision de cada familia) ---
for FAMILY in cafe-node-web-app cafe-static-web cafe-products-api \
              cafe-report-service cafe-sqs-worker; do
  TD_ARN=$(aws ecs describe-task-definition \
    --task-definition "$FAMILY" \
    --query "taskDefinition.taskDefinitionArn" --output text)
  aws ecs tag-resource \
    --resource-arn "$TD_ARN" \
    --tags "key=${TAG_KEY},value=${TAG_VALUE}"
done

# --- ECR Repositories ---
for REPO in cafe/static-web cafe/node-web-app \
            cafe/products-api cafe/report-service; do
  REPO_ARN=$(aws ecr describe-repositories \
    --repository-names "$REPO" \
    --query "repositories[0].repositoryArn" --output text)
  aws ecr tag-resource \
    --resource-arn "$REPO_ARN" \
    --tags "Key=${TAG_KEY},Value=${TAG_VALUE}"
done

# --- Aurora Cluster e instancia ---
aws rds add-tags-to-resource \
  --resource-name "$(aws rds describe-db-clusters \
    --db-cluster-identifier supplierDB \
    --query 'DBClusters[0].DBClusterArn' --output text)" \
  --tags "Key=${TAG_KEY},Value=${TAG_VALUE}"

aws rds add-tags-to-resource \
  --resource-name "$(aws rds describe-db-instances \
    --db-instance-identifier supplierdb-instance-1 \
    --query 'DBInstances[0].DBInstanceArn' --output text)" \
  --tags "Key=${TAG_KEY},Value=${TAG_VALUE}"

# --- ElastiCache Memcached ---
MEMC_ARN=$(aws elasticache list-tags-for-resource \
  --resource-name "arn:aws:elasticache:${REGION}:${ACCOUNT_ID}:cluster:Memcached" \
  2>/dev/null && \
  echo "arn:aws:elasticache:${REGION}:${ACCOUNT_ID}:cluster:Memcached")
aws elasticache add-tags-to-resource \
  --resource-name "arn:aws:elasticache:${REGION}:${ACCOUNT_ID}:cluster:Memcached" \
  --tags "Key=${TAG_KEY},Value=${TAG_VALUE}"

# --- DynamoDB ---
DYNAMO_ARN="arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/FoodProducts"
aws dynamodb tag-resource \
  --resource-arn "$DYNAMO_ARN" \
  --tags "Key=${TAG_KEY},Value=${TAG_VALUE}"

# --- S3 Bucket de reportes ---
EXISTING_TAGS=$(aws s3api get-bucket-tagging \
  --bucket "$S3_REPORTS_BUCKET" \
  --query "TagSet" \
  --output json 2>/dev/null || echo "[]")

MERGED_TAGS=$(echo "$EXISTING_TAGS" | python3 -c "
import sys, json
tags = json.load(sys.stdin)
# Eliminar el tag si ya existe para no duplicar
tags = [t for t in tags if t['Key'] != '${TAG_KEY}']
tags.append({'Key': '${TAG_KEY}', 'Value': '${TAG_VALUE}'})
print(json.dumps(tags))
")

TAGGING_JSON=$(jq -n --argjson tags "$MERGED_TAGS" '{TagSet: $tags}')

aws s3api put-bucket-tagging \
  --bucket "$S3_REPORTS_BUCKET" \
  --tagging "$TAGGING_JSON"

# --- SNS Topics ---
aws sns tag-resource \
  --resource-arn "$SNS_TOPIC_ARN" \
  --tags "Key=${TAG_KEY},Value=${TAG_VALUE}"

SNS_INVENTORY_ARN=$(get_output "SNSInventoryTopicArn")
aws sns tag-resource \
  --resource-arn "$SNS_INVENTORY_ARN" \
  --tags "Key=${TAG_KEY},Value=${TAG_VALUE}"

# --- SQS Queues ---
aws sqs tag-queue \
  --queue-url "$SQS_QUEUE_URL" \
  --tags "${TAG_KEY}=${TAG_VALUE}"

SQS_DLQ_URL=$(get_output "SQSInventoryDLQUrl")
aws sqs tag-queue \
  --queue-url "$SQS_DLQ_URL" \
  --tags "${TAG_KEY}=${TAG_VALUE}"

# --- CloudWatch Log Groups ---
for LG in /ecs/cafe-node-web-app /ecs/cafe-static-web \
          /ecs/cafe-products-api /ecs/cafe-report-service \
          /ecs/cafe-sqs-worker; do
  aws logs tag-log-group \
    --log-group-name "$LG" \
    --tags "${TAG_KEY}=${TAG_VALUE}"
done

# --- Cognito User Pool ---
COGNITO_POOL_ARN=$(aws cognito-idp describe-user-pool \
  --user-pool-id "$USER_POOL_ID" \
  --query "UserPool.Arn" --output text)
aws cognito-idp tag-resource \
  --resource-arn "$COGNITO_POOL_ARN" \
  --tags "${TAG_KEY}=${TAG_VALUE}"

echo "  ✓ Tags aplicados correctamente"

echo ""
echo "============================================="
echo " Despliegue ECS completado"
echo "============================================="
echo ""
echo " Supplier web (Node):   https://$SHARED_ALB_DNS/"
echo " Web estatica (nginx):  https://$SHARED_ALB_DNS/web/"
echo ""
echo " Endpoints API:"
echo "   productos:           https://$SHARED_ALB_DNS/products"
echo "   oferta:              https://$SHARED_ALB_DNS/products/on_offer"
echo "   reporte:             https://$SHARED_ALB_DNS/create_report"
echo "   bean products:       https://$SHARED_ALB_DNS/bean_products"
echo ""
echo " Logs en CloudWatch:"
echo "   /ecs/cafe-node-web-app"
echo "   /ecs/cafe-static-web"
echo "   /ecs/cafe-products-api"
echo "   /ecs/cafe-report-service"
echo "   /ecs/cafe-sqs-worker"
echo ""
echo " Cognito usuario: frank / !CoffeeIsGreat35"
echo " Confirma el email de SNS en tu bandeja."
echo "============================================="