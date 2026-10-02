#!/usr/bin/env bash
# Check the gateway is up, count the models it exposes per provider, and optionally send one
# chat completion through it.
#   scripts/smoke-test.sh                          # health + model counts
#   scripts/smoke-test.sh openrouter/openai/gpt-4o-mini   # plus one request
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; source .env; set +a

base="http://localhost:${LITELLM_PORT:-4000}"
auth=(-H "Authorization: Bearer ${LITELLM_MASTER_KEY}")

echo "== liveliness"
curl -fsS "$base/health/liveliness"; echo

echo "== models"
curl -fsS "${auth[@]}" "$base/v1/models" | grep -o '"id":"[^"/]*' | sort | uniq -c

if [[ $# -ge 1 ]]; then
  echo "== chat completion: $1"
  curl -fsS "${auth[@]}" -H "Content-Type: application/json" \
    "$base/v1/chat/completions" \
    -d "{\"model\": \"$1\", \"max_tokens\": 32, \"messages\": [{\"role\": \"user\", \"content\": \"Reply with the word ok.\"}]}"
  echo
fi
