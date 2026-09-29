# Приложения

## A. Словарь

| Термин | Значение |
|---|---|
| Стенд | окружение целиком на одном сервере: dev (`greefob.ru`) или prod (`thinkfaster.ru`) |
| Шина | внешний сервис объекта, присылающий пакеты событий датчиков |
| Канал (`ид_канала_данных`) | датчик-источник событий; он же `sensorId` фронта и `sensors.id` BFF |
| Объект | место с датчиками (уровень 3 справочника) |
| Такт | часовой расчёт модели: граница часа МСК + 120 с |
| Факт | происшествие, которое уже идёт (`kind: fact`) |
| Техучётка | учётная запись сервиса (не человека) с правами `scope` |
| AppRole | способ входа сервиса в Vault: `role_id` (постоянный) + `secret_id` |
| Распечатывание (unseal) | ввод 2 из 3 ключей после старта Vault; до этого секреты не читаются |
| Root-токен | токен с полными правами Vault; выпускается ключами на время работы |
| Личный токен | токен администратора с политикой `tf-admin` |
| DLQ | очередь / топик для сообщений, которые не удалось обработать (`tf.dlq`) |
| `[skip ci]` | пометка в коммите, отключающая workflow этого пуша |
| `manual` | генератор в `secrets.conf`: значение вводится руками |

## B. Скрипты для Vault

Скрипты выполняются на сервере стенда. `Nonce` и `OTP` они запоминают сами и спрашивают только ключи.
Ключи и токены на экран не выводятся (кроме итогового root у `gen-root.sh`).

### check-unseal-keys.sh — проверить пару ключей, не запечатывая Vault

Использование: `~/check-unseal-keys.sh 1 2`, затем `~/check-unseal-keys.sh 2 3`.

```bash
#!/bin/bash
# Проверка двух ключей распечатывания Vault через выпуск root (Vault остаётся распечатанным).
set -u
v() { docker exec vault vault "$@"; }
field() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" | head -1; }
A="${1:?номера ключей, например: 1 2}"; B="${2:?номера ключей, например: 1 2}"
v operator generate-root -cancel > /dev/null 2>&1
init="$(v operator generate-root -init -format=json 2>&1)" || { echo "ОШИБКА: $init"; exit 1; }
nonce="$(printf '%s' "$init" | field nonce)"; otp="$(printf '%s' "$init" | field otp)"
[ -n "$nonce" ] && [ -n "$otp" ] || { echo "ОШИБКА: нет nonce/otp"; exit 1; }
last=""
for n in "$A" "$B"; do
    read -rs -p "Вставь Unseal Key $n и нажми Enter: " K; echo
    K="$(printf '%s' "$K" | tr -d '\r"' | awk '{print $NF}')"
    if ! last="$(v operator generate-root -nonce="$nonce" -format=json "$K" 2>&1)"; then
        unset K; v operator generate-root -cancel > /dev/null 2>&1
        echo "РЕЗУЛЬТАТ: Unseal Key $n НЕ ПРИНЯТ"; exit 2
    fi
    unset K
done
enc="$(printf '%s' "$last" | field encoded_token)"; [ -n "$enc" ] || enc="$(printf '%s' "$last" | field encoded_root_token)"
[ -n "$enc" ] || { v operator generate-root -cancel > /dev/null 2>&1; echo "РЕЗУЛЬТАТ: ключи $A и $B НЕ ПОДХОДЯТ"; exit 2; }
tok="$(v operator generate-root -decode="$enc" -otp="$otp" 2>/dev/null | tr -d '\r\n')"
docker exec -e VAULT_TOKEN="$tok" vault vault token revoke -self > /dev/null 2>&1
echo "РЕЗУЛЬТАТ: Unseal Key $A и Unseal Key $B — РАБОЧИЕ (проверочный root выпущен и отозван)"
```

### gen-root.sh — временный root-токен

Использование: `~/gen-root.sh`, ввести два ключа; полученный токен сразу использовать и отозвать (4.6).

```bash
#!/bin/bash
# Выпуск временного root-токена ключами распечатывания. Печатает токен в конце.
set -u
v() { docker exec vault vault "$@"; }
field() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" | head -1; }
v operator generate-root -cancel > /dev/null 2>&1
init="$(v operator generate-root -init -format=json 2>&1)" || { echo "ОШИБКА: $init"; exit 1; }
nonce="$(printf '%s' "$init" | field nonce)"; otp="$(printf '%s' "$init" | field otp)"
[ -n "$nonce" ] && [ -n "$otp" ] || { echo "ОШИБКА: нет nonce/otp"; exit 1; }
last=""
for n in первый второй; do
    read -rs -p "Вставь $n Unseal Key и нажми Enter: " K; echo
    K="$(printf '%s' "$K" | tr -d '\r"' | awk '{print $NF}')"
    last="$(v operator generate-root -nonce="$nonce" -format=json "$K" 2>&1)" || { unset K; v operator generate-root -cancel > /dev/null 2>&1; echo "ОШИБКА: ключ не принят"; exit 2; }
    unset K
done
enc="$(printf '%s' "$last" | field encoded_token)"; [ -n "$enc" ] || enc="$(printf '%s' "$last" | field encoded_root_token)"
[ -n "$enc" ] || { v operator generate-root -cancel > /dev/null 2>&1; echo "ОШИБКА: ключи не подходят"; exit 2; }
echo "ROOT-ТОКЕН (временный, отозвать после работы):"
v operator generate-root -decode="$enc" -otp="$otp"
```

### Перевыпуск ключей (rekey), если один ключ утерян

Нужны два действующих ключа. Данные, токены и роли не меняются.

```bash
docker exec vault vault operator rekey -init -key-shares=3 -key-threshold=2
```

Из ответа — `Nonce`. Затем дважды, с разными действующими ключами:

```bash
read -rs -p "Действующий Unseal Key: " K; echo; K=$(printf '%s' "$K" | tr -d '\r"' | awk '{print $NF}'); docker exec vault vault operator rekey -nonce=<Nonce> "$K"; unset K
```

После второго ключа Vault один раз покажет три новых ключа. Старые с этого момента недействительны. Проверьте
новые ключи `check-unseal-keys.sh` и снимите свежий снапшот: старые снапшоты расшифровываются старыми ключами.

## C. Настройки стендов (`stands/<стенд>.env`)

| Переменная | dev | prod | Смысл |
|---|---|---|---|
| `TF_INFRA_DIR` | `/home/user1/tf/think-prod` | `/srv/thinkfaster/tf.infra` | каталог выкатки |
| `DB_BIND` / `DB_PORT` | `0.0.0.0` / `5432` | `127.0.0.1` / `15432` | PostgreSQL на хосте |
| `DOMAIN` / `DOMAIN_ALIASES` | `greefob.ru` / — | `thinkfaster.ru` / `www.thinkfaster.ru` | сайт и сертификат |
| `WEB_BIND` | — (все адреса) | `45.87.41.186` | где слушает nginx |
| `LETSENCRYPT_EMAIL` | задан | задан | уведомления Let's Encrypt |
| `DOCKER_NETWORK` | `think-fast-net` | `think-fast-net` | сеть |
| `FRONTEND_*`, `AUTH_*`, `BFF_*`, `FUNNEL_*` | `tf-front:80`, `tf-auth:8080`, `tf-bff:8080`, `tf-funnel:8000` | так же | апстримы nginx |
| `ML_HOST`/`ML_PORT` | по умолчанию `tf-model:8000` | так же | апстрим `/api/ml/` |
| `FUNNEL_EVENTS_ALLOW` | пусто | пусто (заполнить IP шины) | allowlist приёма |
| `VAULT_DOMAIN` / `VAULT_ALLOW` | `vault.greefob.ru` / пусто | выключен / пусто | Vault UI |
| `MAIL_FROM` | — (адрес Gmail-ящика) | `noreply@thinkfaster.ru` | отправитель tf-mail |

## D. Открытые вопросы (сводно)

| Вопрос | Кому решать | Источник |
|---|---|---|
| Как шина получит долгий токен; нужен ли `scope`; кто создаёт учётку | tf-auth, продукт | tf-auth №2, tf-funnel, VII-1 |
| Роли и права в токене; где контракт «права-и-аудит» | tf-auth, tf-bff | tf-auth №1, VII-7 |
| Оставлять ли `/register` открытым | продукт | tf-auth №3 |
| IP шины, ожидаемый поток событий/с (срок архива, диск) | заказчик / шина | tf-funnel |
| Подключена ли шина к prod (без неё модель считает на пустом журнале) | заказчик | tf-funnel, tf-model |
| Кто публикует справочник объектов и каналов в `tf.ingest.reference` | tf-bff, tf-model | tf-model, VII-8 |
| Хватит ли памяти prod под tf-model при реальном потоке | инфра, tf-model | tf-model, VII-21 |
| Включать ли переобучение модели в контуре и на каком железе | ML | tf-model |
| Срок хранения `audit.events`; кто и где смотрит журнал аудита | продукт, tf-audit | tf-audit |
| Кто собирает `tf-audit:prod` (`build.sh` на prod-сервере, в репозиториях его нет) | Think-Faster | tf-audit |
| Оставлять ли эмулятор на dev после подключения шины | продукт | tf-emulator |
| Сроки жизни токенов (10 мин / 24 ч), `SameSite=Strict` у refresh | продукт | tf-auth №9 |
| Должны ли различаться сборки фронта dev и prod | tf-front | tf-front |
| `env_keep` для `tf-docker` на prod | владелец prod-сервера | tf-auth №7, VII-17 |
| Раннер на dev или ручная выкатка навсегда | инфра | VII |

## E. Как обновлять документ

Исходники лежат в think-infra, `docs/system/`:

| Путь | Что |
|---|---|
| `parts/*.md` | части инфраструктуры и общие части, по порядку имён файлов |
| `services/<сервис>.md` | разделы сервисов — копии `docs/system/<сервис>.md` из их репозиториев |
| `services.json` | порядок сервисов, репозиторий и версия каждого раздела |
| `build.py` | сборка `SYSTEM.md`, `SYSTEM.html` и `SYSTEM.pdf` |

1. Агент сервиса обновляет свой `docs/system/<сервис>.md` (шаблон из 14 пунктов, строка версии первой).
2. Файл копируется в `services/`, версия записывается в `services.json`.
3. `python docs/system/build.py` пересобирает документ. Для PDF нужен Microsoft Edge или Chrome, для схем —
   доступ к cdn.jsdelivr.net (mermaid).
4. Сквозные замечания (Часть VII) перепроверяются при каждой сборке: закрытые — удаляются, новые — добавляются.
