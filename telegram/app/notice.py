"""Уведомление из очереди tf.notify.telegram: разбор и отправка сообщениями бота.

    {"schema": 1, "notice_id": "uuid", "ticket_id": 1042, "kind": "fact",
     "subject": "Загазованность: объект 5122", "text": "...",
     "to": {"chat_ids": [123456789, -100123, "@channel"]}, "request_id": "e81b07c4f2a9"}
"""
import broker
import telegram_bot
from settings import Settings


def parse(body: bytes) -> dict:
    n = broker.parse(body)
    raw = n['to'].get('chat_ids')
    if not isinstance(raw, list) or not raw or not all(
            isinstance(c, int) and not isinstance(c, bool) or isinstance(c, str) and c.strip() for c in raw):
        raise broker.BadNotice('нет chat_id')
    n['recipients'] = list(dict.fromkeys(str(c).strip() for c in raw))
    if len(telegram_bot.render(n['subject'], n['text'])) > telegram_bot.LIMIT:
        raise broker.BadNotice(f'тема и текст длиннее {telegram_bot.LIMIT} символов — предел Telegram')
    return n


def sender(settings: Settings, send_telegram=telegram_bot.send) -> broker.Send:
    def send(n: dict, todo: list[str]):
        later: list[str] = []
        try:
            sent, failed = send_telegram(settings, todo, n['subject'], n['text'], later=later)
        except telegram_bot.TelegramError as e:      # никому не ушло: сеть, токен бота
            return [], dict(e.failed) or {c: e.message for c in todo}, list(todo)
        return sent, failed, later

    return send
