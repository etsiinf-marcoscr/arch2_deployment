"""
sqs_worker.py - Consumer SQS para actualizaciones de inventario de café.

Equivale al consumer Node.js original del Beanstalk (app/sqs/consumer.js).
Corre como proceso independiente en la misma EC2 que report_service.

Flujo:
  SNS FIFO → SQS FIFO → este worker → UPDATE beans en Aurora
                                     → invalida caché Memcached

Formato del mensaje (campo Message dentro del JSON de SNS):
  "supplier_id:bean_type:quantity"
  Ejemplo: "1:Arabica:500"
  Si quantity = 0 → marcar como out_of_stock (quantity = 0)

Lanzar con:
  python3 sqs_worker.py

Variables de entorno necesarias (mismas que app.py más SQS_QUEUE_URL y MEMC_HOST):
  SQS_QUEUE_URL, DB_HOST, DB_USER, DB_PASSWORD, DB_NAME,
  AWS_DEFAULT_REGION, MEMC_HOST (opcional)
"""

import json
import logging
import os
import time

import boto3
import pymysql
from botocore.exceptions import ClientError

# ---------------------------------------------
# Configuración
# ---------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [sqs_worker] %(levelname)s %(message)s"
)
logger = logging.getLogger(__name__)

AWS_REGION    = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL", "")

DB_HOST     = os.environ["DB_HOST"]
DB_USER     = os.environ["DB_USER"]
DB_PASSWORD = os.environ["DB_PASSWORD"]
DB_NAME     = os.environ["DB_NAME"]

# Memcached - opcional, solo si está disponible
MEMC_HOST = os.environ.get("MEMC_HOST", "")

# Parámetros de polling - equivalentes al consumer.js original
VISIBILITY_TIMEOUT = int(os.environ.get("VISIBILITY_TIMEOUT_IN_SEC", "30"))
WAIT_TIME_SECONDS  = int(os.environ.get("LONG_POLL_WAIT_IN_SEC", "5"))
MAX_MESSAGES       = 1   # igual que el original: un mensaje a la vez

sqs_client = boto3.client("sqs", region_name=AWS_REGION)

# Cliente Memcached (pymemcache) - se inicializa solo si MEMC_HOST está definido
memc_client = None
if MEMC_HOST:
    try:
        from pymemcache.client.base import Client as MemcacheClient
        host, port = MEMC_HOST.split(":") if ":" in MEMC_HOST else (MEMC_HOST, 11211)
        memc_client = MemcacheClient((host, int(port)), connect_timeout=2, timeout=2)
        logger.info("Memcached conectado en %s", MEMC_HOST)
    except Exception as e:
        logger.warning("No se pudo conectar a Memcached: %s - continuando sin caché", e)


# ---------------------------------------------
# Conexión Aurora
# ---------------------------------------------

def get_connection():
    return pymysql.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=5
    )


# ---------------------------------------------
# Parseo del mensaje
# El mensaje llega envuelto en el JSON de SNS:
# { "Message": "supplier_id:bean_type:quantity", ... }
# Equivale a parse_message() del consumer.js
# ---------------------------------------------

def parse_message(raw_body):
    """
    Extrae supplier_id, bean_type y quantity del body del mensaje SQS.
    El campo Message contiene "supplier_id:bean_type:quantity".
    """
    body = json.loads(raw_body)
    message = body.get("Message", "")
    logger.info("Mensaje SQS recibido: %s", message)

    parts = [p.strip() for p in message.split(":")]
    if len(parts) != 3:
        raise ValueError(f"Formato de mensaje inválido: '{message}' - se esperaba supplier_id:bean_type:quantity")
    
    if parts[2] < "0" or not parts[2].isdigit():
        raise ValueError(f"Cantidad inválida en mensaje: '{message}' - se esperaba un número entero no negativo")

    return {
        "supplier_id": int(parts[0]),
        "bean_type":   parts[1],
        "quantity":    int(parts[2])
    }


# ---------------------------------------------
# Actualización en Aurora
# Equivale a update_db() del consumer.js
# ---------------------------------------------

def update_bean_quantity(supplier_id, bean_type, delta_quantity):
    """
    Busca el bean por supplier_id + type y actualiza la cantidad.
    Si delta_quantity = 0 → pone quantity a 0 (out_of_stock).
    Si delta_quantity > 0 → SUMA al stock existente (igual que el original).
    """
    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                # Buscar el bean
                cursor.execute(
                    "SELECT id, quantity FROM beans WHERE supplier_id = %s AND type = %s",
                    (supplier_id, bean_type)
                )
                bean = cursor.fetchone()

                if not bean:
                    raise ValueError(
                        f"Bean no encontrado: supplier_id={supplier_id}, type={bean_type}"
                    )

                # Calcular nueva cantidad
                if delta_quantity == 0:
                    new_quantity = 0  # out_of_stock
                    logger.info("Bean %s del supplier %s marcado como out_of_stock", bean_type, supplier_id)
                else:
                    new_quantity = bean["quantity"] + delta_quantity
                    logger.info(
                        "Bean %s supplier %s: %d + %d = %d",
                        bean_type, supplier_id, bean["quantity"], delta_quantity, new_quantity
                    )

                # Actualizar
                cursor.execute(
                    "UPDATE beans SET quantity = %s WHERE id = %s",
                    (new_quantity, bean["id"])
                )
            connection.commit()

        logger.info("Aurora actualizado correctamente (bean id=%s)", bean["id"])

        # Invalidar caché Memcached si está disponible
        invalidate_cache(bean["id"])

        return bean["id"]

    except pymysql.MySQLError as e:
        raise RuntimeError(f"Error actualizando Aurora: {e}") from e


# ---------------------------------------------
# Invalidación de caché Memcached
# Equivale a clear_cache() del consumer.js
# ---------------------------------------------

def invalidate_cache(bean_id):
    """
    Invalida las entradas de Memcached afectadas.
    El node-web-app cachea 'beans_all' y 'beans_{id}'.
    Si no hay Memcached configurado, no hace nada.
    """
    if not memc_client:
        return
    try:
        memc_client.delete(f"beans_{bean_id}")
        memc_client.delete("beans_all")
        logger.info("Caché Memcached invalidada para bean_id=%s", bean_id)
    except Exception as e:
        logger.warning("No se pudo invalidar caché Memcached: %s", e)


# ---------------------------------------------
# Borrar mensaje de SQS tras éxito
# Equivale a delete_item_from_sqs() del consumer.js
# ---------------------------------------------

def delete_message(receipt_handle):
    try:
        sqs_client.delete_message(
            QueueUrl=SQS_QUEUE_URL,
            ReceiptHandle=receipt_handle
        )
        logger.info("Mensaje eliminado de SQS correctamente")
    except ClientError as e:
        logger.error("Error eliminando mensaje de SQS: %s", e)


# ---------------------------------------------
# Bucle principal de polling
# Equivale a read_message() del consumer.js
# ---------------------------------------------

def poll_loop():
    logger.info("Worker SQS iniciado. Escuchando: %s", SQS_QUEUE_URL)

    while True:
        try:
            response = sqs_client.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=MAX_MESSAGES,
                VisibilityTimeout=VISIBILITY_TIMEOUT,
                WaitTimeSeconds=WAIT_TIME_SECONDS
            )

            messages = response.get("Messages", [])

            if not messages:
                logger.debug("Sin mensajes. Siguiente poll en %ss...", WAIT_TIME_SECONDS)
                continue

            message = messages[0]
            receipt_handle = message["ReceiptHandle"]

            try:
                parsed = parse_message(message["Body"])
                update_bean_quantity(
                    supplier_id=parsed["supplier_id"],
                    bean_type=parsed["bean_type"],
                    delta_quantity=parsed["quantity"]
                )
                # Éxito → borrar de la cola
                delete_message(receipt_handle)

            except (ValueError, RuntimeError) as e:
                # Fallo en parseo o BD → NO borrar el mensaje
                # SQS lo devolverá a la cola tras el VisibilityTimeout
                # Tras maxReceiveCount intentos irá a la DLQ
                logger.error("Error procesando mensaje: %s - devolviendo a la cola", e)

        except ClientError as e:
            logger.error("Error en receive_message: %s - reintentando en 5s", e)
            time.sleep(5)

        except Exception as e:
            logger.exception("Error inesperado en el worker: %s", e)
            time.sleep(5)


# ---------------------------------------------
# Entrypoint
# ---------------------------------------------

if __name__ == "__main__":
    if not SQS_QUEUE_URL:
        logger.error("SQS_QUEUE_URL no está definida. Abortando.")
        raise SystemExit(1)

    poll_loop()