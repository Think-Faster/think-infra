"""Отправка письма через SMTP."""
import smtplib
import ssl
from collections.abc import Iterator
from contextlib import contextmanager
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid

from settings import Settings


class MailError(Exception):
    """status: 422 — сервер отверг адресатов (навсегда), 502 — отверг логин или отправителя,
    503 — сервер недоступен. Всё, кроме 422, — повод повторить позже."""

    def __init__(self, status: int, message: str, failed: dict[str, str] | None = None, auth: bool = False):
        super().__init__(message)
        self.status = status
        self.message = message
        self.failed = failed or {}
        self.auth = auth            # не подошли логин и пароль: без правки секретов не исправится


def build(settings: Settings, to: list[str], subject: str, text: str) -> EmailMessage:
    msg = EmailMessage()
    msg['From'] = formataddr((settings.mail_from_name, settings.sender))
    msg['To'] = ', '.join(to)
    msg['Subject'] = subject
    msg['Date'] = formatdate(localtime=True)
    msg['Message-ID'] = make_msgid(domain=settings.sender.rpartition('@')[2] or None)
    msg.set_content(text)
    return msg


@contextmanager
def connect(settings: Settings) -> Iterator[smtplib.SMTP]:
    """Соединение с сервером после входа. Ошибки smtplib — MailError."""
    context = ssl.create_default_context()
    try:
        if settings.smtp_security == 'ssl':
            smtp = smtplib.SMTP_SSL(settings.smtp_host, settings.smtp_port,
                                    timeout=settings.smtp_timeout, context=context)
        else:
            smtp = smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=settings.smtp_timeout)
        with smtp:
            if settings.smtp_security == 'starttls':
                smtp.starttls(context=context)
            if settings.smtp_user:
                smtp.login(settings.smtp_user, settings.smtp_password)
            yield smtp
    # исключения smtplib — наследники OSError, поэтому они перехватываются раньше
    except smtplib.SMTPAuthenticationError:
        raise MailError(502, 'почтовый сервер не принял логин и пароль. '
                             'Для Gmail нужен пароль приложения, а не пароль от почты', auth=True) from None
    except smtplib.SMTPRecipientsRefused as e:
        raise MailError(422, 'почтовый сервер отверг всех адресатов', reasons(e.recipients)) from None
    except smtplib.SMTPSenderRefused as e:
        raise MailError(502, f'почтовый сервер отверг отправителя: {e.smtp_code} {decode(e.smtp_error)}') from None
    except smtplib.SMTPException as e:
        raise MailError(502, f'ошибка почтового сервера: {e}') from None
    except OSError as e:
        raise MailError(503, f'почтовый сервер {settings.smtp_host}:{settings.smtp_port} недоступен: {e}') from None


def check(settings: Settings) -> None:
    """Вход без отправки: при старте видно, что адрес, логин и пароль подходят."""
    with connect(settings):
        pass


def send(settings: Settings, to: list[str], subject: str, text: str) -> dict[str, str]:
    """Отправляет одно письмо всем адресатам. Возвращает тех, кого сервер отверг, с причиной.

    Принятое сервером письмо ещё не доставлено: о несуществующем ящике Gmail
    сообщает позже, письмом на адрес отправителя.
    """
    msg = build(settings, to, subject, text)
    with connect(settings) as smtp:
        refused = smtp.send_message(msg)
    return reasons(refused)


def reasons(refused: dict[str, tuple[int, bytes]]) -> dict[str, str]:
    return {address: f'{code} {decode(message)}' for address, (code, message) in refused.items()}


def decode(message: bytes | str) -> str:
    return message.decode(errors='replace') if isinstance(message, bytes) else message
