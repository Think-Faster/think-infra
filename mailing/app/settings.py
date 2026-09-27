"""Настройки tf-mail — только из переменных окружения.

Секреты (secrets.conf) в контейнер подставляет scripts/deploy.sh из Vault стенда:
  secret/tf/app/tf-mail   TF_MAIL_SMTP_HOST, TF_MAIL_SMTP_PORT, TF_MAIL_SMTP_USER, TF_MAIL_SMTP_PASSWORD
  secret/tf/rabbit/email  TF_RABBIT_EMAIL_PASSWORD  (учётка брокера tf-notify-email)
  secret/tf/redis         TF_REDIS_PASSWORD
Остальное — несекретные значения по умолчанию, при необходимости задаются в docker-compose.yml.
"""
import os
from collections.abc import Mapping
from dataclasses import dataclass, field

REQUIRED = ('TF_MAIL_SMTP_HOST', 'TF_MAIL_SMTP_PORT', 'TF_MAIL_SMTP_USER', 'TF_MAIL_SMTP_PASSWORD',
            'TF_RABBIT_EMAIL_PASSWORD')


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class Settings:
    smtp_host: str
    smtp_port: int
    smtp_user: str
    smtp_password: str = field(repr=False)
    # starttls — порт 587 (Gmail), ssl — порт 465; по умолчанию выбирается по порту
    smtp_security: str = 'starttls'
    smtp_timeout: float = 15
    mail_from: str = ''                 # пусто — письма уходят от smtp_user (Gmail всё равно подставит его)
    mail_from_name: str = 'Think Faster — оповещения'
    max_recipients: int = 50            # Gmail принимает не больше 100 адресатов в одном письме

    rabbit_url: str = 'amqp://tf-rabbit:5672/tf'
    rabbit_user: str = 'tf-notify-email'
    rabbit_password: str = field(default='', repr=False)
    redis_url: str = 'redis://tf-redis:6379/0'      # off — без Redis
    redis_password: str = field(default='', repr=False)
    retries: int = 5                    # как delivery-limit политики tf-notify в rabbitmq/definitions.json

    @property
    def sender(self) -> str:
        return self.mail_from or self.smtp_user


def load(env: Mapping[str, str] = os.environ) -> Settings:
    missing = [k for k in REQUIRED if not env.get(k, '').strip()]
    if missing:
        raise ConfigError(f'не заданы {", ".join(missing)} — секреты в Vault: scripts/secrets.sh status mailing')
    try:
        port = int(env['TF_MAIL_SMTP_PORT'])
    except ValueError:
        raise ConfigError('TF_MAIL_SMTP_PORT — не число') from None
    security = env.get('MAIL_SMTP_SECURITY') or ('ssl' if port == 465 else 'starttls')
    if security not in ('starttls', 'ssl', 'none'):
        raise ConfigError('MAIL_SMTP_SECURITY: starttls, ssl или none')
    host = env['TF_MAIL_SMTP_HOST'].strip()
    password = env['TF_MAIL_SMTP_PASSWORD']
    if 'gmail' in host:
        # Google показывает пароль приложения группами через пробел: «abcd efgh ijkl mnop»
        password = password.replace(' ', '')
    return Settings(
        smtp_host=host,
        smtp_port=port,
        smtp_user=env['TF_MAIL_SMTP_USER'].strip(),
        smtp_password=password,
        smtp_security=security,
        smtp_timeout=float(env.get('MAIL_SMTP_TIMEOUT') or 15),
        mail_from=env.get('MAIL_FROM', ''),
        mail_from_name=env.get('MAIL_FROM_NAME') or Settings.mail_from_name,
        max_recipients=int(env.get('MAIL_MAX_RECIPIENTS') or 50),
        rabbit_url=env.get('TF_RABBIT_URL') or Settings.rabbit_url,
        rabbit_user=env.get('TF_RABBIT_USER') or Settings.rabbit_user,
        rabbit_password=env['TF_RABBIT_EMAIL_PASSWORD'],
        redis_url=env.get('TF_REDIS_URL') or Settings.redis_url,
        redis_password=env.get('TF_REDIS_PASSWORD', ''),
        retries=int(env.get('NOTIFY_RETRIES') or 5),
    )
