"""Уведомление из очереди tf.notify.email: разбор и отправка письмами.

    {"schema": 1, "notice_id": "uuid", "ticket_id": 1042, "kind": "fact",
     "subject": "Загазованность: объект 5122", "text": "...",
     "to": {"emails": ["..."]}, "request_id": "e81b07c4f2a9"}
"""
from email_validator import EmailNotValidError, validate_email

import broker
import mailer
from settings import Settings


def parse(body: bytes) -> dict:
    n = broker.parse(body)
    raw = n['to'].get('emails')
    if not isinstance(raw, list) or not raw:
        raise broker.BadNotice('нет адресов почты')
    try:
        n['recipients'] = list(dict.fromkeys(
            validate_email(str(a), check_deliverability=False).normalized for a in raw))
    except EmailNotValidError:
        raise broker.BadNotice('адрес почты с ошибкой') from None
    return n


def sender(settings: Settings, send_mail=mailer.send) -> broker.Send:
    """Одно письмо на пачку до max_recipients адресатов (Gmail больше 100 не принимает)."""

    def send(n: dict, todo: list[str]):
        sent, failed, later = [], {}, []
        step = max(1, settings.max_recipients)
        for i in range(0, len(todo), step):
            chunk = todo[i:i + step]
            try:
                refused = send_mail(settings, chunk, n['subject'], n['text'])
            except mailer.MailError as e:
                if e.status == 422:                  # сервер отверг всех адресатов пачки — навсегда
                    failed.update(e.failed or {a: e.message for a in chunk})
                    continue
                rest = todo[i:]                      # сервер лёг или не принял логин — остальным тоже
                failed.update({a: e.message for a in rest})
                later += rest
                break
            failed.update(refused)
            sent += [a for a in chunk if a not in refused]
        return sent, failed, later

    return send
