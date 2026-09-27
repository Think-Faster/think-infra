"""tf-mail: читает очередь tf.notify.email и отправляет письма через SMTP.

Запуск — контейнер (docker-compose.yml), настройки — settings.py. Локально, с переменными окружения
из settings.py (TF_RABBIT_URL=amqp://localhost:5672/tf и т.д.):

    pip install -r requirements.txt
    python app/main.py
"""
import logging
import signal
import sys
import threading

import broker
import mailer
import notice
import settings as config

QUEUE = 'tf.notify.email'

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(name)s: %(message)s')
logging.getLogger('pika').setLevel(logging.WARNING)
log = logging.getLogger('tf-mail')


def main() -> int:
    try:
        settings = config.load()
    except config.ConfigError as e:
        log.error('%s', e)
        return 2

    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())

    try:
        mailer.check(settings)
        log.info('SMTP %s:%d (%s): вход как %s — ok', settings.smtp_host, settings.smtp_port,
                 settings.smtp_security, settings.smtp_user)
    except mailer.MailError as e:
        if e.auth:
            # Письма всё равно не уйдут: очередь не читаем, пусть ждут в ней (TTL сутки), пока не исправят
            # секреты. Не выходим: перезапуск по кругу — это попытки входа подряд, Gmail за них блокирует.
            # Файла жизни нет — контейнер unhealthy, выкатка mailing падает с этой строкой в логе.
            log.error('SMTP: %s. Исправить TF_MAIL_SMTP_USER / TF_MAIL_SMTP_PASSWORD в Vault '
                      '(secret/tf/app/tf-mail) и перевыкатить mailing', e.message)
            stop.wait()
            return 3
        log.warning('SMTP: %s — очередь читаю, письма повторятся, когда сервер ответит', e.message)

    consumer = broker.Consumer('email', notice.parse, notice.sender(settings),
                               broker.Sent(broker.redis_client(settings.redis_url, settings.redis_password)),
                               settings.retries)
    broker.run(consumer, QUEUE,
               broker.parameters(settings.rabbit_url, settings.rabbit_user, settings.rabbit_password), stop)
    log.info('остановлен')
    return 0


if __name__ == '__main__':
    sys.exit(main())
