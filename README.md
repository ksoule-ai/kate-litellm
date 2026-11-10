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

The log viewer's Pretty tab has a "Final prompt" section showing what the model
saw after its chat template ran, including anything the template added (default
system prompt, documents, tools). `make prompt ID=<request id>` prints the same
thing. The template is rendered locally by the `prompt` service;
`config/chat-templates.yaml` says where each model's template comes from.

That section, and the documents and system messages shown in the Pretty tab, come
from `scripts/patch-ui.py`, which edits LiteLLM's bundled UI when the gateway
starts. If a new LiteLLM image no longer matches, `make logs` shows a `patch-ui:
WARNING` line and the stock UI is used.

## Agent sessions (`kl`)

`kl` starts a coding harness through the gateway and records which session made
each git commit. Put `kl/kl` on your `PATH` (for example
`ln -s "$PWD/kl/kl" ~/.local/bin/kl`), then:

```sh
kl setup pi        # one-time config to paste; also `kl setup hermes`
cd ~/code/some-repo
kl run pi --model kl/openrouter/anthropic/claude-sonnet-4.5
kl log             # commits, with the session and harness that made each
kl sessions        # every tracked session
kl session <id>    # one session: its commits and its gateway requests
```

To go back to a commit and carry on from there with a new agent:

```sh
kl resume <commit>              # same harness as made the commit; add e.g. --model for pi
kl resume --print <commit>      # only show the handoff note
kl resume --harness hermes <commit>
```

This leaves your checkout alone. It adds a worktree next to the repo
(`<repo>-kl/<commit>-1`, branch `kl/resume-<commit>-1`), writes a handoff note to
`.kl/HANDOFF.md` in it, and starts the agent there in tmux with an opening message
telling it to read the note. The note is a summary, written by your local model
(the `kl-summarizer` entry in `config/litellm.yaml`), of the conversation the first agent had had when it
made the commit; `kl` copies that conversation out of the request log at commit time,
so it outlasts the log's 7 days. Remove a worktree with `git worktree remove`.

To ask about any of this in plain language, talk to the manager agent:

```sh
kl chat                                   # a conversation
kl chat "which session made the last commit in my-repo, and what was it asked to do?"
```

It can list sessions and commits, read the conversation behind a commit, query the
request log with SQL, read your repos with git, and start a `kl resume` for you. It
runs on a local Ollama model, as do the handoff summaries: set `KL_LOCAL_MODEL` in
`.env` to one you have pulled that supports tools, then `make restart`. Nothing kl
reads (conversations, logs, repo contents) is sent off this machine. Everything it can do is read-only except
starting a resume, which always asks you first. It shows what each tool returned
under its answers: check a small model's answers against that, because small models
misreport. In testing, Granite 4.1 8B answered every test question correctly, Qwen 2.5
7B nearly all, and a 3B model invented details; use 7B or larger.

The same agent is in the admin UI as the **Agent Sessions** tab, under Logs in the
sidebar. The tab shows a page served from your machine, so keep this running in a
terminal:

```sh
kl serve        # or: make serve
```

The first time, open the link `kl serve` prints (or paste the token it prints into
the tab) to connect your browser; that is remembered. A resume asked for in the tab
shows what it will do and waits for you to press Start session. If `make logs` shows
`patch-ui: WARNING script loader not found`, a new LiteLLM image has changed and the
tab is missing; the page still works on its own at `http://localhost:4002`. Repos it knows are the ones `kl` has run in, plus git repos directly
inside any folder listed in `KL_REPO_ROOTS`.

Each `kl run` gets its own virtual key (named `kl-<harness>-<id>` in the UI, deleted
when the harness exits), so its requests can be told apart in the logs whatever the
harness sends. Commits get a `Kl-Session:` trailer and a row in
`~/.kl/ledger.sqlite`. The hooks reach git through the harness's environment, so
your repos' config is untouched and their own hooks still run; `kl hooks install`
puts them on a repo permanently if a harness does not pass its environment on.

Design and status: [docs/AGENT-SESSIONS-PLAN.md](docs/AGENT-SESSIONS-PLAN.md).

## Day to day

| Command | What it does |
| --- | --- |
| `make up` / `make down` | Start / stop (data is kept) |
| `make restart` | Apply changes to `config/litellm.yaml` or `.env` |
| `make logs` | Follow gateway logs |
| `make cache` | Cached vs uncached token report |
| `make prompt ID=…` | Final prompt the model saw for a logged request |
| `make serve` | Run the session manager behind the Agent Sessions tab |
| `make backup` | Dump the database to `backups/` |
| `make psql` | Open a SQL shell on the database |

## Layout

- `docker-compose.yml`: gateway, prompt renderer and Postgres, bound to `127.0.0.1`
- `config/litellm.yaml`: providers, models, logging settings
- `config/chat-templates.yaml`: where each model's chat template comes from
- `.env.example`: every variable the stack reads
- `kl/`: agent session launcher, git hooks, manager agent, its chat page (`kl/ui/`) and their test (`make kl-test`)
- `scripts/`: `.env` bootstrap, smoke test, cache report query, UI patch, prompt renderer
