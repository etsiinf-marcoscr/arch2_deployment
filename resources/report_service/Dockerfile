FROM python:3.12-slim

WORKDIR /app

# Dependencias del sistema para pymysql (ninguna extra necesaria con el driver puro Python)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY sqs_worker.py .

EXPOSE 5000

# Usar gunicorn en producción para ECS
RUN pip install --no-cache-dir gunicorn==23.0.0

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--timeout", "60", "app:app"]
