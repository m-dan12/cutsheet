#!/bin/sh
# Подставляет публичный ключ Auth Service (том auth-keys) в декларативный конфиг и запускает Kong.
set -eu
KEY=${AUTH_PUBLIC_KEY_FILE:-/keys/jwt-public.pem}
TEMPLATE=${KONG_TEMPLATE:-/kong/kong.yml}
OUT=/tmp/kong.yml

i=0
until [ -s "$KEY" ]; do
  i=$((i + 1))
  if [ "$i" -gt 120 ]; then echo "start.sh: no $KEY after 120 s" >&2; exit 1; fi
  [ "$i" -eq 1 ] && echo "start.sh: waiting for $KEY from auth"
  sleep 1
done

# Строка с плейсхолдером заменяется строками ключа с тем же отступом.
awk -v key="$KEY" '
  /__AUTH_PUBLIC_KEY__/ {
    indent = $0; sub(/__AUTH_PUBLIC_KEY__.*/, "", indent)
    while ((getline line < key) > 0) print indent line
    close(key); next
  }
  { print }
' "$TEMPLATE" > "$OUT"

export KONG_DECLARATIVE_CONFIG="$OUT"
exec /docker-entrypoint.sh kong docker-start
