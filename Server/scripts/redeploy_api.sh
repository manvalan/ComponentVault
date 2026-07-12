#!/usr/bin/env bash
# Aggiorna l'API ComponentVault sul VPS (incluso bridge OAuth DigiKey per iPad).
set -euo pipefail

VPS_HOST="${CVAULT_VPS_HOST:-root@82.165.138.64}"
REMOTE_DIR="${CVAULT_REMOTE_DIR:-/opt/componentvault}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "→ Copia api/main.py su ${VPS_HOST}:${REMOTE_DIR}/api/"
scp "${ROOT}/Server/api/main.py" "${VPS_HOST}:${REMOTE_DIR}/api/main.py"

echo "→ Rebuild container API"
ssh "${VPS_HOST}" "cd ${REMOTE_DIR} && docker compose up -d --build api"

echo "→ Verifica bridge OAuth"
ssh "${VPS_HOST}" "curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:8100/oauth/digikey/callback"
curl -s -o /dev/null -w "Pubblico: HTTP %{http_code}\n" "https://cvault.michelebigi.it/oauth/digikey/callback"

echo "Fatto. Riprova login DigiKey dall'iPad."
