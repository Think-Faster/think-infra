"""Кто писал боту за последние сутки — отсюда берут chat_id получателей.

    docker exec tf-tg python chats.py

Человек должен сам открыть бота и нажать «Старт», группа — добавить бота и написать в ней.
"""
import json
import sys

import settings as config
import telegram_bot


def main() -> int:
    try:
        chats = telegram_bot.recent_chats(config.load())
    except (config.ConfigError, telegram_bot.TelegramError) as e:
        print(f'ошибка: {e}', file=sys.stderr)
        return 1
    if not chats:
        print('за сутки боту никто не писал', file=sys.stderr)
    for chat in chats:
        print(json.dumps(chat, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
