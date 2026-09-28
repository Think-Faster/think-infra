# Задание: встраивание tf-funnel в стенд

Для агента и разработчиков репозитория **tf-funnel**. Файл самодостаточный — отдать целиком.
Секреты и Vault — отдельное ТЗ [docs/vault-tz/tf-funnel.md](../vault-tz/tf-funnel.md).

## 1. Как сервис встроен

```
шина (внешняя, статический IP) ──HTTPS──► nginx ── POST /api/funnel/events ──┐
фронт (браузер) ─────────────────HTTPS──► nginx ── /api/funnel/log, /stream ──┤
                                                                              ▼
                                                                  tf-funnel:8000 (сеть think-fast-net)
                                                                    │  Kafka   tf-kafka:9092  → tf.ingest.readings / journal / reference
                                                                    │  Redis   tf-redis:6379  → audit, audit:requests
                                                                    │  Vault   http://vault:8200 (AppRole tf-svc-tf-funnel)
                                                                    │  tf-auth http://tf-auth:8080/.well-known/jwks
                                                                    │  tf-bff  http://tf-bff:8080/readings/scope
                                                                    └─ том tf-funnel-data → /data (архив «Логов», спул аудита)
```

Сервис работает **в одном экземпляре** (состояние в памяти и на томе) — на стенде так и есть.

## 2. Что уже сделано в инфраструктуре

| Что | Где | Значение |
|---|---|---|
| Топики | `kafka/topics.conf` | `tf.ingest.readings` (6 партиций, 7 дней), `tf.ingest.journal` (3, 30 дней), `tf.ingest.reference` (3, compact) — lz4, сообщение ≤ 1 МБ |
| Учётка Kafka | `kafka/acls.conf` | `tf-funnel`: запись в `tf.ingest.*` и `tf.dlq`, SASL_PLAINTEXT / PLAIN |
| Vault | `hashicorp/services.conf` | AppRole `tf-svc-tf-funnel`, чтение `kafka/funnel`, `redis`, `app/tf-funnel` |
| Секреты | `secrets.conf` | `TF_KAFKA_FUNNEL_PASSWORD` (есть), `TF_REDIS_PASSWORD` (есть), `TF_FUNNEL_SERVICE_SUBS` (заводит администратор) |
| nginx | `web-server/nginx/nginx.conf.template` | маршруты `/api/funnel/*` → `tf-funnel:8000`, префикс **не срезается** (раздел 4) |

`VAULT_ROLE_ID` / `VAULT_SECRET_ID` для репозитория tf-funnel прежние — политика только расширена путём `redis`.

## 3. docker-compose сервиса

```yaml
services:
  tf-funnel:
    image: tf-funnel:${TF_TAG:-local}
    container_name: tf-funnel          # по этому имени nginx находит сервис (FUNNEL_HOST)
    restart: unless-stopped
    networks: [think-fast-net]
    # Порт 8000 на хост НЕ публиковать: снаружи — только через nginx.
    mem_limit: 512m                    # GOMEMLIMIT=400MiB в образе
    volumes:
      - tf-funnel-data:/data           # именованный том: права 10004 из образа наследуются
    environment:
      TF_ENV: prod
      VAULT_ADDR: http://vault:8200
      VAULT_ROLE_ID: ${VAULT_ROLE_ID:?VAULT_ROLE_ID is not set}
      VAULT_SECRET_ID: ${VAULT_SECRET_ID:?VAULT_SECRET_ID is not set}
      TF_VAULT_WAIT: "900"             # после перезагрузки сервера Vault запечатан, пока его не распечатают
      TF_KAFKA_BOOTSTRAP: tf-kafka:9092
      TF_REDIS_URL: redis://tf-redis:6379/0   # без пароля: сервис возьмёт его из Vault (redis)
      TF_AUDIT_SPOOL: /data/audit.spool       # не /tmp: спул должен пережить пересоздание контейнера
      TF_FUNNEL_ARCHIVE_DAYS: "14"            # 0 — хранить вечно, диск общий с Postgres, Kafka и Vault
      TF_FUNNEL_WS_ORIGINS: ${TF_FUNNEL_WS_ORIGINS:?TF_FUNNEL_WS_ORIGINS is not set}

volumes:
  tf-funnel-data:
    name: tf-funnel-data

networks:
  think-fast-net:
    external: true
```

| Настройка | dev | prod |
|---|---|---|
| `TF_FUNNEL_WS_ORIGINS` | `https://greefob.ru` | `https://thinkfaster.ru,https://www.thinkfaster.ru` |
| `TF_FUNNEL_ARCHIVE_DAYS` | `14` | `14` (уточнить по реальному потоку, раздел 7) |
| `TF_FUNNEL_PULL` | не задавать | не задавать (эмулятор только на локальном стенде) |

Остальное — значения по умолчанию сервиса (`TF_BFF_URL=http://tf-bff:8080`, `TF_AUTH_COOKIE=access_token`,
`TF_FUNNEL_PORT=8000`, `TF_KAFKA_USER=tf-funnel`). `TF_AUTH_JWKS` — см. раздел 6, пункт 1.

Запрещено: секреты в compose (пароль Redis в `TF_REDIS_URL` в том числе), `env_file` с секретами.

## 4. Публичные адреса и ограничения nginx

Домен: `greefob.ru` (dev), `thinkfaster.ru` (prod). Путь передаётся в сервис **как есть**, с `/api/funnel`.

| Адрес | Кто | Ограничения nginx |
|---|---|---|
| `POST /api/funnel/events` | шина | тело ≤ **8 МБ**, приём тела ≤ 30 с, **20 запросов/с** с адреса (всплеск 40), ответ ждётся до 60 с; при заданном `FUNNEL_EVENTS_ALLOW` — **только с IP шины**, остальным 403 |
| `GET /api/funnel/stream` | фронт, WebSocket | `Upgrade` проксируется, соединение живёт, пока идут ping (таймаут тишины 120 с) |
| `GET /api/funnel/log` | фронт | **5 запросов/с** с адреса (всплеск 10) |
| `/api/funnel/status`, `/api/funnel/health` | фронт, мониторинг | без ограничений |

Превышение частоты — `429`. nginx передаёт `Host` (исходный домен), `X-Real-IP`, `X-Forwarded-For`,
`X-Forwarded-Proto`.

## 5. Доработки в коде tf-funnel

Обязательные до prod:

1. **Ключ tf-auth.** По адресу `TF_AUTH_JWKS` сервис ждёт PEM (`kit.go:278`), а tf-auth подписывает с
   `kid: main-key` — вероятно, отдаёт JSON JWKS. Тогда **каждый запрос получит 503**. Научить `Verifier`
   разбирать JSON JWKS (`{"keys":[{"kty":"RSA","kid":…,"n":…,"e":…}]}`) с выбором ключа по `kid`;
   PEM оставить как запасной вариант.
2. **Размер батча Kafka.** `ProducerBatchMaxBytes` = 1 048 576 впритык к `max.message.bytes` топиков →
   `MESSAGE_TOO_LARGE` под нагрузкой. Поставить `1_000_000` (`funnel.go:53-66`).
3. **IP клиента за nginx.** Сейчас в аудит и журнал запросов пишется IP nginx (`http.go:26-31`). Брать
   `X-Real-IP` (или последний адрес `X-Forwarded-For`), если запрос пришёл из доверенной сети
   (`TF_TRUSTED_PROXIES`, по умолчанию сеть docker `172.16.0.0/12`).
4. **Лимит тела и таймауты сервера.** `maxBody` 64 МБ при `GOMEMLIMIT=400MiB` → риск OOM. Снизить до
   **8 МБ** (как в nginx), проверять число событий потоково; задать `ReadTimeout`, `WriteTimeout` (кроме
   `/stream`), `IdleTimeout` HTTP-сервера (`main.go:194`).

Желательные:

5. `TF_FUNNEL_ARCHIVE_DAYS` по умолчанию — не 0 (например, 14); `TF_AUDIT_SPOOL` по умолчанию — в `/data`.
6. `ид_события` обязательным (или свой id события в сообщении Kafka) — иначе потребители не отбросят
   повтор пакета после частичного сбоя Kafka.
7. Сбой tf-auth / Redis не должен тормозить приём: запоминать неудачу загрузки ключа на 30–60 с и
   использовать старый ключ после истечения кеша; `Audit.Send` — не под общим мьютексом с Flush.
8. Курсор режима pull — в `/data/pull.cursor` (только для стенда с эмулятором).
9. `/health` — отдельная проверка готовности (Kafka, ключ), метрики. Комментарий `Dockerfile:3` исправить
   на путь `kafka/funnel`. `go mod tidy`.

## 6. Открытые вопросы (зависят от других сервисов)

1. **tf-auth: формат `/.well-known/jwks`** — PEM или JSON (пункт 5.1). Пока не выяснено — не задавать
   `TF_AUTH_JWKS` и проверить на dev первым же запросом с токеном.
2. **tf-auth: claim-ы.** Сервис ждёт `aud=api`, `iss` ∈ {`auth-service`, `tf-auth`}, `typ`/`token_type`=`access`,
   `scope` — **строкой через пробел**. Сверить с тем, что выпускает tf-auth.
3. **Техучётка шины**: долгий токен от tf-auth. Если в нём `scope: "telemetry.push"` — `TF_FUNNEL_SERVICE_SUBS`
   не нужен. Если scope tf-auth не кладёт — сообщить администратору `sub` учётки шины, он заведёт его в
   Vault (`app/tf-funnel`, `TF_FUNNEL_SERVICE_SUBS`).
4. **tf-bff: `GET /readings/scope`** с ответом `{"all":bool,"objectIds":[…],"sensorIds":[…]}` должна
   существовать, иначе «Логи» и WebSocket отвечают 503.
5. **IP шины** — администратору, для `FUNNEL_EVENTS_ALLOW`.

## 7. Эксплуатация

- **Диск:** архив ~10–30 байт на событие после сжатия. 1000 событий/с ≈ 1–2,5 ГБ в сутки → 14 дней ≈
  15–35 ГБ на общем диске стенда. Сообщить администратору ожидаемый поток — от него зависит срок.
- **Перезапуск** теряет статусы молчания каналов (восстанавливаются за 3 события на канал) и подписки
  WebSocket (фронт переподключается). Архив и спул — на томе, сохраняются.
- **Выкатка:** self-hosted runner на стенде пока не подключён — workflow `deploy-funnel-dev.yml` будет
  ждать в очереди. До его появления выкатывать на сервере вручную из клона репозитория:
  `VAULT_ROLE_ID=… VAULT_SECRET_ID=… TF_FUNNEL_WS_ORIGINS=https://greefob.ru docker compose up -d --build`.

## 8. Критерии приёмки (на dev)

- [ ] `docker ps`: `tf-funnel` в сети `think-fast-net`, порт на хост не опубликован, том `tf-funnel-data` в `/data`.
- [ ] `curl https://greefob.ru/api/funnel/health` → 200.
- [ ] `POST /api/funnel/events` с токеном шины → 202; сообщения в `tf.ingest.readings`; без токена → 401.
- [ ] Пакет больше 8 МБ → 413 от nginx.
- [ ] Фронт: `wss://greefob.ru/api/funnel/stream?objectId=…` получает `ready` и `reading`, соединение живёт дольше 2 минут.
- [ ] `GET /api/funnel/log` с токеном пользователя → записи архива.
- [ ] В потоке Redis `audit:requests` — реальный IP клиента, а не адрес nginx (после пункта 5.3).
- [ ] После `docker restart tf-funnel` архив «Логов» на месте.
