# kate-litellm

A locally hosted [LiteLLM](https://docs.litellm.ai/) gateway: one OpenAI-compatible
endpoint in front of every LLM provider, with spend tracking and request logs kept in
a local Postgres database.

See [docs/PLAN.md](docs/PLAN.md) for the design, phases and open decisions.

## Requirements

A container runtime that provides `docker compose` (OrbStack, Docker Desktop or Colima).

## Quick start

```sh
make init                 # creates .env and generates secrets
$EDITOR .env              # add provider API keys
make up
make test                 # health check + model counts
make test MODEL=openrouter/openai/gpt-4o-mini   # one real request
```

- API: `http://localhost:4000` (OpenAI-compatible, e.g. `/v1/chat/completions`)
- Admin UI and logs: `http://localhost:4000/ui` (login with `UI_USERNAME` / `UI_PASSWORD` from `.env`)

## Using it

Create a virtual key per app in the UI, then point the app at the gateway:

```sh
export OPENAI_BASE_URL=http://localhost:4000/v1
export OPENAI_API_KEY=sk-...        # a LiteLLM virtual key, not a provider key
```

Models are addressed as `provider/model`:

- `openrouter/<vendor>/<model>`
- `replicate/<owner>/<model>`
- `huggingface/<inference-provider>/<org>/<model>` for serverless
- dedicated Hugging Face Inference Endpoints by the name you give them in
  `config/litellm.yaml` (one entry per endpoint URL)

## Logs and token tracking

Request logs, including prompt and response bodies, are in the UI under Logs and are
deleted after 7 days. Each log row keeps the provider's full usage block, so cached
and uncached prompt tokens are tracked per request. `make cache` prints them per
model per day.

## Day to day

| Command | What it does |
| --- | --- |
| `make up` / `make down` | Start / stop (data is kept) |
| `make restart` | Apply changes to `config/litellm.yaml` or `.env` |
| `make logs` | Follow gateway logs |
| `make cache` | Cached vs uncached token report |
| `make backup` | Dump the database to `backups/` |
| `make psql` | Open a SQL shell on the database |

## Layout

- `docker-compose.yml`: gateway + Postgres, bound to `127.0.0.1`
- `config/litellm.yaml`: providers, models, logging settings
- `.env.example`: every variable the stack reads
- `scripts/`: `.env` bootstrap, smoke test, cache report query
