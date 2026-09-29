# Часть VII. Сквозной анализ: несоответствия и риски

Здесь сведено то, что видно только при чтении всех разделов вместе: расхождения между сервисами, пробелы
в контрактах и риски эксплуатации. Приоритет: **К** — критично (блокирует функцию или угрожает безопасности
prod), **В** — высокий, **С** — средний, **Н** — низкий.

| № | Тема | Суть | Затронуты | Приоритет |
|---|---|---|---|---|
| 1 | Техучётки | tf-auth выпускает только пользовательские токены: `kind: user`, без `scope`, access живёт 10 мин, refresh — через cookie. Шине нечем получить долгий токен для `POST /events`: `TF_FUNNEL_SERVICE_SUBS` снимает проверку права, но не срок жизни токена. tf-model (`/forecast`, `/history`) и tf-audit (`/events`) проверяют `kind` раньше списка `*_SERVICE_SUBS`, поэтому обход через список у них **не работает вообще** | tf-auth, tf-funnel, tf-model, tf-audit, шина, tf-bff | **К** |
| 2 | Открытая регистрация | `POST /api/auth/register` доступен всем на prod. Без профиля в BFF новая учётка данных не увидит (`user_not_provisioned`), но это лишняя поверхность атаки: засорение таблицы, перебор, блокировка чужих логинов через лимит | tf-auth, nginx | **К** |
| 3 | IP клиента | nginx *дописывает* адрес к присланному клиентом `X-Forwarded-For`. tf-auth берёт из него первый адрес для аудита, а его подделывает клиент. Лимит входа tf-auth, аудит tf-funnel и tf-model видят адрес nginx. В итоге IP в журналах недостоверен, а лимит входа работает как блокировка по логину, и любой может заблокировать чужой логин | nginx, tf-auth, tf-funnel, tf-model, tf-audit | **В** |
| 4 | Выход из системы | **Закрыто 29.09:** `POST /api/auth/logout` в tf-auth `prod` (ветка `TF-Auth-Logout`). Раздел tf-auth в Части III написан до этого. Остаётся: refresh-токен не отзывается на сервере и действует до `exp` | tf-auth, tf-front | **Н** |
| 5 | Схема `audit` не заведена | Роль Vault `tf-svc-tf-audit` есть, а схемы, ролей БД и `postgres/audit` в `secrets.conf` нет. tf-audit на dev и prod не стартует. Потоки Redis копятся до `MAXLEN ~1 млн` и при долгом простое обрезаются: события теряются | think-infra, tf-audit | **В** |
| 6 | Формат ключа и ротация | `/.well-known/jwks` отдаёт PEM, а не JWKS. Ключ один, `kid` фиксированный. Ротация разлогинивает всех, а потребители держат старый ключ в кеше до 1 ч (tf-funnel, tfkit) или 60 мин (tf-bff) и всё это время отвергают новые токены | tf-auth, все проверяющие токены | **С** |
| 7 | Роли и права | В tf-auth одно право — `SuperUser`, роли ведёт BFF (RBAC). Контракт — концепт [Think-Faster: docs/common/права-и-аудит.md](https://github.com/GroznyiBombila/Think-Faster/blob/main/docs/common/права-и-аудит.md) (агенты сервисов его не нашли); реализация от него отходит: нет `scope` у техучёток и области видимости в грантах. Создание учётки (`/auth/create`) требует `SuperUser` в tf-auth, который выдаётся только SQL-запросом | tf-auth, tf-bff, tf-front | **С** |
| 8 | Справочник модели | tf-model ждёт строки `object`/`channel` в `tf.ingest.reference`, но их никто не публикует: воронка пишет туда только `channel.status`. Новые объекты и датчики попадут в модель только с новым образом. Логичный издатель — tf-bff: он владеет объектами и датчиками | tf-model, tf-bff, tf-funnel | **С** |
| 9 | Дубли событий | При частичном подтверждении Kafka воронка отвечает `503`, шина повторяет пакет, и подтверждённая часть уходит повторно. `ид_события` необязателен. Дубли отбрасывает только модель (по ключу `channel, ts, value`), другие потребители их не отличат | tf-funnel, шина, будущие потребители | **С** |
| 10 | Аудит уведомлений | tf-mail и tf-tg пишут `notify.sent`/`notify.failed` только в свой лог, а в поток `audit` — нет. tf-audit знает сервис `notify` (по старой заготовке `docs/backend/notify`) и ждёт от него событий | tf-mail, tf-tg, tf-audit | **С** |
| 11 | Дубликат сервиса уведомлений | В Think-Faster осталась заготовка `docs/backend/notify` (`tf-notify`). На стендах её заменили `tf-mail` и `tf-tg` из think-infra, но в описаниях аудита она фигурирует как активный источник. Если её выкатить, она будет читать те же очереди | Think-Faster, think-infra | **Н** |
| 12 | Лишние права Kafka | tf-bff имеет ACL на чтение `tf.ingest.journal/readings/reference`, но читает только `tf.forecast.results`. Схема в разделе tf-funnel показывает BFF читателем ingest-топиков — это не так | think-infra, tf-bff | **Н** |
| 13 | Батч Kafka воронки | `ProducerBatchMaxBytes` = 1 048 576 впритык к `max.message.bytes` топиков: под нагрузкой возможен `MESSAGE_TOO_LARGE`. Правка в одну строку не сделана | tf-funnel | **В** |
| 14 | Бэкапы | Снапшоты Vault и дампы Postgres лежат на том же сервере. При потере диска теряется всё, включая возможность расшифровать Vault. Бэкапа архива воронки и тома модели нет | think-infra | **В** |
| 15 | Root в GitHub | `deploy-apps-prod.yml` умеет брать root из `VAULT_TOKEN` Environment `prod`. Бессрочный root в GitHub даёт полный доступ к prod-Vault любому, кто может изменить workflow в ветке `prod`. Пары сервисов уже разложены, root там не нужен | think-infra, GitHub | **К** (пока секрет не удалён) |
| 16 | Личный токен без `-orphan` | `setup.sh admin-token` создаёт токен, дочерний к root. Инструкции требуют отзывать root, и личный токен пропадает вместе с ним | think-infra | **В** |
| 17 | Выкатка на prod из репозиториев | Обёртка `tf-docker` через `sudo` сбрасывает `VAULT_*`. Выкатки tf-auth и tf-bff из GitHub на prod не проходят без `env_keep` в sudoers | prod-сервер, tf-auth, tf-bff | **С** |
| 18 | PostgreSQL dev открыт в интернет | `DB_BIND=0.0.0.0` на dev: база доступна с любого адреса, защита — только пароль | think-infra | **С** |
| 19 | Vault UI dev без allowlist | `vault.greefob.ru` открыт всем, защита — токен и лимит попыток входа | think-infra | **Н** |
| 20 | Нет наблюдаемости | Метрик нет ни у одного сервиса. `/health` tf-auth и tf-funnel не проверяет зависимости, healthcheck tf-bff закомментирован, у tf-front его нет. Централизованных логов и алертов нет | все | **С** |
| 21 | Память prod | tf-model 2,5 ГБ, tf-funnel 512 МБ, tf-bff 512 МБ, RabbitMQ 1 ГБ; у tf-auth, Kafka, Postgres лимита нет, а Argon2 берёт 64 МБ на каждый вход. Пиковое потребление на prod не измерено | prod | **С** |
| 22 | Процесс dev-выкатки | tf-auth, tf-bff, tf-front сливают **любую** ветку в `dev` при пуше и выкатывают с простоем (`down → build --no-cache → up`); сборка идёт на dev-VM (кейс 1) | tf-auth, tf-bff, tf-front | **С** |
| 23 | Эмулятор на dev | ТЗ воронки think-infra считало эмулятор только локальным, фактически он работает на dev. Это нормально, ТЗ нужно обновить. На prod эмулятор запрещён, и это соблюдается | think-infra, tf-emulator | **Н** |
| 24 | Метка окружения фронта | На экране входа prod написано `development`: `REACT_APP_*` не передаются в сборку | tf-front | **Н** |
| 25 | `/status` воронки и `/api/ml/status` | Доступны любому вошедшему пользователю. Там номера молчащих каналов, настройки и пороги модели | tf-funnel, tf-model | **Н** |
| 26 | Настройки модели передаются не все | На `prod` BFF передаёт модели `model.switch`, `settings.operating`, `settings.gaps` (ручки `/model-commands/*`, `ModelSettingsRelay.cs`). **Не передаются** `settings.works` (график работ хранится в BFF, модель берёт свою копию из пакета) и `retrain.request`. Старые таблицы BFF (`coefficients`, `model-versions`, `ignored-ranges`) дублируют состояние модели и расходятся с ним | tf-bff, tf-model, tf-front | **С** |

## Что совместимо (проверено сверкой)

- **Уведомления.** Поля, которые шлёт tf-bff, совпадают с тем, что разбирают tf-mail и tf-tg. BFF шлёт одно
  письмо на каждого адресата со своим `notice_id`, Telegram — одним сообщением на все чаты.
- **Токены.** PEM из `/.well-known/jwks` понимают tf-bff, tf-funnel, tf-model и tf-audit. `iss=auth-service`,
  `aud=api`, `typ`/`token_type=access` у выпускающего и проверяющих совпадают. Cookie `access_token` с `Path=/`
  доходит до `/api/funnel/stream`.
- **Команды модели.** Конверт tf-bff совпадает с разбором tf-model. Ключ маршрута — `kind`, у exchange
  `tf.model.commands` привязка `#`.
- **Kafka.** Группы `tf-model-ingest` и `tf-bff-facts` попадают под ACL с префиксами `tf-model` и `tf-bff`.
- **Права «Логов».** Ответ BFF `GET /readings/scope` `{all, objectIds, sensorIds}` совпадает с тем, что ждут
  воронка и фронт.
- **Секреты AppRole.** `secret_id` у всех ролей бессрочные (`secret_id_ttl=0`). После перезагрузки
  контейнеры войдут в Vault с теми же парами (открытый вопрос tf-auth № 8 закрыт).
- **Сеть `postgree_app-network`.** Её создаёт compose `postgree`, так что на стенде с выкатанным `postgree`
  она есть (открытый вопрос tf-auth № 6). Но tf-auth она не нужна: `tf-postgres` доступен в `think-fast-net`.
