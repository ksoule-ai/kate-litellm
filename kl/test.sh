#!/usr/bin/env bash
# End-to-end test of `kl run`, the hooks and the ledger, against a stand-in for
# the gateway's key endpoints. Needs git and python3; touches nothing
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
        out = json.dumps({"key": "sk-session-" + body.get("key_alias", "")}).encode()
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
