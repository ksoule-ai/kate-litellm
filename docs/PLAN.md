# Plan: local LiteLLM gateway

## Goal

One endpoint on this Mac (`http://localhost:4000`) that fronts every LLM provider I use,
speaks the OpenAI API, and records every request (model, tokens, cost, latency, and
optionally prompt/response bodies) in a local database with a web UI to browse it.

## Architecture

```
 clients (SDKs, Claude Code, Cursor, scripts, curl)
        │  OpenAI-compatible API + a LiteLLM virtual key
        ▼
 ┌──────────────────────────┐        ┌─────────────────────┐
 │ LiteLLM proxy  :4000     │──────▶ │ Postgres 16         │
 │  /v1/*   API             │        │ keys, spend, logs   │
 │  /ui     admin + logs    │        │ (Docker volume)     │
 └──────────┬───────────────┘        └─────────────────────┘
            │ provider keys from .env
            ▼
 OpenRouter · Replicate · Hugging Face (serverless + dedicated endpoints)
```

- **Docker Compose**, two services: `litellm` and `db`. This is LiteLLM's supported
  deployment for the proxy + database, and keeps Python/Prisma off the host.
- **Postgres is required**, not optional: virtual keys, spend tracking, the request
  log, and the admin UI all depend on it.
- **Bound to `127.0.0.1` only.** Nothing on the LAN can reach the gateway or database.
- **Postgres data lives in a named Docker volume**, not in this folder, so the repo
  stays small and safe to put under any file-sync tool.

## Repo layout

| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | `litellm` + `db` services |
| `config/litellm.yaml` | Models/providers, logging and gateway settings |
| `.env.example` | Every variable the stack reads, with no values |
| `.env` | Real secrets. Gitignored, created by `make init` |
| `scripts/init-env.sh` | Creates `.env` and generates the master/salt/db secrets |
| `scripts/smoke-test.sh` | Health check + one chat completion through the gateway |
| `scripts/cache-report.sql` | Cached vs uncached tokens per model per day |
| `Makefile` | `init`, `up`, `down`, `logs`, `test`, `cache`, `backup`, … |
| `backups/` | `pg_dump` output. Gitignored |

## Configuration approach

- **Wildcard routes per provider** (`openrouter/*`, `replicate/*`, `huggingface/*`) so
  every model a provider offers is callable as `provider/model` without editing config
  when new models ship. Friendly aliases get added on top where useful.
- **Hugging Face dedicated Inference Endpoints get one entry each**, because every
  endpoint has its own URL. There is a template in `config/litellm.yaml`.
- **Provider keys only in `.env`**, referenced from config as `os.environ/NAME`.
- **`store_model_in_db: true`** so models can also be added from the UI.
- **`store_prompts_in_spend_logs: true`** so the log viewer shows full request and
  response bodies, not just metadata.
- **Request logs are deleted after 7 days** (`maximum_spend_logs_retention_period`),
  with the cleanup job running daily. Daily spend totals are kept separately.
- **Cached vs uncached tokens** are recorded per request: LiteLLM stores the provider's
  full usage block (including `prompt_tokens_details.cached_tokens` and cache writes)
  in the log row. `make cache` reports them per model per day.
- **One virtual key per client/app** (created in the UI). The master key is for admin
  only. Per-key attribution is what makes the spend and log views useful.

## Status

1. **Scaffold**: done.
2. **Container runtime**: done. OrbStack is installed.
3. **First boot**: done. The stack starts, all three provider routes resolve, and
   retention and cached-token logging were tested against a mock upstream.
4. **Provider keys**: to do. Add `OPENROUTER_API_KEY`, `REPLICATE_API_KEY` and
   `HF_TOKEN` to `.env`, then `make restart` and `make test MODEL=…`.
5. **Dedicated HF endpoints**: to do. Add one config entry per endpoint URL.
6. **Clients**: to do. Create a virtual key per tool and repoint each at
   `http://localhost:4000`.
7. **Operate**: to do. Pin `LITELLM_IMAGE` to a specific release so upgrades are
   deliberate (LiteLLM had a compromised PyPI release in March 2026; first boot ran
   1.103.2 from the `main-stable` tag), and schedule `make backup` if wanted.

## Things to know

- **Log bodies are stored.** Every prompt and response sent through the gateway sits
  in plaintext in Postgres for the 7-day window.
- **Cached-token numbers come from the provider.** OpenRouter reports them. Replicate
  and Hugging Face endpoints generally do not, so those rows will show zero cached.
- **Cache hits need the provider to cache.** Through OpenRouter, some upstream models
  cache automatically; Anthropic models need `cache_control` in the request.
