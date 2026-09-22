"""Ручная проверка критериев приёмки tf-rabbit.

Запуск из папки rabbitmq (контейнер tf-rabbit-smoke, профиль test):

    docker compose run --rm tf-rabbit-smoke publish
    docker restart tf-rabbit
    docker compose run --rm tf-rabbit-smoke check <marker>
    docker compose run --rm tf-rabbit-smoke deny

Тестовое сообщение идёт в tf.notify.email. Запускать, пока потребитель почты не подключён,
иначе он заберёт сообщение раньше проверки.
"""

import os
import sys
import time

import pika
from pika.exceptions import AMQPConnectionError, ChannelClosedByBroker

HOST = "tf-rabbit"
VHOST = "tf"

PASSWORDS = {
    "admin": "TF_RABBIT_ADMIN_PASSWORD",
    "tf-bff": "TF_RABBIT_BFF_PASSWORD",
    "tf-model": "TF_RABBIT_MODEL_PASSWORD",
    "tf-notify-email": "TF_RABBIT_EMAIL_PASSWORD",
}


def connect(user, password=None, attempts=3):
    if password is None:
        password = os.environ[PASSWORDS[user]]
    params = pika.ConnectionParameters(
        host=HOST,
        virtual_host=VHOST,
        credentials=pika.PlainCredentials(user, password),
        connection_attempts=attempts,
        retry_delay=2,
    )
    return pika.BlockingConnection(params)


def publish():
    marker = f"smoke-{int(time.time())}"
    with connect("tf-bff") as conn:
        ch = conn.channel()
        ch.confirm_delivery()
        ch.basic_publish(
            exchange="tf.notifications",
            routing_key="email",
            body=marker.encode(),
            properties=pika.BasicProperties(delivery_mode=2, content_type="text/plain"),
            mandatory=True,
        )
    print(f"OK: tf-bff published persistent message to tf.notifications/email: {marker}")
    print(f"Now restart the container and run: check {marker}")


def find(ch, queue, marker, limit=1000):
    """Берёт сообщения без подтверждения, пока не найдёт marker.
    Остальные вернутся в очередь при закрытии канала."""
    for _ in range(limit):
        method, props, body = ch.basic_get(queue=queue, auto_ack=False)
        if method is None:
            return None, None
        if body.decode(errors="replace") == marker:
            return method, props
    return None, None


def check(marker):
    failed = False

    # 1. Сообщение пережило перезапуск; потребитель отклоняет его без повторной постановки.
    with connect("tf-notify-email") as conn:
        ch = conn.channel()
        method, _ = find(ch, "tf.notify.email", marker)
        if method is None:
            print(f"FAIL: {marker} not found in tf.notify.email")
            sys.exit(1)
        print(f"OK: {marker} found in tf.notify.email after restart")
        ch.basic_reject(delivery_tag=method.delivery_tag, requeue=False)
        print("    rejected by tf-notify-email with requeue=false")

    # 2. Отклонённое сообщение оказалось в tf.dlq.
    time.sleep(1)
    with connect("admin", os.environ["TF_RABBIT_ADMIN_PASSWORD"]) as conn:
        ch = conn.channel()
        method, props = find(ch, "tf.dlq", marker)
        if method is None:
            print(f"FAIL: {marker} not found in tf.dlq")
            failed = True
        else:
            death = (props.headers or {}).get("x-death", [{}])[0]
            print(f"OK: {marker} found in tf.dlq (reason: {death.get('reason')}, queue: {death.get('queue')})")
            ch.basic_ack(delivery_tag=method.delivery_tag)

    sys.exit(1 if failed else 0)


def expect_refused(title, action):
    try:
        action()
    except ChannelClosedByBroker as e:
        if e.reply_code == 403:
            print(f"OK: {title}: access refused")
            return True
        print(f"FAIL: {title}: unexpected error {e.reply_code} {e.reply_text}")
        return False
    except AMQPConnectionError as e:
        # Неверный логин/пароль: pika сообщает об этом как об ошибке подключения.
        print(f"OK: {title}: connection refused ({type(e).__name__})")
        return True
    print(f"FAIL: {title}: action succeeded")
    return False


def deny():
    def model_publish():
        with connect("tf-model") as conn:
            ch = conn.channel()
            ch.confirm_delivery()
            ch.basic_publish("tf.notifications", "email", b"denied", mandatory=True)

    def model_read_email():
        with connect("tf-model") as conn:
            conn.channel().basic_get(queue="tf.notify.email", auto_ack=False)

    def email_read_telegram():
        with connect("tf-notify-email") as conn:
            conn.channel().basic_get(queue="tf.notify.telegram", auto_ack=False)

    def guest_login():
        connect("guest", "guest", attempts=1).close()

    results = [
        expect_refused("tf-model publishes to tf.notifications", model_publish),
        expect_refused("tf-model reads tf.notify.email", model_read_email),
        expect_refused("tf-notify-email reads tf.notify.telegram", email_read_telegram),
        expect_refused("guest logs in", guest_login),
    ]
    sys.exit(0 if all(results) else 1)


def main():
    args = sys.argv[1:]
    if args[:1] == ["publish"]:
        publish()
    elif args[:1] == ["check"] and len(args) == 2:
        check(args[1])
    elif args[:1] == ["deny"]:
        deny()
    else:
        print("Usage: publish | check <marker> | deny")
        sys.exit(1)


if __name__ == "__main__":
    main()
