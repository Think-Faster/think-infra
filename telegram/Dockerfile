# tf-tg: читает очередь tf.notify.telegram и отправляет сообщения от бота Telegram.
# Собирается выкаткой (scripts/deploy.sh telegram) из этой папки. Секреты в образ не попадают:
# их подставляет выкатка из Vault переменными окружения (docker-compose.yml).
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./

RUN useradd --uid 10004 --no-create-home --shell /usr/sbin/nologin tftg
USER tftg

ENV PYTHONUNBUFFERED=1

# Живой — есть соединение с брокером и очередь читается (broker.HEARTBEAT обновляется раз в секунду).
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD python -c "import os,sys,time; sys.exit(time.time() - os.path.getmtime('/tmp/tf-alive') > 60)"

ENTRYPOINT ["python", "main.py"]
