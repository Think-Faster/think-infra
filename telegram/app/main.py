"""tf-tg: читает очередь tf.notify.telegram и отправляет сообщения от бота Telegram.

Запуск — контейнер (docker-compose.yml), настройки — settings.py. Локально, с переменными окружения
из settings.py (TF_RABBIT_URL=amqp://localhost:5672/tf и т.д.):

    pip install -r requirements.txt
    python app/main.py

Кому слать: chat_id человека или группы. Узнать — написать боту, затем
`docker exec tf-tg python chats.py`.
"""
import logging
import signal
import sys
import threading

import broker
import notice
import settings as config
import telegram_bot

QUEUE = 'tf.notify.telegram'

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(name)s: %(message)s')
logging.getLogger('pika').setLevel(logging.WARNING)
log = logging.getLogger('tf-tg')


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
        log.info('Telegram: бот @%s — ok', telegram_bot.check(settings))
    except telegram_bot.TelegramError as e:
        if e.auth:
            # Сообщения всё равно не уйдут: очередь не читаем, пусть ждут в ней (TTL сутки).
            # Файла жизни нет — контейнер unhealthy, выкатка telegram падает с этой строкой в логе.
            log.error('%s. Исправить TF_TG_BOT_TOKEN в Vault (secret/tf/app/tf-tg) и перевыкатить telegram',
                      e.message)
            stop.wait()
            return 3
        log.warning('Telegram: %s — очередь читаю, сообщения повторятся, когда Telegram ответит', e.message)

    consumer = broker.Consumer('telegram', notice.parse, notice.sender(settings),
                               broker.Sent(broker.redis_client(settings.redis_url, settings.redis_password)),
                               settings.retries)
    broker.run(consumer, QUEUE,
               broker.parameters(settings.rabbit_url, settings.rabbit_user, settings.rabbit_password), stop)
    log.info('остановлен')
    return 0


if __name__ == '__main__':
    sys.exit(main())
