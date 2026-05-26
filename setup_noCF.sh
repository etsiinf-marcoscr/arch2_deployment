#!/bin/bash
# =============================================================
# setup_noCF.sh - Cafe ECS Fargate Bootstrap Setup
# =============================================================
# Arquitectura:
#   /              -> cafe-node-web-app (Node.js, proveedores, ruta raíz)
#   /web*          -> cafe-static-web  (nginx, web estática bakeada)
#   /images*       -> cafe-static-web  (nginx, imágenes referenciadas con ruta absoluta)
#   /products*     -> cafe-products-api (Flask + DynamoDB)
#   /create_report*-> cafe-report-service (Flask + Aurora + S3 + SNS)
#   /bean_products*-> cafe-report-service
#
# Cognito callback -> /web/callback.html (servido por nginx)
# Cognito usa HTTPS del ALB (certificado autofirmado importado en ACM).
# No se usa S3 para la web estática.
#
# Configuración previa:
#   1. Tener /resources en el mismo nivel que este script
#   2. export EMAIL="tu@email.com"
#   3. chmod +x setup_noCF.sh && ./setup_noCF.sh
# =============================================================
set -e

echo "============================================="
echo " Cafe ECS Fargate - Bootstrap Setup"
echo "============================================="

STACK_NAME="noCF-ECS-arch2"
REGION="us-east-1"
MYPASS="coffee_beans_for_all"

# ─────────────────────────────────────────────
# 1. Leer outputs del stack CloudFormation
# ─────────────────────────────────────────────
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
  echo "ERROR: faltan variables críticas. Comprueba los outputs del stack."
  exit 1
fi

# ─────────────────────────────────────────────
# 2. Asociar route table pública a ExtraSubnet
# ─────────────────────────────────────────────
echo ""
echo ">>> Asociando route table pública a ExtraSubnet (AZ2)..."

EXTRA_SUBNET=$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK_NAME" \
  --query "StackResources[?LogicalResourceId=='ExtraSubnet'].PhysicalResourceId" \
  --output text)

VPC_ID=$(aws ec2 describe-subnets \
  --subnet-ids "$EXTRA_SUBNET" \
  --query "Subnets[0].VpcId" --output text)

RT_PUBLIC=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
            "Name=route.destination-cidr-block,Values=0.0.0.0/0" \
  --query "RouteTables[0].RouteTableId" \
  --output text)

echo "  ExtraSubnet: $EXTRA_SUBNET"
echo "  VPC:         $VPC_ID"
echo "  RT pública:  $RT_PUBLIC"

RT_ASSOC=$(aws ec2 describe-route-tables \
  --route-table-ids "$RT_PUBLIC" \
  --query "RouteTables[0].Associations[?SubnetId=='${EXTRA_SUBNET}'].RouteTableAssociationId" \
  --output text 2>/dev/null)

if [ -z "$RT_ASSOC" ] || [ "$RT_ASSOC" = "None" ]; then
  aws ec2 associate-route-table \
    --subnet-id "$EXTRA_SUBNET" \
    --route-table-id "$RT_PUBLIC"
  echo "  ✓ ExtraSubnet asociada a la route table pública"
else
  echo "  ExtraSubnet ya tiene la asociación correcta (saltando)"
fi

# ─────────────────────────────────────────────
# 3. Instalar dependencias en el bastión
# ─────────────────────────────────────────────
echo ""
echo ">>> Instalando dependencias en el bastión..."
sudo dnf install -y docker mariadb105 git python3-pip
pip3 install boto3
sudo systemctl start docker
sudo systemctl enable docker
sudo chmod 666 /var/run/docker.sock

# ─────────────────────────────────────────────
# 4. Login ECR
# ─────────────────────────────────────────────
echo ""
echo ">>> Login en ECR..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_BASE"

# ─────────────────────────────────────────────
# 5. Build y push - node-web-app (Node.js :3000)
# ─────────────────────────────────────────────
echo ""
echo ">>> Build node-web-app..."
cd /home/ec2-user/resources/codebase_partner

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

# ─────────────────────────────────────────────
# 6. Build y push - products-api (Flask :5000)
# ─────────────────────────────────────────────
echo ""
echo ">>> Build products-api..."
cd /home/ec2-user/resources/products_api

docker build --tag cafe/products-api .
docker tag cafe/products-api:latest "${ECR_BASE}/cafe/products-api:latest"
docker push "${ECR_BASE}/cafe/products-api"

# ─────────────────────────────────────────────
# 7. Build y push - report-service (Flask :5000)
# ─────────────────────────────────────────────
echo ""
echo ">>> Build report-service..."
cd /home/ec2-user/resources/report_service

docker build --tag cafe/report-service .
docker tag cafe/report-service:latest "${ECR_BASE}/cafe/report-service:latest"
docker push "${ECR_BASE}/cafe/report-service"

# ─────────────────────────────────────────────
# 8. Build y push - static-web (nginx :80)
#
# nginx sirve bajo /web/ y también bajo /images/
# para las imágenes referenciadas con ruta absoluta.
# Cognito callback apunta a /web/callback.html.
# ─────────────────────────────────────────────
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

cat > /home/ec2-user/resources/website/config.js << EOF
window.COFFEE_CONFIG = {
        API_GW_BASE_URL_STR: "https://${SHARED_ALB_DNS}",
        API_GW_REPORT_URL_STR: "https://${SHARED_ALB_DNS}",
        COGNITO_LOGIN_BASE_URL_STR: "${COGNITO_LOGIN_URL}"
}
EOF

echo "config.js generado:"
cat /home/ec2-user/resources/website/config.js

# Preparar contexto de build para nginx
mkdir -p /home/ec2-user/resources/static_web/website
cp -r /home/ec2-user/resources/website/. \
      /home/ec2-user/resources/static_web/website/

# nginx sirve:
#   /web/*    -> assets bajo /usr/share/nginx/html/web/
#   /images/* -> imágenes referenciadas con ruta absoluta desde el HTML
#               (root apunta a /web/ para que /images/ resuelva correctamente)
#   /         -> redirección 301 a /web/
cat > /home/ec2-user/resources/static_web/Dockerfile << 'DOCKERFILE'
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

cd /home/ec2-user/resources/static_web
docker build --tag cafe/static-web .
docker tag cafe/static-web:latest "${ECR_BASE}/cafe/static-web:latest"
docker push "${ECR_BASE}/cafe/static-web"

# ─────────────────────────────────────────────
# 9. Esperar instancia Aurora y poblar la BD
# ─────────────────────────────────────────────
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
  < /home/ec2-user/resources/coffee_db_dump.sql
echo "Aurora poblada."

# ─────────────────────────────────────────────
# 10. Poblar DynamoDB
# ─────────────────────────────────────────────
echo ""
echo ">>> Poblando DynamoDB con productos..."
cd /home/ec2-user
python3 resources/seed.py
echo "DynamoDB poblado."

# ─────────────────────────────────────────────
# 11. Registrar task definitions con valores reales
# ─────────────────────────────────────────────
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

# ─────────────────────────────────────────────
# 12. Actualizar servicios ECS
# ─────────────────────────────────────────────
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

# ─────────────────────────────────────────────
# 13. Esperar estabilización de servicios ECS
# ─────────────────────────────────────────────
echo ""
echo ">>> Esperando estabilización de servicios ECS (puede tardar 2-4 min)..."

for SVC in cafe-node-web-app cafe-static-web cafe-products-api \
           cafe-report-service cafe-sqs-worker; do
  echo "  Esperando: $SVC..."
  aws ecs wait services-stable \
    --cluster "$ECS_CLUSTER" \
    --services "$SVC" \
    --region "$REGION"
  echo "  ✓ $SVC estable"
done

# ─────────────────────────────────────────────
# 14. Certificado autofirmado + listener HTTPS:443
#
# El listener HTTPS replica las mismas reglas
# que el listener HTTP:80 del CloudFormation,
# añadiendo también /images* -> static-web.
# ─────────────────────────────────────────────
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

# Mismas prioridades que HTTP + /images* para las imágenes absolutas
add_https_rule 10 "/products*"      "$TG_PRODUCTS_ARN"
add_https_rule 20 "/create_report*" "$TG_REPORT_ARN"
add_https_rule 30 "/bean_products*" "$TG_REPORT_ARN"
add_https_rule 40 "/web*"           "$TG_STATIC_ARN"
add_https_rule 50 "/images*"        "$TG_STATIC_ARN"

echo "  ✓ ALB HTTPS configurado"

# ─────────────────────────────────────────────
# 15. Actualizar Cognito con la callback HTTPS
#
# Callback -> /web/callback.html (servido por nginx)
# USER_POOL_ID, COGNITO_CLIENT_ID y COGNITO_DOMAIN
# se definieron en el paso 8 - no se repiten.
# ─────────────────────────────────────────────
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

# ─────────────────────────────────────────────
# 16. Crear usuario Cognito "frank"
# ─────────────────────────────────────────────
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

echo ""
echo "============================================="
echo " Despliegue ECS completado"
echo "============================================="
echo ""
echo " Supplier web (Node):   https://$SHARED_ALB_DNS/"
echo " Web estática (nginx):  https://$SHARED_ALB_DNS/web/"
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