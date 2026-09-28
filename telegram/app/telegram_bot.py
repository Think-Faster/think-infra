"""Отправка сообщений через бота Telegram (Bot API, метод sendMessage)."""
import html
import json
import time
import urllib.error
import urllib.request

from settings import Settings

LIMIT = 4096  # длина одного сообщения в Telegram


class TelegramError(Exception):
    """status: 502 — Telegram не принял токен или ответил не по протоколу, 503 — недоступен."""

    def __init__(self, status: int, message: str, failed: dict[str, str] | None = None, auth: bool = False):
        super().__init__(message)
        self.status = status
        self.message = message
        self.failed = failed or {}
        self.auth = auth            # токен бота не подошёл: без правки секрета не исправится


def render(subject: str, text: str) -> str:
    return f'<b>{html.escape(subject)}</b>\n\n{html.escape(text)}'


def call(settings: Settings, method: str, body: dict, timeout: float | None = None) -> dict:
    """Запрос к Bot API. Ответ с ok=false возвращается как есть; 429 с короткой паузой — повтор.

    `timeout` — дольше обычного для long polling getUpdates (links.poll)."""
    data = _post(settings, method, body, timeout)
    retry = data.get('parameters', {}).get('retry_after')
    if data.get('error_code') == 429 and retry is not None and retry <= 5:
        time.sleep(retry)
        data = _post(settings, method, body, timeout)
    return data


def _post(settings: Settings, method: str, body: dict, timeout: float | None = None) -> dict:
    if not settings.bot_token:
        raise TelegramError(503, 'не задан TF_TG_BOT_TOKEN')
    request = urllib.request.Request(f'{settings.api_url}/bot{settings.bot_token}/{method}',
                                     data=json.dumps(body).encode(), method='POST',
                                     headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=timeout or settings.timeout) as reply:
            status, raw = reply.status, reply.read()
    except urllib.error.HTTPError as e:                  # 400, 403, 429 — ответ Bot API с описанием
        status, raw = e.code, e.read()
    except (urllib.error.URLError, OSError) as e:
        raise TelegramError(503, f'Telegram недоступен: {scrub(e, settings)}') from None
    if status in (401, 404):
        # 401 — токен отозван или с ошибкой, 404 — токен не похож на токен
        raise TelegramError(502, 'Telegram не принял токен бота: проверьте TF_TG_BOT_TOKEN', auth=True)
    try:
        return json.loads(raw)
    except ValueError:
        raise TelegramError(502 if status < 500 else 503,
                            f'Telegram ответил не по протоколу Bot API: HTTP {status}') from None


def check(settings: Settings) -> str:
    """getMe: токен подходит. Возвращает имя бота."""
    reply = call(settings, 'getMe', {})
    if not reply.get('ok'):
        raise TelegramError(502, explain(reply))
    return reply['result'].get('username', '')


def send(settings: Settings, chats: list[int | str], subject: str, text: str,
         later: list[str] | None = None) -> tuple[list[str], dict[str, str]]:
    """Шлёт сообщение в каждый чат по очереди. Возвращает, куда ушло и куда нет с причиной.

    `later` — если передан, сюда же попадают чаты, которым не ушло по временной причине (сеть,
    частота, сбой у Telegram): их стоит повторить позже.
    """
    payload = {'text': render(subject, text), 'parse_mode': 'HTML', 'link_preview_options': {'is_disabled': True}}
    sent: list[str] = []
    failed: dict[str, str] = {}
    for i, chat in enumerate(chats):
        try:
            reply = call(settings, 'sendMessage', {**payload, 'chat_id': chat})
        except TelegramError as e:
            # сеть легла или не тот токен: остальным тоже не уйдёт, ждать таймаут на каждого незачем
            failed.update({str(c): e.message for c in chats[i:]})
            if later is not None:
                later.extend(str(c) for c in chats[i:])
            if not sent:
                raise TelegramError(e.status, e.message, failed, e.auth) from None
            break
        if reply.get('ok'):
            sent.append(str(chat))
        else:
            failed[str(chat)] = explain(reply)
            if later is not None and (reply.get('error_code') or 0) in (429, 500, 502, 503, 504):
                later.append(str(chat))
    return sent, failed


def explain(reply: dict) -> str:
    code = reply.get('error_code')
    description = reply.get('description', 'неизвестная ошибка')
    if code == 403:
        return f'{description} — получатель должен открыть бота и нажать «Старт»'
    if code == 400 and 'chat not found' in description:
        return f'{description} — неверный chat_id или получатель ещё не писал боту'
    if code == 429:
        return f'{description} — Telegram ограничил частоту отправки'
    return description


def scrub(error: Exception, settings: Settings) -> str:
    """Текст ошибки без токена бота: он входит в адрес запроса."""
    text = str(error)
    if settings.bot_token:
        text = text.replace(settings.bot_token, '***')
    return text or type(error).__name__
