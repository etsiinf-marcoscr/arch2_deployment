import logging
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from uuid import uuid4

import boto3
import pymysql
from botocore.exceptions import ClientError
from flask import Flask, jsonify

# ─────────────────────────────────────────────
# Configuración
# ─────────────────────────────────────────────
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)

AWS_REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

BUCKET_NAME      = os.environ["REPORT_BUCKET_NAME"]
SNS_TOPIC_ARN    = os.environ["SNS_TOPIC_ARN"]
REPORT_KEY       = os.environ.get("REPORT_KEY", "report.html")
PRESIGNED_EXPIRY = int(os.environ.get("PRESIGNED_EXPIRY_SECONDS", "3600"))

DB_HOST     = os.environ["DB_HOST"]
DB_USER     = os.environ["DB_USER"]
DB_PASSWORD = os.environ["DB_PASSWORD"]
DB_NAME     = os.environ["DB_NAME"]

s3_client  = boto3.client("s3",  region_name=AWS_REGION)
sns_client = boto3.client("sns", region_name=AWS_REGION)


# ─────────────────────────────────────────────
# Helper de conexión a Aurora
# ─────────────────────────────────────────────

def get_connection():
    return pymysql.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=5
    )


# ─────────────────────────────────────────────
# GET /bean_products — nuevo endpoint
# Devuelve el stock actual de la tabla beans.
# Lo usa el node-web-app para mostrar el
# inventario de proveedores actualizado.
# ─────────────────────────────────────────────

@app.route("/bean_products", methods=["GET"])
def get_bean_products():
    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT * FROM beans")
                beans = cursor.fetchall()

        # Convertir Decimal a float para que jsonify no falle
        result = []
        for bean in beans:
            result.append({
                "id":           bean["id"],
                "supplier_id":  bean["supplier_id"],
                "type":         bean["type"],
                "product_name": bean["product_name"],
                "price":        float(bean["price"]),
                "description":  bean["description"],
                "quantity":     bean["quantity"]
            })

        return jsonify(result), 200

    except pymysql.MySQLError as e:
        logger.error("Error consultando beans: %s", e)
        return jsonify({"error": "Error al consultar beans", "detail": str(e)}), 500


# ─────────────────────────────────────────────
# POST /create_report
# ─────────────────────────────────────────────

@app.route("/create_report", methods=["POST"])
def create_report():
    try:
        logger.info("Consultando base de datos...")
        data = fetch_data_from_db()
        # Generar key única y ejecutar subida + generación de URL en paralelo
        report_key = f"report-{uuid4().hex}.html"
        logger.info("Generando HTML y URL en paralelo para %s...", report_key)
        with ThreadPoolExecutor(max_workers=2) as executor:
            future_html = executor.submit(generate_and_upload_html, data, report_key)
            future_url  = executor.submit(generate_presigned_url, report_key)

        future_html.result()
        presigned_url = future_url.result()

        logger.info("Enviando notificación SNS...")
        send_sns_notification(presigned_url)

        logger.info("Reporte generado correctamente.")
        return jsonify({
            "msg": "Reporte publicado en S3",
            "presigned_url": presigned_url,
            "s3_key": report_key
        }), 200

    except DatabaseError as e:
        logger.error("Error de base de datos: %s", e)
        return jsonify({"error": "Error al consultar la base de datos", "detail": str(e)}), 500

    except S3UploadError as e:
        logger.error("Error subiendo a S3: %s", e)
        return jsonify({"error": "Error al subir el reporte a S3", "detail": str(e)}), 500

    except Exception as e:
        logger.exception("Error inesperado en create_report")
        return jsonify({"error": "Error interno", "detail": str(e)}), 500


# ─────────────────────────────────────────────
# Consulta Aurora para el reporte
# ─────────────────────────────────────────────

def fetch_data_from_db():
    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT * FROM suppliers")
                suppliers = cursor.fetchall()
                cursor.execute("SELECT * FROM beans")
                beans = cursor.fetchall()
        return _merge_data(suppliers, beans)
    except pymysql.MySQLError as e:
        raise DatabaseError(f"Fallo en consulta MySQL: {e}") from e


def _merge_data(suppliers, beans):
    result = []
    for supplier in suppliers:
        entry = {
            "suppliers_id_int":     supplier["id"],
            "supplier_name_str":    supplier["name"],
            "supplier_address_str": supplier["address"],
            "supplier_phone_str":   supplier["phone"],
            "bean_info_obj_arr": [
                {
                    "type_str":         bean["type"],
                    "product_name_str": bean["product_name"],
                    "quantity_int":     bean["quantity"]
                }
                for bean in beans
                if bean["supplier_id"] == supplier["id"]
            ]
        }
        result.append(entry)
    return result


# ─────────────────────────────────────────────
# Generación HTML + subida a S3
# ─────────────────────────────────────────────

def generate_and_upload_html(data, key=None):
    html = _build_html(data)
    try:
        # Si no se pasa key, generar una clave única con formato report-<uuid>.html
        if not key:
            key = f"report-{uuid4().hex}.html"
        s3_client.put_object(
            Bucket=BUCKET_NAME,
            Key=key,
            Body=html.encode("utf-8"),
            CacheControl="max-age=0",
            ContentType="text/html"
        )
        logger.info("HTML subido a s3://%s/%s", BUCKET_NAME, key)
        return key
    except ClientError as e:
        raise S3UploadError(f"Error al subir HTML a S3: {e}") from e


def _build_html(data):
    timestamp = datetime.now().strftime("%H:%M:%S")
    rows = ""
    for supplier in data:
        beans_html = ""
        for bean in supplier["bean_info_obj_arr"]:
            beans_html += f"""
            <div data-role="bean_info">
                <h3>{bean['type_str']}</h3>
                <h4>{bean['quantity_int']}</h4>
                <span>{bean['product_name_str']}</span>
            </div>"""
        rows += f"""
        <section data-role="supplier_info">
            <h2>{supplier['supplier_name_str']}</h2>
            <p>{supplier['supplier_address_str']} : {supplier['supplier_phone_str']}</p>
            {beans_html}
        </section>"""

    return f"""<!DOCTYPE html>
<html>
<head>
    <title>Bean quantity report</title>
    <style>{_get_css()}</style>
</head>
<body>
<section class="report">
    <h1>Report</h1>
    <span data-role="timestamp">{timestamp}</span>
    {rows}
</section>
</body>
</html>"""


def _get_css():
    return """
html, body, section, h1, h2, h3, h4, p { margin: 0; padding: 0; }
.report { background-color: whitesmoke; padding: 0; margin: 0; position: relative; }
.report h1 {
    color: #e7e2e2; font-size: 42px; text-align: center;
    background-color: #434343; border-bottom: 1px solid #b9b4b4; padding: 12px 24px;
}
.report h2 { font-size: 24px; }
.report p  { font-size: 18px; padding: 12px 0; font-style: italic; }
.report [data-role="timestamp"] {
    font-size: 16px; color: #cac6c6; position: absolute; top: 32px; right: 24px;
}
.report [data-role="supplier_info"] {
    width: 90%; margin: 12px auto; color: #434343;
    border-bottom: 2px dotted #505951; padding-bottom: 12px; padding-top: 16px;
}
.report [data-role="bean_info"] {
    display: inline-block; color: #434343; margin-bottom: 12px;
    border-radius: 6px; margin-right: 12px; border: 1px solid #434343;
}
.report [data-role="bean_info"] h3 { padding: 12px 24px; font-size: 20px; }
.report [data-role="bean_info"] h4 { padding: 12px 24px; font-size: 18px; }
.report [data-role="bean_info"] span { padding: 12px 24px; font-size: 16px; display: block; }
"""


# ─────────────────────────────────────────────
# Presigned URL
# ─────────────────────────────────────────────

def generate_presigned_url(key):
    try:
        url = s3_client.generate_presigned_url(
            "get_object",
            Params={"Bucket": BUCKET_NAME, "Key": key},
            ExpiresIn=PRESIGNED_EXPIRY
        )
        logger.info("Presigned URL generada para %s (expira en %ss)", key, PRESIGNED_EXPIRY)
        return url
    except ClientError as e:
        raise S3UploadError(f"Error generando presigned URL: {e}") from e


# ─────────────────────────────────────────────
# Notificación SNS
# ─────────────────────────────────────────────

def send_sns_notification(presigned_url):
    try:
        sns_client.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="Reporte de inventario de café disponible",
            Message=(
                f"El reporte de inventario ha sido generado.\n\n"
                f"Accede aquí (expira en {PRESIGNED_EXPIRY // 60} minutos):\n{presigned_url}"
            )
        )
    except ClientError as e:
        logger.warning("No se pudo enviar la notificación SNS: %s", e)


# ─────────────────────────────────────────────
# Excepciones personalizadas
# ─────────────────────────────────────────────

class DatabaseError(Exception):
    pass

class S3UploadError(Exception):
    pass


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)