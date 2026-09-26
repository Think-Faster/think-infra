# ТЗ: перевод сервисов на секреты из Vault

По файлу на репозиторий — отдать агенту/разработчику сервиса целиком, файл самодостаточный
(скрипт `vault-entrypoint.sh` вставлен в конец):

| Сервис | ТЗ | Пути в Vault |
|---|---|---|
| tf-bff | [tf-bff.md](tf-bff.md) | `postgres/bff`, `kafka/bff`, `rabbit/bff`, `redis`, `app/tf-bff` |
| tf-auth | [tf-auth.md](tf-auth.md) | `postgres/auth`, `redis`, `app/tf-auth` |
| tf-funnel | [tf-funnel.md](tf-funnel.md) | `kafka/funnel`, `redis`, `app/tf-funnel` |
| tf-model | think-faster `ML/INTEGRATION.md` §13.5 | `kafka/model`, `rabbit/model`, `redis`, `app/tf-model` |
| tf-notify | think-faster `ML/INTEGRATION.md` §13.5 | `rabbit/email`, `rabbit/telegram`, `redis`, `app/tf-notify` |
| tf-audit | think-faster `ML/INTEGRATION.md` §13.5 | `postgres/audit`, `redis`, `app/tf-audit` |

Исходник скрипта: [../vault-entrypoint.sh](../vault-entrypoint.sh). Какие пути разрешены сервису —
[../../hashicorp/services.conf](../../hashicorp/services.conf).

## Новый сервис

1. Строка в `hashicorp/services.conf`: `<сервис>  <пути>`.
2. На каждом стенде с root-токеном: `hashicorp/scripts/setup.sh apply`,
   затем `hashicorp/scripts/setup.sh service-credentials <сервис>` → `VAULT_ROLE_ID` / `VAULT_SECRET_ID`
   в GitHub Environment `dev` / `prod` репозитория сервиса.
3. ТЗ — копия [tf-funnel.md](tf-funnel.md) (самое короткое) с путями и настройками нового сервиса.
