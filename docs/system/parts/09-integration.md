# Часть IX. Интеграция и изменения

Чек-листы на типовые изменения. Всё, что касается инфраструктуры, делается пулреквестом в think-infra и
применяется на **обоих** стендах.

## 9.1. Новый сервис

1. Имя контейнера `tf-<имя>`, сеть `think-fast-net` (external), порт на хост не публиковать.
2. Секреты:
   - строка `tf-<имя>  <пути>` в `hashicorp/services.conf` → `setup.sh apply` (root) на каждом стенде;
   - свои секреты — строки `app/tf-<имя>` в `secrets.conf` → `secrets.sh init`/`set`;
   - пара: `setup.sh service-credentials tf-<имя>` → Environment `dev`/`prod` репозитория. Если в репозитории
     несколько сервисов — имена секретов с префиксом сервиса.
3. Способ входа в Vault: `vault-entrypoint.sh` (без изменений кода) или AppRole в коде (tfkit, kit.go).
   Пароли не класть в compose, `.env`, образ и `${VAR:-значение}`.
4. Доступы: учётка Kafka (`secrets.conf` + `kafka/acls.conf`), RabbitMQ (`users.conf`, права только на свои
   очереди, без `configure`), схема БД (`schemas.conf` + два пароля), Redis (путь `redis`).
5. Публичный путь — `location` в `web-server/nginx/nginx.conf.template` (+ переменные хоста и порта), решить,
   срезать ли префикс, лимиты. Проверить конфиг до выкатки (4.3).
6. Проверка токенов — по PEM из `http://tf-auth:8080/.well-known/jwks`: `RS256`, `iss=auth-service`, `aud=api`,
   `typ`/`token_type=access`, `sub` — id пользователя.
7. Аудит — `XADD audit` / `audit:requests` по контракту tf-audit §4; поле `service` — из списка tf-audit.
8. Сборка — **не на сервере стенда**: CI или реестр. Healthcheck обязателен.
9. Раздел документации `docs/system/<имя>.md` по шаблону (14 разделов), затем пересобрать документ (приложение E).

## 9.2. Изменения по видам

| Изменение | Файлы think-infra | Применение | Кого предупредить |
|---|---|---|---|
| Новый секрет | `secrets.conf` | `secrets.sh init`/`set` на каждом стенде; выкатка потребителя | владельца сервиса |
| Новый путь Vault у сервиса | `hashicorp/services.conf` | `setup.sh apply` (root) | — (креды не меняются) |
| Новый топик / партиции | `kafka/topics.conf` | выкатка `kafka` | потребителей топика |
| Права Kafka | `kafka/acls.conf` | выкатка `kafka` | — |
| Очередь / exchange / права RabbitMQ | `rabbitmq/definitions.json`, `users.conf` | выкатка `rabbitmq`; удаление — вручную в брокере | издателей и потребителей |
| TTL / DLX / лимиты очередей | `definitions.json` → `policies` | выкатка `rabbitmq`, без пересоздания | — |
| Схема БД | `postgree/db/schemas.conf` + `secrets.conf` | `secrets.sh init postgree`, выкатка `postgree` | владельца схемы (миграции под `<схема>_admin`) |
| Маршрут, лимит, домен | `web-server/nginx/*.template`, `stands/*.env` | проверка `nginx -t`, выкатка `web-server` | фронт, потребителей |
| Настройка стенда | `stands/<стенд>.env` | выкатка затронутых сервисов (пуш выкатывает все) | — |
| Формат `tf.notifications` | `docs/notify-tz/tf-bff.md`, `mailing/`, `telegram/` | согласованная выкатка BFF и потребителей | tf-bff |
| Формат событий шины / `tf.ingest.*` | — (владелец tf-funnel) | обратная совместимость или версия `schema` | tf-model, шина |
| Формат `tf.forecast.results` | — (владелец tf-model) | поле `schema` | tf-bff |
| Токены (`iss`, `aud`, формат ключа, cookie) | — (владелец tf-auth) | одновременно у всех проверяющих | tf-bff, tf-funnel, tf-model, tf-audit, фронт |
| Ротация ключа подписи JWT | Vault `app/tf-auth` | `docker restart tf-auth` + потребители | пользователи будут разлогинены |

## 9.3. Интеграция внешней шины (prod)

1. **tf-auth:** выпустить учётку и долгий токен шины. Сейчас это невозможно (VII-1, VIII-4). Временная схема —
   `sub` учётки в `TF_FUNNEL_SERVICE_SUBS`, но токен живёт 10 мин.
2. **Администратор:** `sub` → Vault `app/tf-funnel` → `TF_FUNNEL_SERVICE_SUBS`, перезапуск tf-funnel; статический
   IP шины → `FUNNEL_EVENTS_ALLOW` в `stands/prod.env`, выкатка `web-server`.
3. **Шина:** `POST https://thinkfaster.ru/api/funnel/events`, `Authorization: Bearer`, пакет ≤ 8 МБ и
   ≤ 10 000 событий, формат tf-funnel §4.1. На `503` — повтор через `Retry-After`, на `422` — не повторять,
   на `429` — снизить частоту.
4. **Проверка:** `/api/funnel/health` → `accepted` растёт; `tf-model` `/api/ml/health` → свежий `last_hour`.

## 9.4. Уведомления из нового сервиса

Публиковать в `tf.notifications` с ключом `email`/`telegram` может только учётка с правом записи (сейчас
`tf-bff`). Новому издателю нужны строка в `users.conf` и пароль в `secrets.conf`. Контракт —
`docs/notify-tz/tf-bff.md`: новый `notice_id` на каждое уведомление, тот же — при повторе, адреса проверять
до публикации.
