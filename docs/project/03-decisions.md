# 3. Принятые решения, включая отброшенные

Для каждого решения указано: что выбрано, что рассматривалось и отброшено, почему, какой метод
получился в итоге и где он описан или реализован. Номера (Р-N) используются в остальных документах.

Первичные журналы решений, из которых собран этот перечень:
- проектный план — [Think-Faster: tasks/plan.md §4, §10](https://github.com/Think-Faster/Think-Faster/blob/main/tasks/plan.md);
- журнал исследования модели — [ML/results/analytics.md](https://github.com/Think-Faster/Think-Faster/blob/main/ML/results/analytics.md), таблица статусов в начале;
- вводные по модели — [ML/вводные.md](https://github.com/Think-Faster/Think-Faster/blob/main/ML/вводные.md);
- особые решения — [docs/документация.md §5.6, §6](https://github.com/Think-Faster/Think-Faster/blob/main/docs/документация.md);
- решения BFF — [think-bff: BFF/docs/DECISIONS.md](https://github.com/Think-Faster/think-bff/blob/prod/BFF/docs/DECISIONS.md);
- инфраструктура — история коммитов [think-infra@dev](https://github.com/Think-Faster/think-infra/commits/dev) и [SYSTEM.md, Часть VI](../system/SYSTEM.md).

## 3.1. Контур и архитектура

| № | Решение | Отброшено | Почему | Итоговый метод | Где |
|---|---|---|---|---|---|
| Р-1 | Сервисный контур: отдельные сервисы за одним nginx | монолит на FastAPI (план 16.09) | разные языки и владельцы частей, независимая выкатка, требование ТЗ §14 «решение — отдельный сервис или компонент» | 9 контейнеров приложений + инфраструктура в одной docker-сети | [SYSTEM.md 1.2–1.3](../system/SYSTEM.md) |
| Р-2 | Без сервиса `dispatch` | `dispatch` разводит тревоги в BFF, почту и Telegram (схема 18.09) | адреса дежурных и заявки живут в BFF, промежуточный сервис дублировал бы данные | BFF сам создаёт заявку и публикует уведомление по факту | [BFF DECISIONS.md «Событие по факту»](https://github.com/Think-Faster/think-bff/blob/prod/BFF/docs/DECISIONS.md) |
| Р-3 | Уведомления — через очередь RabbitMQ | SMTP прямо из BFF; HTTP-ручки сервиса уведомлений с JWT | повторы, DLQ и дедуп без потери писем, BFF не ждёт почтовый сервер | `tf.notifications` → `tf-mail` / `tf-tg` | [BFF DECISIONS.md «Пересмотр… письма через RabbitMQ»](https://github.com/Think-Faster/think-bff/blob/prod/BFF/docs/DECISIONS.md), [think-infra: mailing/](https://github.com/Think-Faster/think-infra/tree/dev/mailing) |
| Р-4 | Почта и Telegram — два сервиса | один `tf-notify` на два канала (заготовка `docs/backend/notify`) | независимые отказы (почта без Telegram и наоборот), свои учётки брокера и секреты | `tf-mail`, `tf-tg`; общий модуль очереди | [think-infra: mailing/app/broker.py](https://github.com/Think-Faster/think-infra/blob/dev/mailing/app/broker.py) |
| Р-5 | Kafka для потока, RabbitMQ для команд и уведомлений | всё в одном брокере | поток показаний — журнал с хранением и повторным чтением (Kafka); команды и письма — ровно одному получателю с подтверждением (RabbitMQ) | топики `tf.ingest.*`, `tf.forecast.results`; очереди `tf.model.commands`, `tf.notify.*` | [kafka/topics.conf](https://github.com/Think-Faster/think-infra/blob/dev/kafka/topics.conf), [rabbitmq/definitions.json](https://github.com/Think-Faster/think-infra/blob/dev/rabbitmq/definitions.json) |
| Р-6 | Приём потока — HTTP-ручка воронки, дальше Kafka | шина пишет прямо в Kafka; отдельный `analyzer` | шине проще HTTPS с токеном; воронка проверяет события и отмечает молчание каналов | `POST /api/funnel/events` → `tf.ingest.*` | [docs/backend/funnel/](https://github.com/Think-Faster/Think-Faster/tree/main/docs/backend/funnel) |
| Р-7 | Живые показания фронту — WebSocket воронки | WebSocket через `dispatch` или BFF | данные уже в воронке, без лишнего перехода | `WSS /api/funnel/stream` | [funnel/stream.go](https://github.com/Think-Faster/Think-Faster/blob/main/docs/backend/funnel/stream.go) |
| Р-8 | Одна база PostgreSQL, по схеме на сервис | два контейнера (аудит отдельно, план 18.09) | один сервер, одна выкатка и бэкап; изоляция достигается ролями схем | `tf-postgres`, схемы `auth`, `bff`, `audit`, роли `_admin`/`_user` | [postgree/](https://github.com/Think-Faster/think-infra/tree/dev/postgree) |
| Р-9 | Оперативный контур, архив и витрины — вне PostgreSQL | схемы `ops/archive/marts` с 313 млн строк в PostgreSQL | ретропрогоны в PostgreSQL заняли бы часы, в DuckDB — секунды; модели нужен только горячий журнал | горячий журнал DuckDB (100 суток), архив — файлы, витрина — Parquet | [02. Архитектура 2.5](02-architecture.md) |
| Р-10 | Версии модели — пакет в образе и `manifest.json` | MLflow, feature store, Airflow, Kubernetes | избыточны для одного сервиса модели и одного сервера | пакет модели (`bundle.py`), переключение командой `model.switch` | [ML/INTEGRATION.md §6, §13.6](https://github.com/Think-Faster/Think-Faster/blob/main/ML/INTEGRATION.md) |
| Р-11 | Собственные часы такта модели | APScheduler, Celery | такт должен переживать перезапуск и не повторяться (раньше было 120 сообщений в час) | `clock.py`: граница часа МСК + 120 с, отметка в `clock.json` | [ML/service/clock.py](https://github.com/Think-Faster/Think-Faster/blob/main/ML/service/clock.py) |
| Р-12 | Фронт на Create React App и React 19, окна по правам | React 18 + Vite; MapLibre и ECharts из плана | сделано в CRA, внешние библиотеки карты и графиков не понадобились | сетка окон, окно видно по правам | [app/ARCHITECTURE.md](https://github.com/Think-Faster/think-front/blob/prod/app/ARCHITECTURE.md) |

## 3.2. Безопасность и доступ

| № | Решение | Отброшено | Почему | Итоговый метод | Где |
|---|---|---|---|---|---|
| Р-13 | JWT RS256, access 10 мин + refresh 24 ч в HttpOnly-cookie | сессии на сервере; токен в localStorage | проверка в каждом сервисе без похода в tf-auth; cookie недоступна скриптам | `access_token`, `refresh_token` | [TokenService.cs](https://github.com/Think-Faster/think-auth/blob/prod/AuthService/AuthService.Cryptography/Services/TokenService.cs) |
| Р-14 | В токене только id и логин, права — в BFF | роли в токене | смена прав действует без перевыпуска токенов | RBAC BFF с кешем | [права-и-аудит.md §1–2](https://github.com/Think-Faster/Think-Faster/blob/main/docs/common/права-и-аудит.md) |
| Р-15 | RBAC «группа × ресурс × маска действий», дерево групп | 4 фиксированные роли в коде; варианты 1, 3, 4 концепта | новые ресурсы и роли — данными, без выката; вложенность групп | `access_grants`, `group_closure` | [01. Авторизация 1.3](01-auth.md), [02 2.6](02-architecture.md) |
| Р-16 | Область видимости по дереву объектов — задел, не реализована | реализовать сразу | нужна проверка во всех сервисах, иначе либо ничего не меняет, либо отрезает инженеров от данных | исключение — `/readings/scope` для «Логов» | [домены-и-сущности.md §13.8](https://github.com/Think-Faster/Think-Faster/blob/main/docs/backend/домены-и-сущности.md) |
| Р-17 | Открытый ключ отдаётся PEM по `/.well-known/jwks` | стандартный JSON JWKS | так сделано в tf-auth; потребители (BFF, tfkit, воронка) приведены к PEM | PEM, кеш 1 ч | [BFF DECISIONS.md «AUTH_JWKS_URL отдаёт PEM»](https://github.com/Think-Faster/think-bff/blob/prod/BFF/docs/DECISIONS.md) |
| Р-18 | Техучётки через `scope` в токене — концепт, временно список `sub` | долгие токены без прав | принимающему сервису не нужна своя база прав | `TF_*_SERVICE_SUBS` в Vault до появления `scope` | [права-и-аудит.md §2](https://github.com/Think-Faster/Think-Faster/blob/main/docs/common/права-и-аудит.md) |
| Р-19 | LDAP/AD — контроллер домена в инфраструктуре, вход через каталог — следующий шаг | полная интеграция на хакатоне | каталога заказчика нет | Samba AD в `think-infra/samba`, схема учёток «вариант В» | [01. Авторизация 1.7](01-auth.md) |
| Р-20 | Секреты только в Vault, у каждого сервиса своя роль | `.env` на серверах; GitHub Secrets; Vault в dev-режиме (в памяти) | утечки через git и файлы; dev-Vault терял секреты при перезапуске | Vault raft, AppRole `tf-svc-*`, распечатывание 2 из 3 ключей | [hashicorp/README.md](https://github.com/Think-Faster/think-infra/blob/dev/hashicorp/README.md) |
| Р-21 | Три способа доставки секрета в контейнер | единый entrypoint для всех | .NET-сервисы не меняют код (entrypoint), Python/Go-сервисы ходят в Vault сами, сервисы инфраструктуры получают переменные при выкатке | `deploy.sh`, `vault-entrypoint.sh`, tfkit/kit.go | [SYSTEM.md 2.3](../system/SYSTEM.md) |
| Р-22 | Веб-интерфейс Vault — поддомен через nginx | открыть порт Vault; оставить только SSH-туннель | не перезапускать Vault (запечатается) и не менять выданные `role_id`; TLS снимает nginx | `https://vault.greefob.ru`, лимит входа | [web-server/nginx/vault.conf.template](https://github.com/Think-Faster/think-infra/blob/dev/web-server/nginx/vault.conf.template) |
| Р-23 | Наружу только nginx; лимиты и allowlist на nginx | лимиты в каждом сервисе | единая точка защиты: размер тела, частота, IP шины | `client_max_body_size 8m`, `limit_req`, `FUNNEL_EVENTS_ALLOW` | [nginx.conf.template](https://github.com/Think-Faster/think-infra/blob/dev/web-server/nginx/nginx.conf.template) |

## 3.3. Аудит

| № | Решение | Отброшено | Почему | Итоговый метод | Где |
|---|---|---|---|---|---|
| Р-24 | Два журнала: действий и запросов | один журнал на всё | разная ценность и срок хранения (год против 90 дней) | `audit.events`, `audit.requests` | [права-и-аудит.md §6.1](https://github.com/Think-Faster/Think-Faster/blob/main/docs/common/права-и-аудит.md) |
| Р-25 | Доставка через поток Redis | HTTP `POST /audit/events` | сервис не ждёт аудит; если аудит лежит, события ждут в потоке | `XADD audit`, группа `audit-writer` | [docs/backend/audit/audit.py](https://github.com/Think-Faster/Think-Faster/blob/main/docs/backend/audit/audit.py) |
| Р-26 | Журнал неизменяем на уровне базы | только права роли | триггеры запрещают `UPDATE`/`DELETE`/`TRUNCATE` всем, включая владельца | `audit.forbid_change()` | [docs/backend/audit/schema.sql](https://github.com/Think-Faster/Think-Faster/blob/main/docs/backend/audit/schema.sql) |
| Р-27 | Протухший токен не пишется в журнал действий | писать каждый отказ | обновление раз в 10 минут у каждого пользователя забило бы журнал | только строка `401` в журнале запросов | [права-и-аудит.md §6.2](https://github.com/Think-Faster/Think-Faster/blob/main/docs/common/права-и-аудит.md) |
| Р-28 | Хэш-цепочка записей не делается | цепочка для доказательства неизменности | для хакатона избыточна; неизменность дают триггеры | — | там же, §6.6 |

## 3.4. Данные и разметка

| № | Решение | Отброшено | Почему | Итоговый метод | Где |
|---|---|---|---|---|---|
| Р-29 | Разметка восстанавливается по журналу | ждать журнал ОДС и реестр оборудования | организаторы их не дадут (ответы 12–13) | эпизод = сработки одного типа с паузой ≤ 1 ч; шум размечается отдельно | [ML/pipeline/labels.py](https://github.com/Think-Faster/Think-Faster/blob/main/ML/pipeline/labels.py), [results/labels.md](https://github.com/Think-Faster/Think-Faster/blob/main/ML/results/labels.md) |
| Р-30 | 2021 год исключён | обучать на всех семи годах | две системы мониторинга работали параллельно (ответ 6); семь лет вместо трёх дают ±0,005 | обучение 2022–2024, проверка 2025, тест 2026 | [analytics.md §4](https://github.com/Think-Faster/Think-Faster/blob/main/ML/results/analytics.md) |
| Р-31 | Флаг «тревожное» не используется | брать как метку | его смысл меняется по годам: 7 % у «Обнаружен дым» в 2023-м, 100 % в 2026-м | метки по справочнику состояний | [документация.md §4.1](https://github.com/Think-Faster/Think-Faster/blob/main/docs/документация.md) |
| Р-32 | Погода не входит в модель | Open-Meteo: осадки, давление, влажность, снег, грунт, расход реки | 11 пар моделей из 12 не лучше без погоды | — | [analytics.md §1, §2, §5](https://github.com/Think-Faster/Think-Faster/blob/main/ML/results/analytics.md) |
| Р-33 | Загазованность — шестой тип сверх ТЗ | слить с пожаром | своя реакция (вентиляция, а не пожарный расчёт); 600 эпизодов испортили бы пожар | 6 типов прогноза | [документация.md §1.1](https://github.com/Think-Faster/Think-Faster/blob/main/docs/документация.md) |
| Р-34 | Карта — сгенерированные линейные объекты по пикетам + развёртка коллектора | реальные координаты | московская система координат наружу не выдаётся (ответ 19) | пикет = 10 м, слои карты в BFF | [домены-и-сущности.md §13.2–13.3](https://github.com/Think-Faster/Think-Faster/blob/main/docs/backend/домены-и-сущности.md) |

## 3.5. Модель

| № | Решение | Отброшено | Почему | Итоговый метод | Где |
|---|---|---|---|---|---|
| Р-35 | Мера выбора — ложные часы при равной полноте | F1, ROC-AUC, PR-AUC, число сигналов | тревога горит часами; PR-AUC этого не видит, число сигналов вознаграждает гладкую оценку | сравнение в ложных часах + свежие поимки | [analytics.md §34, §40](https://github.com/Think-Faster/Think-Faster/blob/main/ML/results/analytics.md) |
| Р-36 | Своя модель каждому типу, 5 зёрен | одна модель на все типы; LightGBM из плана | одно зерно меняет результат до 2,5 раза | CatBoost ×5 (пожар, газ, подтопление, проникновение), XGBoost ×5 (датчик), смесь CatBoost + TCN (оборудование) | [документация.md §4.5](https://github.com/Think-Faster/Think-Faster/blob/main/docs/документация.md) |
| Р-37 | Нейросеть TCN только у отказа оборудования | сеть у всех типов; окна 336 и 72 ч; ежемесячное переобучение сети | у остальных типов вровень или хуже бустинга; переобучение теряет свежие поимки | 4 версии оборудования для главного диспетчера | [документация.md §5.5–5.6](https://github.com/Think-Faster/Think-Faster/blob/main/docs/документация.md) |
| Р-38 | Порог — скользящая доля часов под тревогой | фиксированный порог по F1; пороги по объектам | фиксированный промахивается в 0–4,4 раза; пороги по объектам дают втрое больше ложных | квантиль оценок парка за 90 суток на долю `share` | [ML/settings/operating.md](https://github.com/Think-Faster/Think-Faster/blob/main/ML/settings/operating.md) |
| Р-39 | Канал «по факту» рядом с прогнозом | только прогноз | прогноз теряет часть эпизодов; вместе с фактами порог поднимается, ложных на 65–85 % меньше | объявление на 10-й минуте эпизода, полнота 99,8 % | [analytics.md §10, §15](https://github.com/Think-Faster/Think-Faster/blob/main/ML/results/analytics.md) |
| Р-40 | Настройки таблицами главного диспетчера, а не переобучением | переобучать при каждой смене условий | переобучение по ТЗ — по согласованию (§8); таблицы действуют со следующего часа | доли и `reject_k`, график работ, игнорируемые периоды, версия типа | [документация.md §6.3](https://github.com/Think-Faster/Think-Faster/blob/main/docs/документация.md) |
| Р-41 | Дообучение выключено по умолчанию | дообучение поверх прошлой модели (`warm`); ежемесячное | `warm` даёт втрое больше ложных; признаки не дрейфуют чаще раза в 150 суток | `retrain.request` при `TF_MODEL_RETRAIN=on`, скользящее окно по типам | [analytics.md §13, §19](https://github.com/Think-Faster/Think-Faster/blob/main/ML/results/analytics.md) |
| Р-42 | Молчание по графику работ | учить модель на отметке работ; подавлять по косвенному признаку | график снимает 45–59 % ложных часов газа без потерь | `MUTED` с причиной и ссылкой на строку графика | [analytics.md §62](https://github.com/Think-Faster/Think-Faster/blob/main/ML/results/analytics.md) |
| Р-43 | Правило отклонения только у газа и подтопления | у всех типов | у остальных добавляет пропусков больше, чем убирает ложных | `reject_k = 0,2` у газа и подтопления | [analytics.md §43–46](https://github.com/Think-Faster/Think-Faster/blob/main/ML/results/analytics.md) |
| Р-44 | Уверенность — изотоническая калибровка | конформные предсказания; сырая оценка | конформные отброшены с обоснованием; калиброванная доля читается буквально | `confidence` из `calibration.json` | [analytics.md §6, §17](https://github.com/Think-Faster/Think-Faster/blob/main/ML/results/analytics.md) |
| Р-45 | Рекомендации — словарь правил, не модель | генерировать моделью | прозрачность, номер правила и обоснование у каждой меры | 70 правил, режимы «прогноз» и «по факту» | [analytics.md §61](https://github.com/Think-Faster/Think-Faster/blob/main/ML/results/analytics.md) |
| Р-46 | Срочный прогноз на 6 ч не ставится | второй контур на 6 ч | прибавка меньше 5 % или выгоднее поднять долю суточного | суточный горизонт 24 ч | [документация.md §5.6](https://github.com/Think-Faster/Think-Faster/blob/main/docs/документация.md) |
| Р-47 | Сглаживание, предел длины тревоги, вторая ступень — не ставятся | ставить | проверены, не окупаются | склейка тревог 6 ч | [документация.md §4.7](https://github.com/Think-Faster/Think-Faster/blob/main/docs/документация.md) |

## 3.6. Инфраструктура и выкатка

| № | Решение | Отброшено | Почему | Итоговый метод | Где |
|---|---|---|---|---|---|
| Р-48 | Стенд = ветка, выкатка из GitHub Actions на self-hosted runner | ручные `docker compose` на сервере | воспроизводимость и ревью | `deploy-<сервис>.yml` → `scripts/deploy.sh` | [scripts/deploy.sh](https://github.com/Think-Faster/think-infra/blob/dev/scripts/deploy.sh) |
| Р-49 | Образы не собираются на слабом dev-сервере | сборка по SSH на сервере | сборка Go-образа исчерпала память и положила стенд 27.09 | сборка в CI, доставка `docker save`/Docker Hub | [SYSTEM.md, кейс 1](../system/SYSTEM.md) |
| Р-50 | Почта prod — Resend на порту 2587 | Gmail SMTP 587/465; HTTP API почтового сервиса | хостинг prod режет 25/465/587; 2587 открыт, код не меняется | `smtp.resend.com:2587`, `MAIL_FROM=noreply@thinkfaster.ru` | [mailing/README.md](https://github.com/Think-Faster/think-infra/blob/dev/mailing/README.md) |
| Р-51 | Сертификат Let's Encrypt с автопродлением, поддомены — в тот же сертификат | отдельные сертификаты | одна процедура продления | certbot webroot, `DOMAIN_ALIASES`, `VAULT_DOMAIN` | [web-server/](https://github.com/Think-Faster/think-infra/tree/dev/web-server) |
| Р-52 | Эмулятор на dev, на prod — никогда | эмулятор только локально | на dev нет шины; на prod он записал бы тестовые данные в prod-Kafka | `TF_FUNNEL_PULL` только на dev | [SYSTEM.md, tf-emulator](../system/SYSTEM.md) |
| Р-53 | Один путь выкатки каждого сервиса | воронка и модель из двух репозиториев с разными параметрами | конфликтующие параметры пересоздавали бы контейнер | воронка и модель — только из Think-Faster | [deploy-apps-prod.yml](https://github.com/Think-Faster/think-infra/blob/dev/.github/workflows/deploy-apps-prod.yml) |
