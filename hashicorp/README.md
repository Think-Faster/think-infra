# Vault

Хранилище секретов инфраструктуры. У каждого стенда (dev, prod) свой Vault.
Секреты лежат в `secret/tf/<сервис>`, их список — [secrets.conf](../secrets.conf).
Как ими пользоваться — [README.md](../README.md).

Vault слушает только `127.0.0.1:8200`. Скрипты обращаются к нему через `docker exec`,
веб-интерфейс открывается по SSH-туннелю:

```bash
ssh -L 8200:127.0.0.1:8200 <пользователь>@<сервер>
```

затем `http://localhost:8200`, вход по токену.

Выкатка Vault **не автоматизирована**: после перезапуска контейнер запечатан, и CI
всё равно не сможет работать, пока его не распечатают. Изменения `hashicorp/` применяются вручную.

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

### 4. Настроить хранилище, политики и доступ CI

Из корня репозитория, с root-токеном:

```bash
export VAULT_TOKEN=<root-токен>
hashicorp/scripts/setup.sh apply
```

Создаёт хранилище `secret/` (KV v2), политики `tf-deploy`, `tf-admin`, `tf-backup` и AppRole `tf-deploy`.
Идемпотентно: после изменения скрипта можно запускать повторно.

### 5. Выдать токены вместо root

```bash
hashicorp/scripts/setup.sh admin-token <имя>     # каждому администратору — свой
hashicorp/scripts/setup.sh backup-token          # для cron-бэкапа
hashicorp/scripts/setup.sh ci-credentials        # VAULT_ROLE_ID / VAULT_SECRET_ID для GitHub
```

Куда их положить и как заполнить секреты — [README.md](../README.md), раздел «Настройка стенда».

### 6. Отозвать root-токен

После настройки root-токен больше не нужен ни людям, ни CI:

```bash
docker exec -e VAULT_TOKEN=<root-токен> vault vault token revoke -self
```

Если root снова понадобится (новые политики, `setup.sh apply`), его выпускают ключами распечатывания:

```bash
docker exec vault vault operator generate-root -init             # печатает OTP и Nonce
docker exec vault vault operator generate-root -nonce=<Nonce> <ключ 1>
docker exec vault vault operator generate-root -nonce=<Nonce> <ключ 2>   # печатает Encoded Token
docker exec vault vault operator generate-root -decode=<Encoded Token> -otp=<OTP>
```

После работы — снова `token revoke -self`.

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
VAULT_TOKEN=<токен tf-backup> sh scripts/backup.sh
```

Снапшот попадает в `hashicorp/backups/` (в git не хранится), хранятся последние 14.
Каталог стоит копировать за пределы сервера. Снапшот зашифрован — без ключей распечатывания бесполезен.

Ежедневно по cron (в 03:00):

```
0 3 * * * cd /path/to/tf.infra/hashicorp && VAULT_TOKEN=<токен tf-backup> sh scripts/backup.sh >> backups/backup.log 2>&1
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
