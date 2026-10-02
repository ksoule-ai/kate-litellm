#!/usr/bin/env bash
# Create .env from .env.example and fill in the generated secrets.
# Refuses to touch an existing .env.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -e .env ]]; then
  echo ".env already exists; leaving it alone." >&2
  exit 1
fi

rand() { openssl rand -hex "$1"; }

sed \
  -e "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=sk-$(rand 24)|" \
  -e "s|^LITELLM_SALT_KEY=.*|LITELLM_SALT_KEY=sk-$(rand 24)|" \
  -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(rand 24)|" \
  -e "s|^UI_PASSWORD=.*|UI_PASSWORD=$(rand 12)|" \
  .env.example > .env
chmod 600 .env

echo "Created .env with generated secrets. Add your provider API keys to it, then run: make up"
