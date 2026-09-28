# Часть VIII. Возможности доработки (сводный план)

Сведено из §12 разделов сервисов и Части VII. Объём оценён авторами разделов; «инфра» — think-infra.

## Первая очередь: безопасность и блокеры

| № | Что | Кто | Объём | Закрывает |
|---|---|---|---|---|
| 1 | `-orphan` в `setup.sh admin-token` | инфра | 0,5 ч | VII-16, кейс 3 |
| 2 | Удалить `VAULT_TOKEN` (root) из Environment `prod` think-infra и отозвать этот токен | инфра, владелец GitHub | 0,5 ч | VII-15 |
| 3 | Схема `audit`: строка в `schemas.conf`, `TF_PG_AUDIT_ADMIN/USER_PASSWORD` в `secrets.conf`, `secrets.sh init postgree`, выкатка `postgree`, прогон `schema.sql` под `audit_admin` на dev и prod; затем выкатка tf-audit | инфра + Think-Faster | 2–4 ч | VII-5 |
| 4 | Техучётки в tf-auth: `kind=service`, `scope` строкой через пробел (`telemetry.push`, `ml.read`, `audit.read`), долгий токен, выпускаемый суперпользователем; токены для шины и для BFF | tf-auth (+ BFF, шина) | 2–3 дня | VII-1 |
| 5 | Закрыть `/register` на prod (или удалить, оставить `/create`) | tf-auth | 1 ч | VII-2 |
| 6 | Достоверный IP клиента: nginx `proxy_set_header X-Forwarded-For $remote_addr` (заменить, а не дописать), в сервисах доверять только `tf-nginx` (`UseForwardedHeaders`, `TF_TRUSTED_PROXIES`) | инфра + tf-auth, tf-funnel, tfkit | 0,5 ч инфра + 2–3 ч на сервис | VII-3 |
| 7 | `POST /logout` в tf-auth (удалить cookie, отзыв refresh по `jti` в Redis) и вызов из фронта | tf-auth, tf-front | 0,5–1 день | VII-4 |
| 8 | Бэкапы вне сервера: копирование снапшотов Vault и дампов Postgres (rsync/S3), проверка восстановления раз в месяц | инфра | 0,5–1 день | VII-14 |
| 9 | `ProducerBatchMaxBytes = 1 000 000` в воронке | tf-funnel | 0,5 ч | VII-13 |

## Вторая очередь: надёжность и эксплуатация

| № | Что | Кто | Объём |
|---|---|---|---|
| 10 | `env_keep` для `tf-docker` в sudoers prod | владелец prod-сервера | 0,5 ч |
| 11 | Раннер GitHub на dev для think-infra (или официально зафиксировать ручную выкатку) | инфра | 1 ч |
| 12 | Healthcheck tf-bff (раскомментировать), проверки зависимостей в `/health` tf-auth и tf-funnel, healthcheck tf-front | сервисы | 2–4 ч |
| 13 | Метрики (Prometheus) и алерты: лаг Kafka, DLQ, такт модели, диск, сертификат, запечатанный Vault | инфра + сервисы | 2–4 дня |
| 14 | Лимиты памяти tf-auth, Kafka, Postgres; замер пикового потребления на prod | инфра + tf-auth, tf-model | 1 день |
| 15 | Сборка образов tf-auth, tf-bff, tf-front в CI с публикацией в реестр; dev-выкатка без простоя, без автослияния любой ветки в `dev` | сервисы | 1–2 дня на сервис |
| 16 | Публикация справочника объектов и каналов в `tf.ingest.reference` из tf-bff | tf-bff, tf-model | 1–2 дня |
| 17 | Аудит уведомлений: `notify.sent`/`notify.failed` из tf-mail и tf-tg в поток `audit` | инфра | 2–3 ч |
| 18 | Расписание `audit.drop_old_requests()`, срок хранения `audit.events`, уникальный ключ `audit.requests` | tf-audit + инфра | 0,5 дня |
| 19 | Закрыть PostgreSQL dev от интернета (`DB_BIND=127.0.0.1`, доступ по туннелю), `VAULT_ALLOW` на dev | инфра | 1 ч + уведомить разработчиков |
| 20 | Настоящий JWKS (`{"keys":[…]}`) с несколькими ключами по `kid` для ротации с перекрытием; PEM — отдельным путём | tf-auth + потребители | 1–2 дня |
| 21 | Воронка: таймауты сервера, лимит тела 8 МБ, кеш неудачи загрузки ключа, аудит не под общим мьютексом, обязательный `ид_события` | tf-funnel | 1 день |
| 22 | Кеш-заголовки, gzip, заголовки безопасности (CSP, HSTS) — в `tf-nginx` для всего сайта | инфра + tf-front | 0,5 дня |

## Третья очередь: развитие

| № | Что | Кто |
|---|---|---|
| 23 | Роли и права в токене или ручка прав по согласованному контракту «права-и-аудит»; положить сам контракт в общий репозиторий | tf-auth, tf-bff |
| 24 | Экран журнала аудита для главного диспетчера (BFF → tf-audit `/events` с техучёткой) | tf-bff, tf-front, tf-audit |
| 25 | Кластеризация: 3 брокера Kafka, 3 узла RabbitMQ (quorum-очереди уже готовы), реплика Postgres | инфра |
| 26 | Переобучение модели вне prod-контейнера, досчёт пропущенных часов | tf-model |
| 27 | Живой поток на экране показаний инженера | tf-front, tf-funnel |
| 28 | Удалить `docs/backend/notify` из Think-Faster (заменён tf-mail/tf-tg) | Think-Faster |
| 29 | Сократить ACL tf-bff на `tf.ingest.*`, если BFF их не читает | инфра |
| 30 | Отправка почты через HTTP API (443) как запасной путь, если закроют и 2587 | инфра |
