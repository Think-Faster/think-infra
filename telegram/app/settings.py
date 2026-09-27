"""Настройки tf-tg — только из переменных окружения.

Секреты (secrets.conf) в контейнер подставляет scripts/deploy.sh из Vault стенда:
  secret/tf/app/tf-tg        TF_TG_BOT_TOKEN  (токен бота от @BotFather)
  secret/tf/rabbit/telegram  TF_RABBIT_TELEGRAM_PASSWORD  (учётка брокера tf-notify-telegram)
  secret/tf/redis            TF_REDIS_PASSWORD
Остальное — несекретные значения по умолчанию, при необходимости задаются в docker-compose.yml.
"""
import os
from collections.abc import Mapping
from dataclasses import dataclass, field

REQUIRED = ('TF_TG_BOT_TOKEN', 'TF_RABBIT_TELEGRAM_PASSWORD')


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class Settings:
    bot_token: str = field(repr=False)
    api_url: str = 'https://api.telegram.org'
    timeout: float = 15

    rabbit_url: str = 'amqp://tf-rabbit:5672/tf'
    rabbit_user: str = 'tf-notify-telegram'
    rabbit_password: str = field(default='', repr=False)
    redis_url: str = 'redis://tf-redis:6379/0'      # off — без Redis
    redis_password: str = field(default='', repr=False)
    retries: int = 5                    # как delivery-limit политики tf-notify в rabbitmq/definitions.json


def load(env: Mapping[str, str] = os.environ) -> Settings:
    missing = [k for k in REQUIRED if not env.get(k, '').strip()]
    if missing:
        raise ConfigError(f'не заданы {", ".join(missing)} — секреты в Vault: scripts/secrets.sh status telegram')
    return Settings(
        bot_token=env['TF_TG_BOT_TOKEN'].strip(),
        api_url=env.get('TG_API_URL') or Settings.api_url,
        timeout=float(env.get('TG_TIMEOUT') or 15),
        rabbit_url=env.get('TF_RABBIT_URL') or Settings.rabbit_url,
        rabbit_user=env.get('TF_RABBIT_USER') or Settings.rabbit_user,
        rabbit_password=env['TF_RABBIT_TELEGRAM_PASSWORD'],
        redis_url=env.get('TF_REDIS_URL') or Settings.redis_url,
        redis_password=env.get('TF_REDIS_PASSWORD', ''),
        retries=int(env.get('NOTIFY_RETRIES') or 5),
    )
