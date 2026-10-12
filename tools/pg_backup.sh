#!/bin/sh
# Резервная копия PostgreSQL с проверкой восстановления (ТЗ 8, этап 6).
#   sh tools/pg_backup.sh [каталог]      # по умолчанию backups/
# Делает pg_dump в формате custom, восстанавливает его во временную базу и сравнивает
# число строк в основных таблицах; при расхождении — код возврата 1. Хранит последние
# KEEP копий (по умолчанию 14). Ежедневный запуск — cron / Планировщик заданий Windows (WSL).
set -eu
DIR=${1:-backups}
KEEP=${KEEP:-14}
USER=${POSTGRES_USER:-cutsheet}
DB=${POSTGRES_DB:-cutsheet}
COMPOSE="docker compose -f $(dirname "$0")/../deploy/docker-compose.yml"
PSQL="$COMPOSE exec -T postgres psql -U $USER -v ON_ERROR_STOP=1 -qAt"

mkdir -p "$DIR"
FILE="$DIR/cutsheet-$(date -u +%Y%m%dT%H%M%SZ).dump"
$COMPOSE exec -T postgres pg_dump -U "$USER" -d "$DB" -Fc > "$FILE"
echo "backup: $FILE ($(wc -c < "$FILE") bytes)"

CHECK=cutsheet_restore_check
$PSQL -d postgres -c "DROP DATABASE IF EXISTS $CHECK" -c "CREATE DATABASE $CHECK"
$COMPOSE exec -T postgres pg_restore -U "$USER" -d "$CHECK" --no-owner < "$FILE"
STATUS=0
for t in projects scenes replicas user_edits processed_events; do
  a=$($PSQL -d "$DB" -c "SELECT count(*) FROM $t" 2>/dev/null || echo "-")
  b=$($PSQL -d "$CHECK" -c "SELECT count(*) FROM $t" 2>/dev/null || echo "-")
  [ "$a" = "$b" ] && echo "  $t: $a rows" || { echo "  $t: $a in db, $b restored — MISMATCH"; STATUS=1; }
done
$PSQL -d postgres -c "DROP DATABASE $CHECK"

ls -1t "$DIR"/cutsheet-*.dump | tail -n +$((KEEP + 1)) | xargs -r rm --
[ $STATUS -eq 0 ] && echo "restore check OK" || echo "restore check FAILED"
exit $STATUS
