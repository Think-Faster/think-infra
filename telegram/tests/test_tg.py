"""Тесты tf-tg без сети: Telegram, брокер и Redis подменены.

    pip install -r requirements.txt -r requirements-dev.txt
    python -m pytest -q tests
"""
import json
import sys
import urllib.error
import uuid
from io import BytesIO
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'app'))

import broker  # noqa: E402
import notice  # noqa: E402
import settings as config  # noqa: E402
import telegram_bot  # noqa: E402

NID = str(uuid.uuid4())
ENV = {'TF_TG_BOT_TOKEN': '123:secret', 'TF_RABBIT_TELEGRAM_PASSWORD': 'p', 'TF_REDIS_PASSWORD': 'r'}


def message(**over) -> bytes:
    n = {'schema': 1, 'notice_id': NID, 'ticket_id': 1042, 'kind': 'fact', 'subject': 'Загазованность',
         'text': 'Канал 196771', 'to': {'chat_ids': [1, '@ch']}, 'request_id': 'e81b07c4f2a9'}
    n.update(over)
    return json.dumps(n, ensure_ascii=False).encode()


def consumer(tg):
    s = config.load(ENV)
    return broker.Consumer('telegram', notice.parse, notice.sender(s, tg), broker.Sent(), s.retries)


def test_settings():
    s = config.load(ENV)
    assert (s.rabbit_user, s.rabbit_url) == ('tf-notify-telegram', 'amqp://tf-rabbit:5672/tf')
    assert 'secret' not in repr(s)
    with pytest.raises(config.ConfigError, match='TF_TG_BOT_TOKEN'):
        config.load({**ENV, 'TF_TG_BOT_TOKEN': ' '})


def test_telegram_limit_is_permanent():
    c = consumer(lambda *a, **k: pytest.fail('не должно уйти'))
    assert c.decide(message(text='x' * 4090)) == broker.REJECT


def test_no_chats_is_permanent():
    assert consumer(None).decide(message(to={'emails': ['a@example.com']})) == broker.REJECT


def test_later_is_retried_alone():
    calls = []

    def tg(s, chats, subject, text, later=None):
        calls.append(list(chats))
        if len(calls) == 1:
            later.append('@ch')
            return ['1'], {'@ch': 'Too Many Requests — Telegram ограничил частоту отправки'}
        return list(chats), {}

    c = consumer(tg)
    assert c.decide(message()) == broker.RETRY
    assert c.decide(message(), {'x-delivery-count': 1}) == broker.ACK
    assert calls == [['1', '@ch'], ['@ch']]


def test_telegram_down_retries_everyone():
    def tg(*a, **k):
        raise telegram_bot.TelegramError(503, 'Telegram недоступен')
    assert consumer(tg).decide(message()) == broker.RETRY


class Api:
    """urlopen: ответы Bot API по порядку — (HTTP-код, тело) или исключение."""

    def __init__(self, *replies):
        self.replies, self.urls = list(replies), []

    def __call__(self, request, timeout):
        self.urls.append(request.full_url)
        step = self.replies.pop(0)
        if isinstance(step, Exception):
            raise step
        code, body = step
        raw = json.dumps(body).encode()
        if code >= 400:
            raise urllib.error.HTTPError(request.full_url, code, 'err', {}, BytesIO(raw))

        class Reply(BytesIO):
            status = code

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False
        return Reply(raw)


def test_send_reports_blocked_and_hides_token(monkeypatch):
    api = Api((200, {'ok': True, 'result': {}}),
              (403, {'ok': False, 'error_code': 403, 'description': 'Forbidden: bot was blocked by the user'}))
    monkeypatch.setattr(telegram_bot.urllib.request, 'urlopen', api)
    later = []
    sent, failed = telegram_bot.send(config.load(ENV), [1, 2], 'тема', 'текст', later=later)
    assert sent == ['1'] and 'Старт' in failed['2'] and later == []

    monkeypatch.setattr(telegram_bot.urllib.request, 'urlopen',
                        Api(urllib.error.URLError('https://api.telegram.org/bot123:secret/ refused')))
    with pytest.raises(telegram_bot.TelegramError) as e:
        telegram_bot.send(config.load(ENV), [1], 'тема', 'текст')
    assert e.value.status == 503 and 'secret' not in e.value.message


def test_bad_token_is_auth(monkeypatch):
    monkeypatch.setattr(telegram_bot.urllib.request, 'urlopen', Api((401, {'ok': False})))
    with pytest.raises(telegram_bot.TelegramError) as e:
        telegram_bot.check(config.load(ENV))
    assert e.value.auth
