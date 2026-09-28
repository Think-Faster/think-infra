"""Кто подключил бота: username Telegram → chat_id.

Бот не может написать первым, а личному пользователю Bot API не шлёт по @username — только по
chat_id. Поэтому человек указывает username в профиле Thinkfaster, открывает бота и нажимает
«Старт». tf-tg читает обновления бота (getUpdates), на /start запоминает `tg:user:<username>` =
chat_id и отвечает, что подключено; /stop или блокировка бота — связь снимается. BFF кладёт
usernames в `to.usernames`, chat_id по ним tf-tg подставляет сам при отправке.

Ключи Redis (без TTL, у tf-redis включён AOF) — их же читает tf-bff для профиля:
  tg:user:<username>  chat_id; username — в нижнем регистре, без @
  tg:bot              имя бота без @ (getMe при старте) — ссылка t.me/<бот> в профиле
  tg:chats            hash chat_id → {type, name, username}: все чаты, писавшие боту (chats.py)
  tg:updates:offset   следующий update_id — чтобы после перезапуска не разбирать обновления заново
Без Redis связи живут в памяти процесса: до перезапуска и не видны BFF.
"""
import json
import logging
import re
import threading

import telegram_bot
from settings import Settings

log = logging.getLogger('links')

USERNAME = re.compile(r'^@?([A-Za-z][A-Za-z0-9_]{4,31})$')   # правила имени пользователя Telegram
POLL_SECONDS = 25                                            # long polling getUpdates
UPDATES = ['message', 'channel_post', 'my_chat_member']

HELP = 'Этот бот присылает уведомления Thinkfaster. /start — подключить, /stop — отключить.'


class Unavailable(Exception):
    """Redis не ответил: связь неизвестна, отправку стоит повторить позже."""


def normalize(username: str) -> str | None:
    """«@Ivan_Petrov» → «ivan_petrov»; не похоже на username — None."""
    m = USERNAME.match(username.strip()) if isinstance(username, str) else None
    return m.group(1).lower() if m else None


class Links:
    def __init__(self, redis=None):
        self.r = redis
        self.mem: dict[str, str] = {}

    def get(self, username: str) -> int | None:
        key = f'tg:user:{username}'
        if self.r is None:
            value = self.mem.get(key)
        else:
            try:
                value = self.r.get(key)
            except Exception as e:
                raise Unavailable(f'Redis недоступен ({type(e).__name__})') from None
        if value is None:
            return None
        return int(value.decode() if isinstance(value, bytes) else value)

    def link(self, username: str, chat_id: int) -> None:
        self._set(f'tg:user:{username}', str(chat_id))

    def unlink(self, username: str) -> None:
        key = f'tg:user:{username}'
        self.mem.pop(key, None)
        if self.r is not None:
            self.r.delete(key)

    def bot(self, name: str) -> None:
        self._set('tg:bot', name)

    def seen(self, chat: dict) -> None:
        name = chat.get('title') or ' '.join(filter(None, (chat.get('first_name'), chat.get('last_name'))))
        value = json.dumps({'type': chat['type'], 'name': name, 'username': chat.get('username')}, ensure_ascii=False)
        if self.r is None:
            self.mem[f'tg:chats:{chat["id"]}'] = value
        else:
            self.r.hset('tg:chats', str(chat['id']), value)

    def chats(self) -> list[dict]:
        if self.r is None:
            raw = {k.split(':', 2)[2]: v for k, v in self.mem.items() if k.startswith('tg:chats:')}
        else:
            raw = {(k.decode() if isinstance(k, bytes) else k): v for k, v in self.r.hgetall('tg:chats').items()}
        return [{'chat_id': int(k), **json.loads(v)} for k, v in raw.items()]

    def offset(self) -> int:
        value = self.mem.get('tg:updates:offset') if self.r is None else self.r.get('tg:updates:offset')
        return int(value.decode() if isinstance(value, bytes) else value or 0)

    def set_offset(self, offset: int) -> None:
        self._set('tg:updates:offset', str(offset))

    def _set(self, key: str, value: str) -> None:
        self.mem[key] = value
        if self.r is not None:
            self.r.set(key, value)


def handle(update: dict, links: Links) -> tuple[int, str] | None:
    """Одно обновление бота. Возвращает (chat_id, ответ) или None, если отвечать не нужно."""
    member = update.get('my_chat_member')
    if member:
        chat, user = member.get('chat', {}), member.get('from', {})
        if chat.get('id') is not None:
            links.seen(chat)
        # Человек заблокировал бота — сообщения ему не уйдут, связь снимаем.
        if chat.get('type') == 'private' and member.get('new_chat_member', {}).get('status') == 'kicked':
            name = normalize(user.get('username') or '')
            if name and links.get(name) == chat.get('id'):
                links.unlink(name)
                log.info('связь снята: бот заблокирован')
        return None

    msg = update.get('message') or update.get('channel_post')
    if not msg or msg.get('chat', {}).get('id') is None:
        return None
    chat = msg['chat']
    links.seen(chat)
    if chat.get('type') != 'private':
        return None                               # группы и каналы — только в списке chats.py

    command = (msg.get('text') or '').split(maxsplit=1)[0].split('@')[0].lower()
    if command not in ('/start', '/stop'):
        return chat['id'], HELP
    name = normalize(msg.get('from', {}).get('username') or '')
    if not name:
        return chat['id'], ('В Telegram не задано имя пользователя. Задайте его (Настройки → Имя пользователя), '
                            'укажите то же имя в профиле Thinkfaster и снова нажмите /start.')
    if command == '/stop':
        links.unlink(name)
        log.info('связь снята по /stop')
        return chat['id'], f'Уведомления для @{name} сюда больше не придут. Включить снова — /start.'
    links.link(name, chat['id'])
    log.info('связь установлена по /start')
    return chat['id'], (f'Готово: уведомления Thinkfaster для @{name} будут приходить сюда. '
                        'Имя должно совпадать с указанным в профиле. Отключить — /stop.')


def poll(settings: Settings, links: Links, stop: threading.Event) -> None:
    """Читает обновления бота, пока не `stop`. Ошибки не роняют отправку уведомлений — только пауза."""
    wait = 5
    while not stop.is_set():
        try:
            offset = links.offset()
            reply = telegram_bot.call(settings, 'getUpdates',
                                      {'offset': offset, 'timeout': POLL_SECONDS, 'allowed_updates': UPDATES},
                                      timeout=settings.timeout + POLL_SECONDS)
            if not reply.get('ok'):
                # 409 — у бота включён webhook или обновления читает ещё один процесс с тем же токеном.
                log.warning('getUpdates: %s — снова через %d с', telegram_bot.explain(reply), wait)
                stop.wait(wait)
                wait = min(wait * 2, 300)
                continue
            for update in reply['result']:
                answer = handle(update, links)
                if answer:
                    chat_id, text = answer
                    telegram_bot.call(settings, 'sendMessage', {'chat_id': chat_id, 'text': text})
                links.set_offset(update['update_id'] + 1)
            wait = 5
        except telegram_bot.TelegramError as e:
            log.warning('getUpdates: %s — снова через %d с', e.message, wait)
            stop.wait(wait)
            wait = min(wait * 2, 300)
        except Exception as e:                        # Redis и прочее: связи подождут
            log.warning('обновления бота: %s — снова через %d с', type(e).__name__, wait)
            stop.wait(wait)
            wait = min(wait * 2, 300)
