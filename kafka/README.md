# tf-kafka

Один брокер Apache Kafka 4.0 в режиме KRaft (без ZooKeeper) в сети `think-fast-net`.
Kafka здесь — шина потоков данных: показания, журнал диспетчера, справочники, прогнозы, DLQ.
Команды и уведомления в Kafka не идут, они в `tf-rabbitmq`. Бизнес-логики в контейнере нет.

## Состав

| Файл | Назначение |
|---|---|
| `docker-compose.yml` | `tf-kafka` — брокер; `tf-kafka-init` — одноразовый контейнер, создаёт топики и права |
| `topics.conf` | Декларативный список топиков (партиции, хранение, сжатие) |
| `acls.conf` | Права сервисов на топики и группы консьюмеров |
| `scripts/init.sh` | Применяет `topics.conf` и `acls.conf`, идемпотентен |
| `scripts/healthcheck.sh` | Брокер отвечает и контроллер KRaft выбран |
| `scripts/client-config.sh` | Генерирует файл настроек клиента для CLI-утилит |
| `scripts/smoke-test.sh` | Ручная проверка критериев приёмки |

## Запуск

### 1. Секреты — в Vault

Все секреты Kafka лежат в Vault стенда по пути `secret/tf/kafka`, файла `.env` с паролями нет.
Список — в [secrets.conf](../secrets.conf), общий порядок работы — в [README.md](../README.md).

| Переменная | Что это |
|---|---|
| `KAFKA_CLUSTER_ID` | ID кластера KRaft. Создаётся **один раз** до первого запуска и больше не меняется |
| `TF_KAFKA_ADMIN_PASSWORD` | Пароль суперпользователя `admin` (брокер, init, обслуживание) |
| `TF_KAFKA_FUNNEL_PASSWORD` | Пароль пользователя `tf-funnel` |
| `TF_KAFKA_MODEL_PASSWORD` | Пароль пользователя `tf-model` |
| `TF_KAFKA_BFF_PASSWORD` | Пароль пользователя `tf-bff` |

Сгенерировать недостающие (на сервере стенда, из корня репозитория):

```bash
scripts/secrets.sh init kafka
```

Если `KAFKA_CLUSTER_ID` поменяется после первого запуска, брокер не стартует на старом томе
(`Invalid cluster.id`), поэтому `secrets.sh rotate` для него запрещён.

### 2. Выкатка

Обычно — GitHub Actions: изменения в `kafka/` при пуше в `dev`/`prod` выкатываются на свой стенд
(`.github/workflows/deploy-kafka.yml`). Вручную на сервере:

```bash
docker network create think-fast-net   # если сети ещё нет
TF_INFRA_DIR=<каталог инфраструктуры> VAULT_TOKEN=<токен> scripts/deploy.sh kafka
```

`deploy.sh` читает секреты из Vault, поднимает `tf-kafka` и ждёт завершения `tf-kafka-init`
(итог — список топиков в логе).

Для ручных команд `docker compose` в папке `kafka` сначала загрузить секреты в оболочку:

```bash
eval "$(../scripts/secrets.sh env kafka)"
docker compose up tf-kafka-init
```

`tf-kafka-init` ждёт, пока healthcheck брокера станет `healthy`, применяет конфиги и завершается с кодом 0.
Статус `Exited (0)` у него — это норма. Повторный запуск ничего не пересоздаёт, данные не теряются.

Данные лежат в именованном томе `tf-kafka-data` и переживают `docker compose down` и пересоздание контейнера.
Удаляет их только `docker compose down -v` или `docker volume rm tf-kafka-data`.

## Подключение сервисов

| Параметр | Значение |
|---|---|
| `bootstrap.servers` | `tf-kafka:9092` (только из `think-fast-net`) |
| `security.protocol` | `SASL_PLAINTEXT` |
| `sasl.mechanism` | `PLAIN` |
| Пользователь | `tf-funnel`, `tf-model` или `tf-bff` |
| Пароль | `TF_KAFKA_<СЕРВИС>_PASSWORD` из Vault (`scripts/secrets.sh get TF_KAFKA_BFF_PASSWORD`) |
| `group.id` | должен начинаться с имени сервиса: `tf-model`, `tf-bff-journal` и т.п. |
| Сжатие у продюсера | `lz4` (как у топиков, иначе брокер будет пережимать) |
| Размер сообщения | не больше 1 МБ |

Права (из `acls.conf`):

| Сервис | Читает | Пишет |
|---|---|---|
| `tf-funnel` | — | `tf.ingest.*`, `tf.dlq` |
| `tf-model` | `tf.ingest.*` | `tf.forecast.results`, `tf.dlq` |
| `tf-bff` | `tf.ingest.journal`, `tf.ingest.reference`, `tf.forecast.results` | `tf.dlq` |

Попытка выйти за эти права возвращает `TopicAuthorizationException` / `GroupAuthorizationException`.
Пользователь `admin` — суперпользователь, только для обслуживания, сервисам его не отдавать.

## Ограничения одного брокера

- **Replication factor = 1, `min.insync.replicas` = 1.** Копия данных одна.
  Если том `tf-kafka-data` потерян — потеряны все сообщения. Пока брокер перезапускается,
  продюсеры и консьюмеры ждут (клиенты Kafka переподключаются сами).
- Для работы без простоя нужны три брокера — это открытый вопрос ТЗ.
- Трафик внутри `think-fast-net` не шифруется (SASL_PLAINTEXT). Порт на хост не публикуется,
  поэтому с других машин брокер недоступен. На Linux сам Docker-хост технически может достучаться
  до IP контейнера в bridge-сети, но без логина и пароля брокер его не пустит.
- Смена пароля — `scripts/secrets.sh rotate <КЛЮЧ>` и выкатка (брокер перезапустится).
  Добавление пользователя — строка в `secrets.conf`, `secrets.sh init kafka`, правка `docker-compose.yml`
  и `scripts/client-config.sh`, выкатка.

## CLI внутри контейнера

Все утилиты Kafka лежат в `/opt/kafka/bin`. Им нужен файл с логином — его создаёт `client-config.sh`.
Удобно зайти в контейнер один раз:

```bash
docker exec -it tf-kafka bash
cd /opt/kafka/bin
ADMIN=$(bash /opt/tf/client-config.sh admin)
```

Дальше примеры предполагают, что вы внутри контейнера и переменная `ADMIN` задана.

### Посмотреть топики

```bash
./kafka-topics.sh --bootstrap-server tf-kafka:9092 --command-config $ADMIN --describe --exclude-internal
./kafka-configs.sh --bootstrap-server tf-kafka:9092 --command-config $ADMIN --describe --entity-type topics --entity-name tf.ingest.readings
```

### Посмотреть смещения групп консьюмеров

```bash
# список групп
./kafka-consumer-groups.sh --bootstrap-server tf-kafka:9092 --command-config $ADMIN --list

# смещения и отставание (LAG) группы по каждой партиции
./kafka-consumer-groups.sh --bootstrap-server tf-kafka:9092 --command-config $ADMIN --describe --group tf-model

# все группы сразу
./kafka-consumer-groups.sh --bootstrap-server tf-kafka:9092 --command-config $ADMIN --describe --all-groups
```

`CURRENT-OFFSET` — до какого сообщения группа дочитала, `LOG-END-OFFSET` — сколько всего сообщений
в партиции, `LAG` — сколько осталось прочитать.

Сдвинуть смещение группы (например, перечитать всё сначала). Консьюмеры группы должны быть остановлены:

```bash
./kafka-consumer-groups.sh --bootstrap-server tf-kafka:9092 --command-config $ADMIN \
  --group tf-model --topic tf.ingest.readings --reset-offsets --to-earliest --dry-run
# если результат устраивает — повторить с --execute вместо --dry-run
```

### Прочитать сообщения из топика

```bash
./kafka-console-consumer.sh --bootstrap-server tf-kafka:9092 --consumer.config $ADMIN \
  --topic tf.dlq --from-beginning --property print.key=true --timeout-ms 10000
```

## Как добавить топик

1. Согласовать топик в таблице «Топики Kafka».
2. Добавить строку в `topics.conf`:
   ```
   tf.ingest.weather   3  retention.ms=604800000,compression.type=lz4,max.message.bytes=1048576
   ```
3. Если нужны права — добавить строки в `acls.conf`. Топики `tf.ingest.*` уже покрыты
   префиксными правами funnel и model, для bff нужна отдельная строка.
4. Применить: выкатка (пуш в ветку стенда) или `docker compose up tf-kafka-init` с загруженными секретами.

Удаление топика — только вручную (данные будут потеряны), затем убрать строку из `topics.conf`:

```bash
./kafka-topics.sh --bootstrap-server tf-kafka:9092 --command-config $ADMIN --delete --topic <имя>
```

## Как изменить хранение

Поменять значения в третьей колонке `topics.conf` и выкатить (или `docker compose up tf-kafka-init` с загруженными секретами).
Для существующего топика `init.sh` перезаписывает перечисленные настройки (`kafka-configs --alter`),
топик не пересоздаётся. Изменение вступает в силу сразу, старые сегменты удаляются в фоне.

| Что | Настройка |
|---|---|
| Хранить N дней | `retention.ms` = N × 86400000 |
| Ограничить объём на партицию | `retention.bytes` (по умолчанию без лимита) |
| Хранить бессрочно | `retention.ms=-1` |
| Хранить последнее значение по ключу | `cleanup.policy=compact` |

Убрать настройку (вернуть значение брокера по умолчанию) — удалить её из `topics.conf` и вручную:

```bash
./kafka-configs.sh --bootstrap-server tf-kafka:9092 --command-config $ADMIN \
  --alter --entity-type topics --entity-name tf.ingest.readings --delete-config retention.bytes
```

### Партиции

`init.sh` партиции не меняет, только предупреждает о расхождении в логе. Уменьшить число партиций
нельзя вообще. Увеличить можно, но сообщения с одним ключом начнут попадать в другую партицию —
порядок по ключу временно нарушится. Поэтому только осознанно:

```bash
./kafka-topics.sh --bootstrap-server tf-kafka:9092 --command-config $ADMIN --alter --topic tf.ingest.readings --partitions 12
```

и затем обновить `topics.conf`.

## Права

Добавить право — строка в `acls.conf` и выкатка.
Удаление строки право **не** отзывает, это делается вручную:

```bash
./kafka-acls.sh --bootstrap-server tf-kafka:9092 --command-config $ADMIN --list
./kafka-acls.sh --bootstrap-server tf-kafka:9092 --command-config $ADMIN --remove --force \
  --allow-principal User:tf-bff --operation Read --topic tf.ingest.journal
```

## Проверка критериев приёмки

```bash
# 1. Все пять топиков существуют с заданными партициями и хранением
docker logs tf-kafka-init

# 2. Сообщение переживает перезапуск контейнера
docker exec -it tf-kafka bash /opt/tf/smoke-test.sh produce      # печатает marker
docker restart tf-kafka
docker exec -it tf-kafka bash /opt/tf/smoke-test.sh consume <marker>

# 3. Сервис без прав получает отказ
docker exec -it tf-kafka bash /opt/tf/smoke-test.sh deny

# 4. Брокер недоступен с хоста: порт не опубликован
docker port tf-kafka           # пустой вывод
nc -zv localhost 9092          # connection refused
```

Тестовые сообщения пишутся в `tf.dlq` с ключом `smoke-test`, консьюмерам DLQ их нужно игнорировать.
