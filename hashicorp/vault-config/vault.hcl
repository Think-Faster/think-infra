# Конфигурация Vault. Образ подхватывает все *.hcl из /vault/config
# при запуске командой `server` (без -dev).

# Веб-интерфейс на http://<хост>:8200
ui = true

# Для raft mlock не нужен и не рекомендуется (иначе нужен IPC_LOCK и хватает памяти не всем хостам).
disable_mlock = true

# Встроенное хранилище: данные пишутся на диск в том tf-vault-data
# и переживают перезапуск и пересоздание контейнера.
# Поддерживает снапшоты: vault operator raft snapshot save (см. README).
storage "raft" {
  # /vault/file: entrypoint образа выдаёт права пользователю vault только на этот каталог
  # (и /vault/config, /vault/logs). На /vault/data raft падает с "permission denied".
  path    = "/vault/file"
  node_id = "tf-vault"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"
