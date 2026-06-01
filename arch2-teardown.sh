#!/bin/bash
# =============================================================
# arch2-teardown.sh - Limpieza completa del stack cafe
# =============================================================
# Orden de operaciones:
#   1. Vaciar bucket S3 de reportes (antes de borrar el stack)
#   2. Borrar el stack CloudFormation y esperar
#   3. Borrar los Target Groups huérfanos (DeletionPolicy: Retain)
# =============================================================
set -e

STACK_NAME="arch2"
REGION="us-east-1"

echo "============================================="
echo " Cafe ECS Fargate - Teardown"
echo "============================================="

# ---------------------------------------------
# Helpers
# ---------------------------------------------
get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text \
    --region "$REGION" 2>/dev/null
}

# ---------------------------------------------
# Comprobar que el stack existe
# ---------------------------------------------
STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].StackStatus" \
  --output text \
  --region "$REGION" 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$STACK_STATUS" = "DOES_NOT_EXIST" ]; then
  echo "El stack '$STACK_NAME' no existe. Nada que borrar."
  exit 0
fi

echo "Stack encontrado en estado: $STACK_STATUS"

# ---------------------------------------------
# 1. Vaciar bucket S3 antes de borrar el stack
# ---------------------------------------------
echo ""
echo ">>> Vaciando bucket S3 de reportes..."

S3_REPORTS_BUCKET=$(get_output "S3ReportsBucket")

if [ -n "$S3_REPORTS_BUCKET" ] && [ "$S3_REPORTS_BUCKET" != "None" ]; then
  echo "  Bucket: $S3_REPORTS_BUCKET"
  # Borrar objetos normales
  aws s3 rm "s3://${S3_REPORTS_BUCKET}" --recursive --region "$REGION" \
    && echo "  ✓ Objetos borrados" || echo "  (bucket ya vacío o sin objetos)"
  # Borrar versiones si el bucket tiene versionado
  aws s3api list-object-versions \
    --bucket "$S3_REPORTS_BUCKET" \
    --region "$REGION" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null | \
  python3 -c "
import sys, json, boto3
data = json.load(sys.stdin)
objs = data.get('Objects') or []
if objs:
    boto3.client('s3').delete_objects(
        Bucket='${S3_REPORTS_BUCKET}',
        Delete={'Objects': objs}
    )
    print('  ✓ Versiones borradas')
" 2>/dev/null || true
  echo "  ✓ Bucket vaciado"
else
  echo "  No se encontró el bucket en los outputs del stack (saltando)"
fi

# ---------------------------------------------
# 2. Borrar el stack y esperar
# ---------------------------------------------
echo ""
echo ">>> Eliminando stack CloudFormation '$STACK_NAME'..."

aws cloudformation delete-stack \
  --stack-name "$STACK_NAME" \
  --region "$REGION"

echo "  Esperando DELETE_COMPLETE (puede tardar 10-15 min)..."
aws cloudformation wait stack-delete-complete \
  --stack-name "$STACK_NAME" \
  --region "$REGION"

echo "  ✓ Stack eliminado"

# ---------------------------------------------
# 3. Borrar Target Groups huérfanos (Retain)
# ---------------------------------------------
echo ""
echo ">>> Eliminando Target Groups huérfanos..."

for TG_NAME in cafe-node-web-app-tg cafe-static-web-tg \
               cafe-products-api-tg cafe-report-service-tg; do

  TG_ARN=$(aws elbv2 describe-target-groups \
    --names "$TG_NAME" \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text \
    --region "$REGION" 2>/dev/null || echo "")

  if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
    aws elbv2 delete-target-group \
      --target-group-arn "$TG_ARN" \
      --region "$REGION"
    echo "  ✓ $TG_NAME borrado"
  else
    echo "  $TG_NAME no encontrado (ya borrado o nunca creado)"
  fi
done

echo ""
echo "============================================="
echo " Teardown completado"
echo " IMPORTANTE: Recuerde borrar esta instancia EC2, el certificado ACM generado y por ultimo eliminar la VPC 10.0.0.0/16"
echo "============================================="