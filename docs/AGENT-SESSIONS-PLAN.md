# Plan: commit-linked agent sessions

## Goal

Run open source coding harnesses (Pi, Hermes) through this gateway, record which
gateway session produced each git commit, and be able to go back to any commit, hand a
new agent a summary of the conversation up to that point, and carry on from there. All
of it is driven from a chat tab in the gateway's admin UI, where a manager agent can
read the logs and the repos.

## Architecture

```
 browser: localhost:4000/ui ── "Agents" tab (iframe) ──┐
                                                       ▼
 ┌─────────────────────┐   read-only SQL    ┌──────────────────────────────┐
 │ LiteLLM  :4000      │◀───────────────────│ kl daemon  :4002  (on host)  │
 │ Postgres (logs)     │   chat completions │  manager agent + tools       │
 └─────────▲───────────┘◀───────────────────│  ledger.sqlite               │
           │ model calls, one virtual key   │  git worktrees, tmux         │
           │ per agent session              └───────▲──────────────┬───────┘
 ┌─────────┴───────────┐   post-commit hook         │              │ starts
 │ pi / hermes in tmux │────────────────────────────┘              ▼
 │ started by `kl run` │                               new harness in a worktree
 └─────────────────────┘
```

Three new pieces:

- **`kl` launcher and git hooks** (host). `kl run pi` starts a harness with a session
  identity; the hooks record each commit against it.
- **`kl` daemon** (host, loopback only). Owns the ledger, the transcript snapshots, the
  rollback and resume logic, and the manager agent. It has to run on the host, not in
  Docker, because it starts harness processes and runs git in the real repos.
- **Agents tab**. One more patch in `scripts/patch-ui.py` that adds a nav entry showing
  the daemon's chat page in an iframe.

## How each part works

### 1. Session identity

LiteLLM already groups requests into sessions: `LiteLLM_SpendLogs.session_id` is filled
from `x-litellm-session-id`, any `x-<vendor>-session-id` header, a bare `x-session-id`,
or `litellm_session_id` in the body (checked in LiteLLM 1.108.4). The harnesses will
not all send one, so the launcher does not depend on it:

- `kl run <harness> [repo]` creates a **kl session** (a UUID), mints a **virtual key
  for that session** through `/key/generate` with the session, repo and harness in the
  key's metadata, and starts the harness with that key and
  `KL_SESSION_ID` in its environment.
- Every request is then attributable by key, whatever the harness sends. Where the
  harness allows a custom header (Pi's `models.json` has a `headers` field), the
  launcher also sets `x-litellm-session-id` so the stock Logs view groups correctly.

### 2. Commit ledger

- The launcher points the repo at kl's hooks (`core.hooksPath`, chaining to existing
  hooks). The harness's shell tool inherits `KL_SESSION_ID`, so the hooks see it.
- `prepare-commit-msg` adds a `Kl-Session: <id>` trailer. The link then lives in git
  itself and survives rebases, pushes and a lost database.
- `post-commit` posts `{repo, sha, parents, branch, session, time}` to the daemon,
  which stores it in `ledger.sqlite`. If the daemon is down the hook appends to a local
  spool file and never blocks the commit. `post-rewrite` remaps SHAs after amend and
  rebase; `pre-push` records which commits reached GitHub.
- On each commit the daemon also **snapshots the transcript**: a few seconds later
  (spend logs are written in batches) it finds the session's last request that started
  before the commit and copies its request and response bodies into the ledger. That
  request's `messages` array is the harness's whole context at that moment.

### 3. Rollback and resume

`kl resume <sha>` (also the manager agent's one write tool):

1. `git worktree add <repo>-kl/<short-sha> -b kl/resume-<short-sha>-<n> <sha>`. The
   original checkout and branch are never reset.
2. Build the handoff: summarise the snapshot for that commit through the gateway
   (goal, decisions, state of the work, open threads, files touched), and attach
   `git log` up to the commit.
3. Start a new kl session in the worktree with `parent_session` and `parent_commit`
   recorded, write the summary to `.kl/HANDOFF.md`, and start the harness in tmux with
   an opening prompt that points at it.
4. Return the tmux session name to attach to.

### 4. Manager agent

A tool-calling loop in the daemon, using a model through the gateway on its own
virtual key. Tools:

| Tool | Access |
| --- | --- |
| `query_logs(sql)` | Postgres role with `SELECT` only, statement timeout, row cap |
| `list_sessions`, `get_session`, `get_transcript` | ledger and snapshots |
| `git(repo, args)` | allowlist: `log`, `show`, `diff`, `status`, `branch`, `worktree list` |
| `read_file`, `grep` | inside configured repo roots only |
| `resume_from_commit(repo, sha, harness)` | write; needs a confirm click in the UI |

### 5. UI tab

The stock UI has no plugin mechanism for tabs, so this follows the existing
`patch-ui.py` approach, kept as small as possible: one nav item and one iframe. The
chat page itself is plain HTML served by the daemon, so almost nothing depends on the
minified bundle. If the patch stops matching after an upgrade, the page still works at
`localhost:4002` directly.

## Phases

0. **Spikes.** Done in a cloud sandbox against the real gateway image and database,
   with Pi 1.5.2 and Hermes 0.19.0. The model was a scripted stand-in that asks the
   harness to run one shell command (a `git commit`), so real model behaviour and
   interactive use are still untested. Findings:
   - **Pi** sends no session header of its own. With the `headers` entry from
     `kl setup pi` it sends `x-litellm-session-id`, and the gateway's `session_id`
     column then equals the kl session id.
   - **Hermes** sends no session header and has no setting for one. The gateway
     gives every request its own `session_id`, so the virtual key is the only link.
   - **Hermes 0.19.0 ignores `OPENAI_BASE_URL`** with `--provider custom` and calls
     OpenRouter. The endpoint and key go in its `config.yaml`; `kl setup hermes`
     prints the three commands. The docs describe flags (`--base-url`) that this
     release does not have.
   - Both harnesses pass their environment to shell commands, so the hooks see the
     session without extra setup. (Hermes's docs describe filtering in newer
     versions; `kl setup hermes` covers that case.)
   - Log rows, with full request bodies, survive deletion of the session's key.
   - The gateway writes log rows a few seconds after the request, and a row's
     primary key is the upstream response id.
1. **Attribution.** Built and tested: `kl run`, key per session, hooks, ledger,
   `kl log`, `kl sessions`, `kl session`. `make kl-test` covers the launcher, hooks
   and ledger without a gateway; the spike runs above covered the real gateway, Pi
   and Hermes end to end. Differences from the design above:
   - The hooks write to `~/.kl/ledger.sqlite` directly. There is no daemon yet, so no
     spool file is needed; the daemon will read the same file.
   - The hooks are not set in the repo's config. `kl run` points git at them through
     `GIT_CONFIG_*` in the harness's environment, so only that process tree uses
     them. `kl hooks install` sets `core.hooksPath` on a repo for harnesses that do
     not pass their environment on (Hermes filters it; see `kl setup hermes`), and
     the hooks then find the session by repo if exactly one is running there.
   - The session's key is deleted when the harness exits. The ledger keeps its hash,
     which is what the request logs are keyed on.
   - If the launcher is stopped, it closes the session and deletes the key first. If
     it is killed outright, the next `kl run` does that for it.
   - Commits replayed by a rebase keep the session that wrote them. A new commit made
     in the middle of a rebase is not recorded.
2. **Resume.** Built and tested: per-commit snapshots, the summariser and
   `kl resume <commit>`. Run end to end against the real gateway with Pi and Hermes,
   including resuming a Pi commit with Hermes; the summariser was a stand-in, so the
   quality of real summaries is untested. `make kl-test` covers it without a gateway.
   How it turned out:
   - **Snapshot.** The post-commit hook starts a background process that waits for
     the gateway's log to catch up (it is a few seconds behind), then copies the
     session's last request with tools that started before the commit, plus the reply
     to it. Session end and `kl resume` retry if that did not happen.
   - **The gateway was cutting every logged message to 2,048 characters.** That would
     have gutted the snapshots. `MAX_STRING_LENGTH_PROMPT_IN_DB` is now 100,000 in
     `docker-compose.yml`. Log rows are larger as a result.
   - **Database access** goes through `docker compose exec db psql`, so Postgres still
     has no host port. `KL_PSQL` overrides the command.
   - **Summary.** Written by the gateway alias `kl-summarizer`, cached in the ledger.
     Tool output is clipped before summarising, and a long transcript is summarised
     piece by piece (`KL_SUMMARY_CHUNK_CHARS`), each piece rewriting the note so far.
   - **Starting the agent.** Pi takes the opening message as an argument. Hermes has
     no such option in 0.19, so kl types it into the tmux window once the screen
     settles. If the agent fails to start, the window stays open with the error.
   - Snapshot selection compares the gateway's clock with the host's. They are the
     same clock under Docker on Linux; a container VM on a Mac can drift after sleep,
     which could pick the request one turn early or late.
3. **Daemon and manager agent.** Built and tested: `kl chat` (terminal) and
   `kl serve` (local API), both in `kl/manager.py`. Run against real Ollama with
   Qwen 2.5 at 3B and 7B (4-bit), through the gateway alias `kl-manager`.
   `make kl-test` covers the tools, the confirmation step and the API's access checks
   with a scripted model. How it turned out:
   - **Tools:** `list_repos`, `list_sessions`, `get_session`, `list_commits`,
     `get_commit`, `get_conversation`, `query_logs`, `git`, `read_file`, and
     `resume_from_commit`. All read-only except the last.
   - **Resume always asks.** What the person is shown is worked out from the tool's
     arguments, not from the model's words. One request per message: in testing the
     3B model called it five times unprompted on an unrelated question, and each was
     stopped at the prompt.
   - **`query_logs`** runs as a database login (`kl_reader`, created on first use)
     that can read the request log table and nothing else, read-only, 10 s limit. The
     manager has its own gateway key and its requests are left out of what it reads.
   - **`git`** is an allowlist of reading commands with the options that write files
     or run programs refused. **`read_file`** cannot leave the repo.
   - **The API** listens on loopback and checks a token (header or a strict cookie),
     the Host header and, for anything that changes state, the Origin.
   - **No FastAPI or uv.** Everything is still the Python standard library, so there
     is nothing to install. Postgres still has no host port.
   - **Model size matters more than the plan assumed.** Both sizes picked the right
     tool almost every time. The 3B model then misreported what the tools returned
     (invented file names, wrong counts). The 7B model reported correctly on the same
     questions once the tools were made forgiving: ids of sessions and commits look
     alike, so tools accept either; `get_commit` answers the commonest question in one
     call; an identical repeated call is refused; lists carry their own totals.
     `kl chat` prints what each tool returned so answers can be checked. A 7B model
     is the floor; larger ones were not tried.
   - Summaries by the 3B model were thin (it missed the person's request). The
     summariser alias still points at a hosted model.
4. **UI tab.** Chat page, the patch, confirm dialog for resume.
5. **Hardening.** Retention, upgrade check, backup of the ledger with `make backup`.

## Issues

**Would change the design**

- **Seven-day log retention.** A commit older than a week has no logs left to
  summarise. The per-commit snapshot fixes this for commits; conversation that never
  led to a commit is still lost unless retention is raised.
- **The gateway's sessions are not the harness's sessions.** A harness can start a new
  conversation, compact, branch (Pi's `/tree`) or spawn subagents inside one launch,
  and makes side calls (titles, compaction) on the same key. A kl session is "one
  launch", and the snapshot is "what the model was last shown before the commit".
  After a compaction that is already a summary, not the full history.
- **A summary is a lossy resume.** The new agent gets a description of the
  conversation, not the conversation. Pi stores sessions as a JSONL tree with parent
  ids, so a true fork of the native session at the commit is possible there later;
  Hermes keeps sessions in SQLite. The summary route is the one that works for every
  harness, so it comes first.
- **The daemon is a local web server that can read every repo and start processes.**
  Any web page open in the browser can send requests to `localhost:4002`. It needs a
  token on every request, an `Origin` check and a `Host` check (DNS rebinding) from
  the first version. The existing prompt renderer on 4001 has none of these, which is
  acceptable there and would not be here.
- **Prompt injection into the manager agent.** The logs contain whatever the coding
  agents read: web pages, issue text, repo files. The manager reads those logs and has
  tools. That is why its tools are read-only apart from one confirmed action, and why
  it gets no general shell.
- **The manager's own requests land in the logs it queries.** Give it a dedicated key
  and exclude that key by default.

**Limits to accept or work around**

- **Only commits made through `kl run` are attributed.** Commits from a plain
  terminal, or made through the GitHub API or an MCP server, bypass the hooks. They
  appear in the ledger as unattributed when the daemon next scans the repo.
- **Rolling back the repo does not roll back anything else.** Pushed commits, database
  migrations, installed packages and remote state stay as they are. A fresh worktree
  also lacks ignored files (`.env`, `node_modules`, build output), so most projects
  need a per-repo setup command before the agent can run anything.
- **Model choice for the manager.** It needs dependable tool calling over long
  contexts; the small Granite endpoints configured here are unlikely to manage it.
  The MVP uses a hosted model and the final version a local one; see Decisions.
- **UI patch brittleness.** Same risk as today's patch: a new image can break it. Pin
  `LITELLM_IMAGE` before building on it.
- **Postgres has no host port today.** The daemon needs one on loopback, with a
  separate read-only role.
- **Harness details move quickly.** Pi was recently renamed (`badlogic/pi-mono` to
  `earendil-works/pi`) and config field names differ between versions; Hermes's hook
  API was not confirmed. Phase 0 exists to pin these down per installed version.

## Decisions

1. **Where the code lives.** A `kl/` folder in this repo. It shares the compose stack,
   `.env` and UI patch.
2. **How to reach the resumed agent.** tmux, with the UI showing the attach command. A
   web terminal in the tab can come later.
3. **Manager model.** Local on Ollama from the start (changed from "hosted for the
   MVP"): set `KL_MANAGER_MODEL` in `.env`. The summariser is still hosted. The
   original reasoning follows.
   A hosted model for the MVP, a local model in the final version.
   To keep that swap a config change:
   - The daemon calls two gateway aliases, `kl-manager` and `kl-summarizer`, defined in
     `config/litellm.yaml`. Moving to a local model means repointing the aliases (for
     example at `ollama/*`, which is already routed), with no code change.
   - Tools are built for a small model from the start: few of them, flat arguments,
     capped and pre-summarised results instead of raw log rows, and transcripts read
     in pages. Summaries of long transcripts are built in chunks, not in one call.
   - Until the swap, log contents the manager or summariser reads are sent to the
     hosted provider. Agent sessions that touch secrets should be kept out of its
     reach during the MVP, or the secrets rotated afterwards.
   - Phase 5 gains a step: run a fixed set of manager questions and one resume against
     candidate local models and pick the smallest that passes.

## Open decisions

1. **Language for the daemon.** Recommended: Python with `uv`, FastAPI, SQLite. Matches
   the scripts already here.
2. **Retention.** Recommended: keep 7 days in Postgres and rely on snapshots.
