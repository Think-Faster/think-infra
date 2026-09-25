# Vault

Хранилище секретов проекта. Сюда складываются копии `.env` остальных сервисов
(`secret/tf/kafka`, `secret/tf/rabbit`, …).

## Почему пропадали секреты

Раньше Vault запускался в dev-режиме (`server -dev`): всё хранилось **только в памяти**,
тома `vault-data`/`vault-config` не использовались, и любой перезапуск контейнера
(падение, перезагрузка хоста, `docker compose up` после изменения) стирал все секреты.

Сейчас Vault работает в обычном режиме:

- данные — на диске, в именованном томе `tf-vault-data` (встроенное хранилище raft);
- конфиг — [vault-config/vault.hcl](vault-config/vault.hcl);
- бэкапы — снапшоты raft в `hashicorp/backups/` (см. ниже).

Цена за сохранность: после **каждого** старта контейнера Vault запечатан (sealed),
и его нужно распечатать ключами (unseal keys). Пока Vault запечатан, секреты не читаются,
а healthcheck показывает `unhealthy`.

## Первый запуск

### 1. Поднять контейнер

```bash
cd hashicorp
docker compose up -d
```

Если остался старый контейнер `vault` в dev-режиме — сначала `docker rm -f vault`.
Файл `hashicorp/.env` (`VAULT_DEV_ROOT_TOKEN_ID`) больше не используется.

### 2. Инициализировать

Выполняется **один раз** на пустом томе:

```bash
docker exec vault vault operator init -key-shares=3 -key-threshold=2
```

Команда выведет 3 ключа распечатывания (`Unseal Key 1..3`) и `Initial Root Token`.
Их больше нигде не будет, восстановить их нельзя.

- Сохранить ключи и root-токен в менеджер паролей команды (не в git и не на этом же сервере).
- Желательно раздать ключи разным людям: для распечатывания нужны любые 2 из 3.

Без ключей данные в томе и в бэкапах **не расшифровать**.

### 3. Распечатать

```bash
docker exec vault vault operator unseal <ключ 1>
docker exec vault vault operator unseal <ключ 2>
```

### 4. Включить хранилище `secret/`

В dev-режиме `secret/` (KV v2) создавался сам, в обычном режиме — нет:

```bash
docker exec -e VAULT_TOKEN=<root-токен> vault vault secrets enable -path=secret kv-v2
```

### 5. Вернуть секреты сервисов

Секреты из старого dev-Vault потеряны. Заново положить их из `.env` сервисов
командами `kv put` из [kafka/README.md](../kafka/README.md) и [rabbitmq/README.md](../rabbitmq/README.md).

## После каждого перезапуска

Контейнер стартует запечатанным. Проверить и распечатать:

```bash
docker exec vault vault status
```

```bash
docker exec vault vault operator unseal <ключ 1>
```

```bash
docker exec vault vault operator unseal <ключ 2>
```

`Sealed: false` — Vault готов.

## Бэкапы

Том защищает от перезапусков, но не от `docker compose down -v`, удаления тома или поломки диска.
Поэтому регулярно снимать снапшот:

```bash
VAULT_TOKEN=<токен> sh scripts/backup.sh
```

Снапшот попадает в `hashicorp/backups/` (в git не хранится), хранятся последние 14.
Каталог стоит копировать за пределы сервера. Снапшот зашифрован — без ключей распечатывания бесполезен.

Ежедневно по cron (в 03:00):

```
0 3 * * * cd /path/to/tf.infra/hashicorp && VAULT_TOKEN=<токен> sh scripts/backup.sh >> backups/backup.log 2>&1
```

### Восстановление из снапшота

На запущенном, инициализированном и распечатанном Vault:

```bash
docker cp backups/<файл>.snap vault:/tmp/restore.snap
```

```bash
docker exec -e VAULT_TOKEN=<токен> vault vault operator raft snapshot restore -force /tmp/restore.snap
```

После восстановления действуют ключи распечатывания и токены **того** Vault, с которого снят снапшот.

## Обновление версии

1. Снять снапшот (`scripts/backup.sh`).
2. Поменять тег образа в `docker-compose.yml`, `docker compose up -d`.
3. Распечатать.
