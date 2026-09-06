#!/usr/bin/env bash
set -euo pipefail

N="${1:-50}" # top N paquetes, default 50
TMPFILE=$(mktemp --suffix=.json.gz)

echo "Descargando metadata de AUR..." >&2
curl -s https://aur.archlinux.org/packages-meta-ext-v1.json.gz -o "$TMPFILE"

echo "Top $N paquetes por popularidad:" >&2
gunzip -c "$TMPFILE" | jq --argjson n "$N" \
  'sort_by(-.Popularity) | .[:$n] | .[] | {Name, Popularity, NumVotes}'

rm -f "$TMPFILE"
