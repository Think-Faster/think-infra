"""Чтение очереди уведомлений из RabbitMQ (rabbitmq/README.md, раздел «Уведомления»).

Одинаковый файл в mailing/app и telegram/app — менять оба.

BFF публикует в exchange `tf.notifications` с ключом `email` или `telegram`, сообщение ложится в
очередь `tf.notify.email` или `tf.notify.telegram`. Ответ брокеру:
- ack — отправлено. Кому-то могло не уйти по постоянной причине (адрес отвергнут, бот заблокирован):
  это `notify.sent` с числом отказов;
- reject без повтора — сообщение не разобрать или оно не ушло никому по постоянной причине:
  `tf.dlq` и `notify.failed`;
- nack с повтором — почта или Telegram недоступны; с паузой. На последней попытке
  (`x-delivery-count` кворумной очереди) — reject и `notify.failed`.

Повтор не шлёт второй раз тем, кому уже ушло: отправленное по `notice_id` помнится сутки в Redis
(`notify:sent:<notice_id>:<канал>`). Лёг Redis — рассылка идёт с памятью процесса: второе письмо
лучше, чем ни одного. В лог — события `notify.sent` / `notify.failed` без текста и адресов.
"""
import json
import logging
import threading
import time
import uuid
from collections.abc import Callable
from pathlib import Path

log = logging.getLogger('broker')
ACK, REJECT, RETRY = 'ack', 'reject', 'retry'
BACKOFF = (5, 15, 30, 60)               # секунд до повтора по номеру попытки
DAY = 86_400
# Файл жизни: обновляется, пока есть соединение с брокером. По нему — HEALTHCHECK в Dockerfile.
HEARTBEAT = Path('/tmp/tf-alive')


class BadNotice(ValueError):
    """Сообщение, которое никогда не отправится: сразу в DLQ."""


def parse(body: bytes) -> dict:
    """Общие поля уведомления. Адресатов разбирает сервис своего канала."""
    try:
        n = json.loads(body)
    except (UnicodeDecodeError, ValueError):
        raise BadNotice('не JSON') from None
    if not isinstance(n, dict):
        raise BadNotice('не объект')
    try:
        n['notice_id'] = str(uuid.UUID(str(n.get('notice_id'))))
    except ValueError:
        raise BadNotice('notice_id не uuid') from None
    subject, text = n.get('subject'), n.get('text')
    if not isinstance(subject, str) or not subject.strip() or len(subject) > 255:
        raise BadNotice('тема пустая или длиннее 255')
    if not isinstance(text, str) or not text.strip() or len(text) > 20000:
        raise BadNotice('текст пустой или длиннее 20000')
    n['subject'] = ' '.join(subject.split())        # перевод строки в теме ломает заголовки письма
    if not isinstance(n.get('to'), dict):
        n['to'] = {}
    ticket = n.get('ticket_id')
    n['ticket_id'] = None if ticket in (None, '') else str(ticket)
    return n


class Sent:
    """Кому уже ушло по `notice_id`: сутки в Redis, а без Redis — в памяти процесса."""

    def __init__(self, redis=None):
        self.r = redis
        self.mem: dict[str, tuple[float, set]] = {}

    @staticmethod
    def key(nid: str, channel: str) -> str:
        return f'notify:sent:{nid}:{channel}'

    def get(self, nid: str, channel: str) -> set[str]:
        k = self.key(nid, channel)
        if self.r is not None:
            try:
                got = self.r.smembers(k)
                return {x.decode() if isinstance(x, bytes) else x for x in got} | self._mem(k)
            except Exception as e:
                log.warning('Redis недоступен (%s): повтор без защиты от второй отправки', type(e).__name__)
        return self._mem(k)

    def _mem(self, k: str) -> set[str]:
        at, got = self.mem.get(k, (0.0, set()))
        return set(got) if time.time() - at < DAY else set()

    def add(self, nid: str, channel: str, recipients: list[str]) -> None:
        if not recipients:
            return
        k, now = self.key(nid, channel), time.time()
        self.mem[k] = (now, self._mem(k) | set(recipients))
        if len(self.mem) > 10_000:
            self.mem = {x: v for x, v in self.mem.items() if now - v[0] < DAY}
        if self.r is not None:
            try:
                p = self.r.pipeline()
                p.sadd(k, *recipients)
                p.expire(k, DAY)
                p.execute()
            except Exception as e:
                log.warning('Redis недоступен (%s): отправленное помню только в памяти', type(e).__name__)


# send(notice, todo) -> (кому ушло, {кому не ушло: причина}, кому повторить позже)
Send = Callable[[dict, list[str]], tuple[list[str], dict[str, str], list[str]]]


class Consumer:
    """Одна очередь — один канал. Логика без pika: её проверяют тесты.

    `parse(body)` — уведомление с полем `recipients` или BadNotice; `send` — см. Send.
    """

    def __init__(self, channel: str, parse: Callable[[bytes], dict], send: Send, sent: Sent, retries: int = 5):
        self.channel, self.parse, self.send, self.sent, self.retries = channel, parse, send, sent, retries
        self.attempts: dict[str, int] = {}

    def decide(self, body: bytes, headers: dict | None = None) -> str:
        try:
            n = self.parse(body)
        except BadNotice as e:
            log.warning('%s: сообщение не разобрано (%s) — в DLQ', self.channel, e)
            self._event('notify.failed', None, reason=str(e))
            return REJECT
        nid = n['notice_id']
        done = self.sent.get(nid, self.channel)
        todo = [r for r in n['recipients'] if r not in done]
        if not todo:
            log.info('уведомление %s уже отправлено — повтор подтверждён без отправки', nid)
            self.attempts.pop(nid, None)
            return ACK
        attempt = max(self.attempts.get(nid, 0), int((headers or {}).get('x-delivery-count') or 0)) + 1
        self.attempts[nid] = attempt
        try:
            sent, failed, later = self.send(n, todo)
        except Exception as e:                       # неожиданное — как временная ошибка
            log.exception('уведомление %s: сбой отправки', nid)
            sent, failed, later = [], {r: type(e).__name__ for r in todo}, list(todo)
        self.sent.add(nid, self.channel, sent)
        total_sent = len(done) + len(sent)
        if later:
            if attempt < self.retries:
                log.warning('уведомление %s: попытка %d из %d, не ушло %d — повтор', nid, attempt,
                            self.retries, len(later))
                return RETRY
            self.attempts.pop(nid, None)
            self._event('notify.failed', n, sent=total_sent, failed=len(later),
                        reason=_first(failed, later), attempt=attempt)
            return REJECT
        self.attempts.pop(nid, None)
        if total_sent:
            self._event('notify.sent', n, sent=total_sent, failed=len(failed), attempt=attempt)
            return ACK
        self._event('notify.failed', n, sent=0, failed=len(failed), reason=_first(failed, todo), attempt=attempt)
        return REJECT

    def _event(self, event: str, n: dict | None, **details) -> None:
        """Событие в лог: канал, число адресатов, тема, заявка, причина. Текста и адресов нет."""
        d = {'channel': self.channel}
        if n is not None:
            d.update(notice_id=n['notice_id'], ticket_id=n.get('ticket_id'), kind=n.get('kind'),
                     request_id=n.get('request_id'), subject=n['subject'], recipients=len(n['recipients']))
        d.update(details)
        (log.info if event == 'notify.sent' else log.warning)('%s %s', event, json.dumps(d, ensure_ascii=False))

    def delay(self, body: bytes) -> float:
        try:
            n = self.attempts.get(str(uuid.UUID(str(json.loads(body).get('notice_id')))), 1)
        except Exception:
            n = 1
        return BACKOFF[min(n, len(BACKOFF)) - 1]

    def on_message(self, conn, ch, method, props, body) -> None:
        verdict = self.decide(body, getattr(props, 'headers', None))
        tag = method.delivery_tag
        if verdict == ACK:
            ch.basic_ack(tag)
        elif verdict == REJECT:
            ch.basic_reject(tag, requeue=False)
        else:
            conn.call_later(self.delay(body), lambda: ch.basic_nack(tag, requeue=True))


def _first(failed: dict, among: list) -> str:
    """Причина без адреса: у SMTP она бывает с адресом внутри, поэтому только код ответа."""
    for r in among:
        if r in failed:
            return str(failed[r]).split(' ', 1)[0] if str(failed[r])[:3].isdigit() else str(failed[r])[:200]
    return ''


def parameters(url: str, user: str, password: str):
    """Адрес брокера и vhost — из url (amqp://tf-rabbit:5672/tf), учётка — отдельно."""
    import pika
    params = pika.URLParameters(url)
    params.credentials = pika.PlainCredentials(user, password)
    params.heartbeat, params.blocked_connection_timeout = 60, 300
    return params


def redis_client(url: str, password: str):
    """Клиент Redis для Sent; url=off — без Redis (память процесса)."""
    if not url or url == 'off':
        return None
    import redis
    return redis.Redis.from_url(url, password=password or None, socket_timeout=2, socket_connect_timeout=2)


def run(consumer: Consumer, queue: str, params, stop: threading.Event) -> None:
    """Читает очередь до `stop`: переподключение с паузой до 60 с, файл жизни — пока есть соединение."""
    import pika
    wait = 2
    while not stop.is_set():
        conn = None
        try:
            conn = pika.BlockingConnection(params)
            ch = conn.channel()
            ch.queue_declare(queue, passive=True)       # прав configure нет: очередь заводит tf.infra/rabbitmq
            ch.basic_qos(prefetch_count=1)
            ch.basic_consume(queue, lambda c, m, p, b: consumer.on_message(conn, c, m, p, b))
            log.info('RabbitMQ: читаю %s', queue)
            wait = 2
            while not stop.is_set():
                HEARTBEAT.touch()
                conn.process_data_events(time_limit=1)
        except pika.exceptions.AMQPError as e:
            log.warning('RabbitMQ %s: %s — снова через %d с', queue, type(e).__name__, wait)
            stop.wait(wait)
            wait = min(wait * 2, 60)
        finally:
            if conn is not None and conn.is_open:
                try:
                    conn.close()
                except pika.exceptions.AMQPError:
                    pass
