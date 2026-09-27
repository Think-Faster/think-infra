"""Тесты tf-mail без сети: почтовый сервер, брокер и Redis подменены.

    pip install -r requirements.txt -r requirements-dev.txt
    python -m pytest -q tests
"""
import json
import logging
import sys
import uuid
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'app'))

import broker  # noqa: E402
import mailer  # noqa: E402
import notice  # noqa: E402
import settings as config  # noqa: E402

NID = str(uuid.uuid4())
TEXT = 'Канал 196771 «Газовая охрана». Заявка 1042.'
ENV = {'TF_MAIL_SMTP_HOST': 'smtp.gmail.com', 'TF_MAIL_SMTP_PORT': '587', 'TF_MAIL_SMTP_USER': 'bot@example.com',
       'TF_MAIL_SMTP_PASSWORD': 'abcd efgh ijkl mnop', 'TF_RABBIT_EMAIL_PASSWORD': 'p', 'TF_REDIS_PASSWORD': 'r'}


@pytest.fixture(autouse=True)
def info_logs(caplog):
    caplog.set_level(logging.INFO)


def settings(**over) -> config.Settings:
    s = config.load(ENV)
    return config.Settings(**{**s.__dict__, 'max_recipients': 2, **over})


def message(**over) -> bytes:
    n = {'schema': 1, 'notice_id': NID, 'ticket_id': 1042, 'kind': 'fact', 'subject': 'Загазованность:\nобъект 5',
         'text': TEXT, 'to': {'emails': ['A@Example.com', 'b@example.com', 'c@example.com']},
         'request_id': 'e81b07c4f2a9'}
    n.update(over)
    return json.dumps(n, ensure_ascii=False).encode()


class Mail:
    """Почтовый сервер: `plan` — что вернуть на каждый вызов (dict отказов или MailError)."""

    def __init__(self, *plan):
        self.plan, self.calls = list(plan), []

    def __call__(self, s, to, subject, text):
        self.calls.append(list(to))
        step = self.plan.pop(0) if self.plan else {}
        if isinstance(step, Exception):
            raise step
        return step


def consumer(mail=None, sent=None, **over):
    s = settings(**over)
    return broker.Consumer('email', notice.parse, notice.sender(s, mail or Mail()), sent or broker.Sent(), s.retries)


# ----- настройки ---------------------------------------------------------------------------------
def test_settings_from_env():
    s = config.load(ENV)
    assert (s.smtp_security, s.smtp_password, s.sender) == ('starttls', 'abcdefghijklmnop', 'bot@example.com')
    assert config.load({**ENV, 'TF_MAIL_SMTP_PORT': '465'}).smtp_security == 'ssl'
    assert 'abcd' not in repr(s) and 'rabbit_password' not in repr(s)


def test_settings_missing_secret():
    with pytest.raises(config.ConfigError, match='TF_MAIL_SMTP_PASSWORD'):
        config.load({**ENV, 'TF_MAIL_SMTP_PASSWORD': ''})


def test_smtp_login_refused(monkeypatch):
    import smtplib

    class Server:
        def __init__(self, *a, **k):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def starttls(self, context):
            pass

        def login(self, user, password):
            raise smtplib.SMTPAuthenticationError(535, b'bad credentials')

    monkeypatch.setattr(smtplib, 'SMTP', Server)
    with pytest.raises(mailer.MailError) as e:
        mailer.check(settings())
    assert e.value.auth and e.value.status == 502


# ----- разбор сообщения ----------------------------------------------------------------------------
@pytest.mark.parametrize('body, why', [
    (b'{', 'не JSON'), (message(notice_id='42'), 'notice_id'), (message(to={'emails': []}), 'нет адресов'),
    (message(to={'chat_ids': [1]}), 'нет адресов'), (message(to={'emails': ['не адрес']}), 'с ошибкой'),
    (message(subject=' '), 'тема'),
])
def test_bad_message_goes_to_dlq(body, why, caplog):
    assert consumer().decide(body) == broker.REJECT
    assert 'notify.failed' in caplog.text and why in caplog.text


# ----- отправка ------------------------------------------------------------------------------------
def test_mail_in_chunks_and_log_has_no_addresses(caplog):
    mail = Mail({}, {})
    assert consumer(mail).decide(message()) == broker.ACK
    assert mail.calls == [['A@example.com', 'b@example.com'], ['c@example.com']]
    line = next(r.getMessage() for r in caplog.records if 'notify.sent' in r.getMessage())
    d = json.loads(line.split(' ', 1)[1])
    assert d == {'channel': 'email', 'notice_id': NID, 'ticket_id': '1042', 'kind': 'fact',
                 'request_id': 'e81b07c4f2a9', 'subject': 'Загазованность: объект 5', 'recipients': 3,
                 'sent': 3, 'failed': 0, 'attempt': 1}
    assert '@' not in caplog.text and 'Канал' not in caplog.text


def test_retry_sends_only_the_rest():
    mail = Mail({}, mailer.MailError(503, 'недоступен'), {})
    c = consumer(mail)
    assert c.decide(message()) == broker.RETRY
    assert c.delay(message()) == broker.BACKOFF[0]
    assert c.decide(message(), {'x-delivery-count': 1}) == broker.ACK
    assert mail.calls[-1] == ['c@example.com']


def test_refused_chunk_is_permanent(caplog):
    refused = mailer.MailError(422, 'отверг всех', {'A@example.com': '550 x', 'b@example.com': '550 y'})
    assert consumer(Mail(refused, {})).decide(message()) == broker.ACK
    assert '"sent": 1, "failed": 2' in caplog.text


def test_nobody_reached_goes_to_dlq():
    assert consumer(Mail(*[mailer.MailError(422, 'отверг всех')] * 2)).decide(message()) == broker.REJECT


def test_last_attempt_rejects(caplog):
    c = consumer(Mail(*[mailer.MailError(503, 'недоступен')] * 9))
    assert c.decide(message(), {'x-delivery-count': 4}) == broker.REJECT
    assert '"attempt": 5' in caplog.text and '"reason": "недоступен"' in caplog.text


def test_duplicate_delivery_is_not_sent_again():
    class Redis:                       # общий Redis переживает перезапуск сервиса
        def __init__(self):
            self.sets = {}

        def smembers(self, k):
            return {x.encode() for x in self.sets.get(k, set())}

        def pipeline(self):
            outer = self

            class P:
                def sadd(self, k, *v):
                    outer.sets.setdefault(k, set()).update(v)

                def expire(self, k, ttl):
                    assert ttl == broker.DAY

                def execute(self):
                    pass
            return P()

    r = Redis()
    assert consumer(Mail(), broker.Sent(r)).decide(message()) == broker.ACK
    again = Mail()
    assert consumer(again, broker.Sent(r)).decide(message()) == broker.ACK and again.calls == []


def test_sent_survives_redis_outage():
    class Down:
        def smembers(self, k):
            raise ConnectionError

        def pipeline(self):
            raise ConnectionError

    s = broker.Sent(Down())
    s.add(NID, 'email', ['a@example.com'])
    assert s.get(NID, 'email') == {'a@example.com'}


def test_reason_has_no_address():
    assert broker._first({'a@example.com': '550 5.1.1 <a@example.com> unknown'}, ['a@example.com']) == '550'


def test_on_message_answers_broker():
    class Ch:
        def __init__(self):
            self.log = []

        def basic_ack(self, tag):
            self.log.append(('ack', tag))

        def basic_reject(self, tag, requeue):
            self.log.append(('reject', tag, requeue))

        def basic_nack(self, tag, requeue):
            self.log.append(('nack', tag, requeue))

    class Conn:
        def call_later(self, delay, fn):
            fn()

    method, props = SimpleNamespace(delivery_tag=7), SimpleNamespace(headers=None)
    for mail, want in ((Mail(), ('ack', 7)), (Mail(mailer.MailError(503, 'x')), ('nack', 7, True))):
        ch = Ch()
        consumer(mail).on_message(Conn(), ch, method, props, message(notice_id=str(uuid.uuid4())))
        assert ch.log == [want]
    ch = Ch()
    consumer().on_message(Conn(), ch, method, props, b'{')
    assert ch.log == [('reject', 7, False)]


def test_rabbit_parameters():
    p = broker.parameters('amqp://tf-rabbit:5672/tf', 'tf-notify-email', 'p')
    assert (p.host, p.virtual_host, p.credentials.username) == ('tf-rabbit', 'tf', 'tf-notify-email')
    assert broker.redis_client('off', 'r') is None
