# tf-mail: читает очередь tf.notify.email и отправляет письма через SMTP.
# Собирается выкаткой (scripts/deploy.sh mailing) из этой папки. Секреты в образ не попадают:
# их подставляет выкатка из Vault переменными окружения (docker-compose.yml).
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./

RUN useradd --uid 10003 --no-create-home --shell /usr/sbin/nologin tfmail
USER tfmail

ENV PYTHONUNBUFFERED=1

# Живой — есть соединение с брокером и очередь читается (broker.HEARTBEAT обновляется раз в секунду).
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD python -c "import os,sys,time; sys.exit(time.time() - os.path.getmtime('/tmp/tf-alive') > 60)"

ENTRYPOINT ["python", "main.py"]
