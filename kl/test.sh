#!/usr/bin/env bash
# End-to-end test of `kl run`, the hooks, the ledger and `kl resume`, against
# stand-ins for the gateway's key and chat endpoints and its request log. Needs git and python3; touches nothing
# outside a temp folder. Run: make kl-test
set -euo pipefail

KL="$(cd "$(dirname "$0")" && pwd)/kl"
T="$(mktemp -d)"
trap 'kill $GW 2>/dev/null || true; rm -rf "$T"' EXIT

export KL_HOME="$T/home" KL_MASTER_KEY=sk-master HOME="$T" GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_COUNT KL_SESSION_ID
git config --global user.name kl-test
git config --global user.email kl-test@example.invalid
git config --global init.defaultBranch main
git config --global commit.gpgsign false

# Stand-in gateway: hands out keys, records what was asked of it.
python3 - "$T" <<'EOF' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
T = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(T + "/gateway.log", "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers["Authorization"], "body": body}) + "\n")
        out = {"key": "sk-session-" + body.get("key_alias", "")}
        if body.get("model") == "kl-manager":  # a scripted model for the manager agent: one tool call, then an answer
            last = body["messages"][-1]
            words = (last.get("content") or "").split(" ", 1)
            call = {"sessions": ("list_sessions", {}),
                    "commit:": ("get_commit", {"commit": words[-1]}),
                    "git:": ("git", {"repo": "repo", "command": words[-1]}),
                    "read:": ("read_file", {"repo": "repo", "path": words[-1]}),
                    "sql:": ("query_logs", {"sql": words[-1]}),
                    "resume": ("resume_from_commit", dict(zip(("repo", "commit", "harness"), words[-1].split())))}.get(words[0])
            msg = {"role": "assistant", "content": "ANSWER: " + (last.get("content") or "")}
            if last["role"] == "user" and words[0] == "textcall":  # a small model writing the call as text
                msg["content"] = 'I will look. {"name": "list_repos", "arguments": {}}'
            elif last["role"] == "user" and call:
                assert {t["function"]["name"] for t in body["tools"]} >= {call[0]}
                msg = {"role": "assistant", "content": None, "tool_calls": [{"id": "c1", "type": "function",
                       "function": {"name": call[0], "arguments": json.dumps(call[1])}}]}
            out = {"choices": [{"message": msg}]}
        elif self.path == "/v1/chat/completions":  # the summariser
            out = {"choices": [{"message": {"role": "assistant", "content": "## Goal\nSTAND-IN NOTE for a transcript with "
                   + str(body["messages"][0]["content"].count("USER:")) + " user message(s)"}}]}
        out = json.dumps(out).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(out)
    def log_message(self, *a): pass
s = HTTPServer(("127.0.0.1", 0), H)
open(T + "/port", "w").write(str(s.server_port))
s.serve_forever()
EOF
GW=$!
for _ in $(seq 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
export KL_GATEWAY_URL="http://127.0.0.1:$(cat "$T/port")"

# Stand-in request log: whatever is asked, the session made one request before
# the commit (with tools, so it is the conversation) and one after it.
cat > "$T/psql" <<'PSQL'
#!/bin/sh
for a; do sql="$a"; done
case "$sql" in
  *'"startTime" >'*) echo '{"request_id": "req-after", "start_time": "2030-01-01T00:00:00", "model": "m", "request": {}, "response": {}}' ;;
  *row_to_json*) echo '{"request_id": "req-before", "start_time": "2020-01-01T00:00:00", "model": "m", "request": {"model": "m", "tools": [{}], "messages": [{"role": "system", "content": "harness prompt"}, {"role": "user", "content": "build the thing"}]}, "response": {"choices": [{"message": {"role": "assistant", "content": null, "tool_calls": [{"function": {"name": "bash", "arguments": "git commit"}}]}}]}}' ;;
  *) echo "(stand-in)" ;;
esac
PSQL
chmod +x "$T/psql"
export KL_PSQL="$T/psql" KL_PSQL_READER="$T/psql"

pass=0
ok()   { pass=$((pass + 1)); echo "ok   $1"; }
fail() { echo "FAIL $1"; exit 1; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }
sql()  { python3 -c 'import sqlite3, sys
for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2]): print(*["" if c is None else c for c in r], sep="|")' "$KL_HOME/ledger.sqlite" "$1"; }

# A repo with a remote and a pre-commit hook of its own, which must keep running.
git init -q --bare "$T/remote.git"
git init -q "$T/repo" && cd "$T/repo"
git remote add origin "$T/remote.git"
printf '#!/bin/sh\necho ran >> "%s/own-hook.log"\n! git diff --cached --name-only | grep -q forbidden\n' "$T" > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
echo a > a && git add a && git commit -qm "outside kl"

# One session: two commits, a rejected one, an amend, a push.
"$KL" run sh -c '
  echo "$KL_SESSION_ID" > "'"$T"'/sid"; echo "$OPENAI_API_KEY $OPENAI_BASE_URL" > "'"$T"'/env"
  echo b > b && git add b && git commit -qm "first in session"
  echo c > c && git add c && git commit -qm "second in session"
  echo x > forbidden && git add forbidden && git commit -qm "must be rejected" 2>/dev/null; git reset -q forbidden
  echo c2 >> c && git commit -qam "amended" --amend
  git push -q origin main
' 2>"$T/run.err"
SID="$(cat "$T/sid")"

check "session id reached the harness"        '[[ ${#SID} -eq 36 ]]'
check "harness got the session key and URL"   '[[ "$(cat "$T/env")" == "sk-session-kl-sh-${SID:0:8} $KL_GATEWAY_URL/v1" ]]'
check "key was created with the master key"   'grep -q "\"path\": \"/key/generate\", \"auth\": \"Bearer sk-master\"" "$T/gateway.log"'
check "key metadata names the session"        'grep -q "\"kl_session\": \"$SID\"" "$T/gateway.log"'
check "key was deleted when the session ended" 'grep -q "\"path\": \"/key/delete\".*sk-session-kl-sh-${SID:0:8}" "$T/gateway.log"'
check "session is closed in the ledger"       '[[ "$(sql "select count(*) from sessions where id=\"$SID\" and ended_at is not null and exit_code=0")" == 1 ]]'
check "key hash stored, not the key"          '[[ "$(sql "select key_hash from sessions")" == "$(printf %s "sk-session-kl-sh-${SID:0:8}" | python3 -c "import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())")" ]]'
check "three commits recorded (two + amend)"  '[[ "$(sql "select count(*) from commits where session_id=\"$SID\" and attribution=\"env\"")" == 3 ]]'
check "commit outside kl is not attributed"   '[[ "$(sql "select count(*) from commits")" == 3 ]]'
check "HEAD is in the ledger"                 '[[ "$(sql "select subject from commits where sha=\"$(git rev-parse HEAD)\"")" == amended ]]'
check "trailer is in the commit message"      '[[ "$(git log -1 --format="%(trailers:key=Kl-Session,valueonly)" | head -1)" == "$SID" ]]'
check "trailer added once on amend"           '[[ "$(git log -1 --format=%B | grep -c Kl-Session)" == 1 ]]'
check "no trailer on the outside commit"      '! git log --format=%B HEAD~2 -1 | grep -q Kl-Session'
check "repo own pre-commit hook still ran"    '[[ "$(wc -l < "$T/own-hook.log")" -ge 4 ]]'
check "repo own hook can still reject"        '! git log --format=%s | grep -q "must be rejected"'
check "amend recorded as a rewrite"           '[[ "$(sql "select kind from rewrites where new_sha=\"$(git rev-parse HEAD)\"")" == amend ]]'
check "push recorded"                         '[[ "$(sql "select remote || \" \" || remote_ref || \" \" || sha from pushes")" == "origin refs/heads/main $(git rev-parse HEAD)" ]]'
check "repo config was not changed"           '! git config --local --get core.hooksPath'
check "kl log shows the session"              '"$KL" log | grep -q "${SID:0:8}  sh *amended"'
check "kl log shows the outside commit as -"  '"$KL" log | grep -Eq " -  +-  +outside kl"'
check "kl sessions lists it as ended"         '"$KL" sessions | grep -q "${SID:0:8}.*ended *sh *3"'

# A rebase keeps each commit with the session that wrote it.
git checkout -q -b side HEAD~1 && echo s > s && git add s && git commit -qm "outside, on side"
"$KL" run sh -c 'echo "$KL_SESSION_ID" > "'"$T"'/sid2"; git rebase -q side main' 2>/dev/null
SID2="$(cat "$T/sid2")"
check "rebased commit keeps its session"      '[[ "$(sql "select session_id from commits where sha=\"$(git rev-parse main)\"")" == "$SID" ]]'
check "rebase adds no second trailer"         '[[ "$(git log -1 --format=%B main | grep -c Kl-Session)" == 1 ]]'
check "rewrite names the rebasing session"    '[[ "$(sql "select session_id from rewrites where kind=\"rebase\" limit 1")" == "$SID2" ]]'

# A harness that drops the environment: installed hooks find the session by repo.
"$KL" hooks install >/dev/null
"$KL" run sh -c 'echo "$KL_SESSION_ID" > "'"$T"'/sid3"; echo d > d; git add d
                 env -u KL_SESSION_ID -u GIT_CONFIG_COUNT git commit -qm "environment dropped"' 2>/dev/null
SID3="$(cat "$T/sid3")"
check "found by repo when env is dropped"     '[[ "$(sql "select session_id || \" \" || attribution from commits where sha=\"$(git rev-parse HEAD)\"")" == "$SID3 path" ]]'
echo e > e && git add e && git commit -qm "after the session"
check "no session, no attribution"            '[[ -z "$(sql "select session_id from commits where sha=\"$(git rev-parse HEAD)\"")" ]]'
"$KL" hooks uninstall >/dev/null
check "hooks uninstall restores the repo"     '! git config --local --get core.hooksPath'

# Failure modes.
check "gateway down: clear error, nothing run" '! KL_GATEWAY_URL=http://127.0.0.1:1 "$KL" run sh -c "touch $T/ran" 2>"$T/err" && grep -q "make up" "$T/err" && [[ ! -e "$T/ran" ]]'
check "exit code of the harness is returned"  '"$KL" run sh -c "exit 7" 2>/dev/null; [[ $? -eq 7 ]]'


# Snapshots and resume. FIRST is a commit from the first session; later commits exist after it.
cd "$T/repo" && git checkout -q main
FIRST="$(sql "select sha from commits where session_id=\"$SID\" and subject=\"first in session\"")"
HEAD_BEFORE="$(git rev-parse HEAD)"
check "snapshot copies the conversation"      '"$KL" snapshot "$(sql "select repo from commits limit 1")" "$FIRST" && [[ "$(sql "select request_id || \" \" || complete from snapshots where sha=\"$FIRST\"")" == "req-before 1" ]]'
"$KL" resume --print "$FIRST" > "$T/handoff" 2>/dev/null
check "handoff carries the summary"           'grep -q "STAND-IN NOTE for a transcript with 1 user message" "$T/handoff"'
check "handoff lists commits up to that one"  'grep -q "first in session" "$T/handoff" && ! grep -q "second in session" "$T/handoff"'
check "summary is kept, not written twice"    '"$KL" resume --print "$FIRST" >/dev/null 2>&1; [[ "$(grep -c /v1/chat/completions "$T/gateway.log")" == 1 ]]'
check "--print creates nothing"               '[[ ! -e "$T/repo-kl" ]]'
"$KL" resume --no-start "$FIRST" 2>/dev/null
W="$T/repo-kl/${FIRST:0:8}-1"
check "worktree is at the commit, new branch" '[[ "$(git -C "$W" rev-parse HEAD)" == "$FIRST" && "$(git -C "$W" branch --show-current)" == "kl/resume-${FIRST:0:8}-1" ]]'
check "handoff is in the worktree, ignored"   '[[ -s "$W/.kl/HANDOFF.md" && -z "$(git -C "$W" status --porcelain)" ]]'
check "original checkout is untouched"        '[[ "$(git rev-parse HEAD)" == "$HEAD_BEFORE" && "$(git branch --show-current)" == main ]]'
"$KL" resume --fg --harness sh "$FIRST" -c 'echo "$KL_SESSION_ID" > "'"$T"'/sid4"; echo r > r; git add r; git commit -qm "resumed work"' 2>/dev/null
SID4="$(cat "$T/sid4")"; W2="$T/repo-kl/${FIRST:0:8}-2"
check "second resume gets its own worktree"   '[[ "$(git -C "$W2" log -1 --format=%s)" == "resumed work" && "$(git -C "$W2" rev-parse HEAD~1)" == "$FIRST" ]]'
check "resumed session links to its origin"   '[[ "$(sql "select parent_session || \" \" || parent_commit from sessions where id=\"$SID4\"")" == "$SID $FIRST" ]]'
check "resumed commit is attributed"          '[[ "$(sql "select session_id from commits where subject=\"resumed work\"")" == "$SID4" ]]'
check "untracked commit: says so, still works" '"$KL" resume --print "$(git rev-list --max-parents=0 HEAD)" 2>/dev/null | grep -q "No conversation was recorded"'
check "options after the commit reach kl"     '"$KL" resume "$FIRST" --no-start 2>/dev/null && [[ -d "$T/repo-kl/${FIRST:0:8}-3" ]]'
check "unknown commit: clear error"           '! "$KL" resume --print nosuchcommit 2>"$T/err" && grep -q "is not a commit" "$T/err"'

# The manager agent, against a scripted model. Each question makes one tool call.
chat() { "$KL" chat "$@" 2>&1 </dev/null; }
check "manager lists sessions with a tool"     'chat sessions | grep -q "ANSWER: session=${SID4:0:8}; state=ended; harness=sh"'
check "manager key is its own, kept private"   'grep -q "\"key_alias\": \"kl-manager\"" "$T/gateway.log" && [[ "$(stat -c %a "$KL_HOME/manager.key" 2>/dev/null || stat -f %Lp "$KL_HOME/manager.key")" == 600 ]]'
check "tool call written as text still works"  'chat textcall | grep -q "ANSWER: repo=repo; sessions="'
check "get_commit: session, request, files"   'chat -v "commit: ${FIRST:0:8}" > "$T/gc"; grep -q "made by: session ${SID:0:8} (harness sh)" "$T/gc" && grep -q "the person said: build the thing" "$T/gc" && grep -q " b | 1 +" "$T/gc"'
check "a commit id is accepted for a session" 'chat "sessions" >/dev/null; python3 -c "
import sys, types; sys.argv=[\"kl\"]; core=types.ModuleType(\"core\"); core.__file__=\"$KL\"; exec(open(\"$KL\").read().split(\"if __name__\")[0], core.__dict__); core.__file__=\"$KL\"
sys.path.insert(0, \"$(dirname "$KL")\"); import manager
assert manager.Tools(core).session(\"${FIRST:0:8}\")[\"id\"] == \"$SID\""'
check "git tool reads"                         'chat "git: log -1 --format=%s main" | grep -q "after the session"'
check "git tool refuses to write a file"       'chat "git: diff --output=$T/leak HEAD~1" | grep -q "not allowed" && [[ ! -e "$T/leak" ]]'
check "git tool refuses other commands"        'chat "git: push origin main" | grep -q "allowed git commands"'
check "git tool refuses branch changes"        'chat "git: branch -D side" | grep -q "branch can only list" && git rev-parse -q --verify side >/dev/null'
check "read_file reads inside the repo"        'chat "read: a" | grep -q "ANSWER: 1: a"'
check "read_file refuses paths outside it"     'chat "read: ../home/ledger.sqlite" | grep -q "outside the repository"'
check "query tool runs a SELECT"               'chat "sql: select request_id from requests" | grep -q "req-before"'
check "query tool refuses anything else"       'chat "sql: delete from requests" | grep -q "only a single SELECT" && chat "sql: select 1; drop table x" | grep -q "only a single SELECT"'
N="$(ls "$T/repo-kl" | wc -l)"
check "resume without a yes does nothing"      'chat "resume repo $FIRST true" | grep -q "The person declined" && [[ "$(ls "$T/repo-kl" | wc -l)" == "$N" ]]'
check "resume shows what will happen"          'chat "resume repo $FIRST true" | grep -q "at commit ${FIRST:0:10} (\"first in session\")"'
check "resume with a yes starts a session"     'chat --yes "resume repo $FIRST true" | grep -q "kl: worktree" && [[ "$(ls "$T/repo-kl" | wc -l)" == "$((N + 1))" ]]'
check "resume of an unknown commit: no prompt" '! chat --yes "resume repo deadbeef true" | grep -q "Go ahead"'

# The local API: token, Host and Origin are all checked.
PORT=$((20000 + RANDOM % 20000))
"$KL" serve --port $PORT 2>"$T/serve.err" & SERVE=$!
trap 'kill $GW $SERVE 2>/dev/null || true; rm -rf "$T"' EXIT
for _ in $(seq 50); do grep -q token= "$T/serve.err" 2>/dev/null && break; sleep 0.1; done
TOKEN="$(cat "$KL_HOME/daemon.token")"; U="http://127.0.0.1:$PORT"
api() { curl -s --noproxy '*' -m 20 "$@"; }
check "API: no token, no access"               '[[ "$(api -o /dev/null -w "%{http_code}" $U/api/health)" == 401 ]]'
check "API: wrong token, no access"            '[[ "$(api -o /dev/null -w "%{http_code}" -H "Authorization: Bearer nope" $U/api/health)" == 401 ]]'
check "API: token gives access"                'api -H "Authorization: Bearer $TOKEN" $U/api/health | grep -q "\"ok\": true"'
check "API: other Host is refused"             '[[ "$(api -o /dev/null -w "%{http_code}" -H "Host: evil.example" -H "Authorization: Bearer $TOKEN" $U/api/health)" == 403 ]]'
check "API: other Origin cannot post"          '[[ "$(api -o /dev/null -w "%{http_code}" -H "Origin: http://evil.example" -H "Authorization: Bearer $TOKEN" -d "{}" $U/api/chat)" == 403 ]]'
check "API: sign-in link sets a strict cookie" 'api -D - -o /dev/null "$U/?token=$TOKEN" | grep -qi "set-cookie: kl_token=.*HttpOnly; SameSite=Strict"'
check "API: cookie gives access"               'api -H "Cookie: kl_token=$TOKEN" $U/api/health | grep -q "\"ok\": true"'
check "API: chat streams the steps"            'api -H "Authorization: Bearer $TOKEN" -d "{\"message\": \"sessions\"}" $U/api/chat > "$T/chat.out" && grep -q "\"type\": \"tool\", \"name\": \"list_sessions\"" "$T/chat.out" && grep -q "\"type\": \"text\"" "$T/chat.out" && tail -1 "$T/chat.out" | grep -q "\"waiting_for_confirmation\": false"'
api -H "Authorization: Bearer $TOKEN" -d "{\"conversation\": \"c1\", \"message\": \"resume repo $FIRST true\"}" $U/api/chat > "$T/chat.out"
check "API: resume waits for confirmation"     'grep -q "\"type\": \"confirm\"" "$T/chat.out" && tail -1 "$T/chat.out" | grep -q "\"waiting_for_confirmation\": true" && [[ "$(ls "$T/repo-kl" | wc -l)" == "$((N + 1))" ]]'
check "API: declining does nothing"            'api -H "Authorization: Bearer $TOKEN" -d "{\"conversation\": \"c1\", \"approve\": false}" $U/api/confirm | grep -q "The person declined" && [[ "$(ls "$T/repo-kl" | wc -l)" == "$((N + 1))" ]]'
kill $SERVE 2>/dev/null || true

# A launcher that is stopped still cleans up; one that is killed is cleaned up by the next run.
"$KL" run sleep 30 2>/dev/null & P=$!
for _ in $(seq 50); do [[ -n "$(sql "select id from sessions where ended_at is null")" ]] && break; sleep 0.1; done
A="$(sql "select key_alias from sessions where ended_at is null")"
kill -TERM $P; wait $P || true
check "SIGTERM: session closed, key deleted"   '[[ -z "$(sql "select id from sessions where ended_at is null")" ]] && grep -q "/key/delete.*sk-session-$A" "$T/gateway.log"'
"$KL" run sleep 30 2>/dev/null & P=$!
for _ in $(seq 50); do [[ -n "$(sql "select id from sessions where ended_at is null")" ]] && break; sleep 0.1; done
A="$(sql "select key_alias from sessions where ended_at is null")"
kill -KILL $P; wait $P 2>/dev/null || true; pkill -f "sleep 30" || true
"$KL" run true 2>/dev/null
check "killed launcher: next run deletes its key" '[[ -z "$(sql "select id from sessions where ended_at is null")" ]] && grep -q "/key/delete.*key_aliases.*$A" "$T/gateway.log"'

echo "$pass checks passed"
