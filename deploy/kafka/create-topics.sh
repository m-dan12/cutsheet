#!/bin/bash
# Создаёт топики из реестра contracts/topics.txt (топики как код, ТЗ 8). Идемпотентно.
set -euo pipefail
BOOTSTRAP=$1
REGISTRY=$2
BIN=/opt/kafka/bin

grep -vE '^\s*(#|$)' "$REGISTRY" | while read -r topic partitions retention; do
  "$BIN/kafka-topics.sh" --bootstrap-server "$BOOTSTRAP" --create --if-not-exists \
    --topic "$topic" --partitions "$partitions" --replication-factor 1 \
    --config "retention.ms=$retention" >/dev/null
  echo "topic ready: $topic ($partitions partitions)"
done
