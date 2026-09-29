"""Кто писал боту и кто подключил уведомления — отсюда берут chat_id групп и каналов.

    docker exec tf-tg python chats.py

Обновления бота читает сам tf-tg (links.poll), поэтому список — из Redis, а не из getUpdates:
второй читатель getUpdates получил бы 409. Человек подключается сам: username в профиле
Thinkfaster и «Старт» у бота. Группа — добавить бота и написать в ней сообщение.
"""
import json
import sys

import broker
import links as tg_links
import settings as config


def main() -> int:
    try:
        settings = config.load()
    except config.ConfigError as e:
        print(f'ошибка: {e}', file=sys.stderr)
        return 1
    links = tg_links.Links(broker.redis_client(settings.redis_url, settings.redis_password))
    try:
        chats = links.chats()
        rows = []
        for chat in chats:
            name = tg_links.normalize(chat.get('username') or '')
            linked = chat['type'] == 'private' and name is not None and links.get(name) == chat['chat_id']
            rows.append({**chat, 'linked': linked})
    except Exception as e:
        print(f'ошибка: Redis недоступен ({type(e).__name__})', file=sys.stderr)
        return 1
    if not rows:
        print('боту пока никто не писал', file=sys.stderr)
    for row in rows:
        print(json.dumps(row, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
