"""Уведомление из очереди tf.notify.telegram: разбор и отправка сообщениями бота.

    {"schema": 1, "notice_id": "uuid", "ticket_id": 1042, "kind": "fact",
     "subject": "Загазованность: объект 5122", "text": "...",
     "to": {"chat_ids": [123456789, -100123, "@channel"], "usernames": ["ivan_petrov"]},
     "request_id": "e81b07c4f2a9"}

`usernames` — люди, подключившие бота (links.py): chat_id по ним подставляется при отправке.
Кто ещё не нажал «Старт» — не ушло по постоянной причине, остальным сообщение всё равно уходит.
"""
import broker
import links as tg_links
import telegram_bot
from settings import Settings

USER = 'username:'          # адресат-username в recipients: не спутать с "@канал" из chat_ids

NOT_LINKED = 'получатель не подключил бота — открыть бота и нажать «Старт»'


def parse(body: bytes) -> dict:
    n = broker.parse(body)
    chats = n['to'].get('chat_ids') or []
    names = n['to'].get('usernames') or []
    if not isinstance(chats, list) or not all(
            isinstance(c, int) and not isinstance(c, bool) or isinstance(c, str) and c.strip() for c in chats):
        raise broker.BadNotice('chat_id с ошибкой')
    if not isinstance(names, list) or not all(tg_links.normalize(u) for u in names):
        raise broker.BadNotice('username с ошибкой')
    if not chats and not names:
        raise broker.BadNotice('нет chat_id и username')
    n['recipients'] = list(dict.fromkeys(
        [str(c).strip() for c in chats] + [USER + tg_links.normalize(u) for u in names]))
    if len(telegram_bot.render(n['subject'], n['text'])) > telegram_bot.LIMIT:
        raise broker.BadNotice(f'тема и текст длиннее {telegram_bot.LIMIT} символов — предел Telegram')
    return n


def sender(settings: Settings, send_telegram=telegram_bot.send, links: tg_links.Links | None = None) -> broker.Send:
    links = links or tg_links.Links()

    def send(n: dict, todo: list[str]):
        failed: dict[str, str] = {}
        later: list[str] = []
        target: dict[str, str] = {}             # адресат → chat_id, куда реально шлём
        for r in todo:
            if not r.startswith(USER):
                target[r] = r
                continue
            try:
                chat = links.get(r[len(USER):])
            except tg_links.Unavailable as e:
                failed[r] = str(e)
                later.append(r)
                continue
            if chat is None:
                failed[r] = NOT_LINKED
            else:
                target[r] = str(chat)
        chats = list(dict.fromkeys(target.values()))
        if not chats:
            return [], failed, later

        tg_later: list[str] = []
        try:
            sent_chats, failed_chats = send_telegram(settings, chats, n['subject'], n['text'], later=tg_later)
        except telegram_bot.TelegramError as e:      # никому не ушло: сеть, токен бота
            failed.update({r: e.failed.get(c, e.message) for r, c in target.items()})
            return [], failed, later + list(target)
        sent = [r for r, c in target.items() if c in sent_chats]
        failed.update({r: failed_chats[c] for r, c in target.items() if c in failed_chats})
        later += [r for r, c in target.items() if c in tg_later]
        return sent, failed, later

    return send
