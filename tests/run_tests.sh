#!/usr/bin/env bash
# Automated tests for ../setup.sh.
#
# The interview project is already on disk (as it is on CoderPad), so each
# test gets its own copy of a fixture directory rather than a clone. Uses a
# restricted PATH to simulate missing tools, instead of a real uv/network
# dependency. Interactive prompts are driven with `expect`,
# which gives the script a real pseudo-terminal.
#
# Usage: bash tests/run_tests.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$HERE/../setup.sh"
PASS=0
FAIL=0

TMP_ROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }

assert_contains() {
  # assert_contains "$haystack" "needle" "description"
  if [[ "$1" == *"$2"* ]]; then ok "$3"; else
    fail "$3 (expected to find: $2)"
    echo "---- actual output ----"
    echo "$1"
    echo "------------------------"
  fi
}

assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then ok "$3"; else fail "$3 (did not expect: $2)"; fi
}

assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (expected '$2', got '$1')"; fi
}

# ---------- fixtures: project directories, as the candidate already has them ----------
# Deliberately not git repos. The script no longer needs git, and a fixture
# without .git is what proves it - see the git-withheld test below.
FIXTURE_SRC="$TMP_ROOT/fixture-src"
mkdir -p "$FIXTURE_SRC"
cat > "$FIXTURE_SRC/.env.example" <<'EOF'
ANTHROPIC_API_KEY=
OTHER_VAR=keep-me
EOF
cat > "$FIXTURE_SRC/pyproject.toml" <<'EOF'
[project]
name = "fixture"
version = "0.0.0"
EOF

# A second fixture that already has a real .env with a stale value, so the
# key-merge path is exercised against a file that exists rather than against
# .env.example.
FIXTURE_ENV_SRC="$TMP_ROOT/fixture-env-src"
cp -R "$FIXTURE_SRC" "$FIXTURE_ENV_SRC"
cat > "$FIXTURE_ENV_SRC/.env" <<'EOF'
ANTHROPIC_API_KEY=old-stale-value
UNRELATED=stays
EOF

# A third, identical in shape, kept separate only so the failed-install tests
# assert against their own directory and cannot be disturbed by another test.
FIXTURE_UV_SRC="$TMP_ROOT/fixture-uv-src"
cp -R "$FIXTURE_SRC" "$FIXTURE_UV_SRC"

# make_project <fixture-src> -> echoes a per-test copy, inside $work.
#
# Idempotent on purpose: the retry tests run setup twice against the same
# folder and the second run has to find what the first one left there, which
# is exactly what a candidate re-running the command gets.
make_project() {
  local src="$1" dest
  dest="$work/$(basename "$src")"
  dest="${dest%-src}"
  [ -d "$dest" ] || cp -R "$src" "$dest"
  echo "$dest"
}

# ---------- PATH shim helper: build a PATH containing only a whitelist of ----------
# real tools, letting us simulate "X is not installed" by omitting X.
# All the external (non-builtin) commands setup.sh can call are listed here.
# `sh` is on this list because the uv installer runs as `curl ... | sh`:
# without it that pipeline fails as 127 before curl is even reached, which
# looks like a script bug rather than a missing shim.
ALL_SHIMMABLE="bash sh git python3 python uv curl grep tr basename cp touch chmod mkdir uname"

make_shim_path() {
  # make_shim_path "omit1 omit2 ..." -> echoes a PATH to use
  local omit=" $1 "
  local dir="$TMP_ROOT/shim-$$-$RANDOM"
  mkdir -p "$dir"
  local bin real
  for bin in $ALL_SHIMMABLE; do
    case "$omit" in *" $bin "*) continue ;; esac
    real="$(command -v "$bin" 2>/dev/null || true)"
    [ -n "$real" ] && ln -sf "$real" "$dir/$bin"
  done
  echo "$dir"
}

echo "== .env handling =="

# -- env-var key: happy path, whitespace stripped, .env merged from .env.example --
work="$TMP_ROOT/t1" && mkdir -p "$work" && cd "$work" || exit 1
out="$(ANTHROPIC_API_KEY="  abc123  " PATH="$(make_shim_path '')" bash "$SETUP" "$(make_project "$FIXTURE_SRC")" 2>&1)"
status=$?
assert_eq "$status" "0" "env-var key: exits 0"
assert_contains "$out" "Key received (6 characters)" "env-var key: whitespace stripped before counting"
assert_contains "$out" "Setup complete" "env-var key: reports completion"
env_file="$work/fixture/.env"
if [ -f "$env_file" ]; then
  assert_contains "$(cat "$env_file")" "ANTHROPIC_API_KEY=abc123" "env-var key: .env has the stripped key"
  assert_contains "$(cat "$env_file")" "OTHER_VAR=keep-me" "env-var key: .env keeps other vars from .env.example"
else
  fail "env-var key: .env was created"
fi
cd "$HERE" || exit 1

# -- custom KEY_NAME --
work="$TMP_ROOT/t2" && mkdir -p "$work" && cd "$work" || exit 1
out="$(KEY_NAME=MY_KEY MY_KEY="xyz" PATH="$(make_shim_path '')" bash "$SETUP" "$(make_project "$FIXTURE_SRC")" 2>&1)"
assert_contains "$(cat "$work/fixture/.env" 2>/dev/null)" "MY_KEY=xyz" "KEY_NAME override writes the right variable name"
cd "$HERE" || exit 1

# -- .env merge + replacement with special characters, against a repo that
# already has a real .env (not just .env.example) with a stale value --
special='AbC-123_+/=!@#%^&*()[]{}'
work="$TMP_ROOT/t3" && mkdir -p "$work" && cd "$work" || exit 1
out="$(ANTHROPIC_API_KEY="$special" PATH="$(make_shim_path '')" bash "$SETUP" "$(make_project "$FIXTURE_ENV_SRC")" 2>&1)"
content="$(cat "$work/fixture-env/.env" 2>/dev/null)"
assert_not_contains "$content" "old-stale-value" "special-char key: old value for the same name is replaced"
assert_contains "$content" "ANTHROPIC_API_KEY=$special" "special-char key: new value written verbatim"
assert_contains "$content" "UNRELATED=stays" "special-char key: unrelated existing lines are preserved"
cd "$HERE" || exit 1

echo "== interactive key entry (pseudo-terminal) =="
if command -v expect >/dev/null 2>&1; then
  work="$TMP_ROOT/t4" && mkdir -p "$work" && cd "$work" || exit 1
  shim_path="$(make_shim_path '')"
  proj="$(make_project "$FIXTURE_SRC")"
  out="$(expect -c "
    set timeout 20
    spawn env PATH=$shim_path bash $SETUP $proj
    expect \"ANTHROPIC_API_KEY:\"
    send \"pasted-secret-key\r\"
    expect eof
  " 2>&1)"
  assert_contains "$out" "Key received (17 characters)" "interactive paste: key length reported correctly"
  assert_contains "$(cat "$work/fixture/.env" 2>/dev/null)" "ANTHROPIC_API_KEY=pasted-secret-key" "interactive paste: .env written from PTY input"
  cd "$HERE" || exit 1
else
  echo "  SKIP - 'expect' not installed, interactive-paste test skipped"
fi

echo "== finding the project =="

# -- the CoderPad case: run from inside the project, no argument at all --
work="$TMP_ROOT/t5" && mkdir -p "$work" && cd "$work" || exit 1
proj="$(make_project "$FIXTURE_SRC")"
out="$(cd "$proj" && ANTHROPIC_API_KEY=k PATH="$(make_shim_path '')" bash "$SETUP" 2>&1)"
assert_contains "$out" "Setup complete" "no argument: sets up the folder you are standing in"
assert_contains "$(cat "$proj/.env" 2>/dev/null)" "ANTHROPIC_API_KEY=k" "no argument: writes .env into that folder"
cd "$HERE" || exit 1

# -- a trailing slash on the directory is accepted --
work="$TMP_ROOT/t6" && mkdir -p "$work" && cd "$work" || exit 1
proj="$(make_project "$FIXTURE_SRC")"
out="$(ANTHROPIC_API_KEY=k PATH="$(make_shim_path '')" bash "$SETUP" "$proj/" 2>&1)"
assert_contains "$out" "Setup complete" "a trailing slash on the project directory is accepted"
cd "$HERE" || exit 1

# -- the shipping case: setup.sh lives in the project, so running it from
# somewhere else entirely still sets up the project it sits in --
work="$TMP_ROOT/t5b" && mkdir -p "$work/elsewhere" && cd "$work" || exit 1
proj="$(make_project "$FIXTURE_SRC")"
cp "$SETUP" "$proj/setup.sh"
out="$(cd "$work/elsewhere" && ANTHROPIC_API_KEY=k PATH="$(make_shim_path '')" bash "$proj/setup.sh" 2>&1)"
assert_contains "$out" "Setup complete" "script inside the project: runs from any directory"
assert_contains "$(cat "$proj/.env" 2>/dev/null)" "ANTHROPIC_API_KEY=k" "script inside the project: sets up its own folder"
assert_not_contains "$out" "doesn't look like the interview project" "script inside the project: never looks in the caller's directory"
cd "$HERE" || exit 1

# -- but a copy sitting somewhere that is not a project must not insist on its
# own folder: it falls back to the working directory, as before --
work="$TMP_ROOT/t5c" && mkdir -p "$work/loose" && cd "$work" || exit 1
proj="$(make_project "$FIXTURE_SRC")"
cp "$SETUP" "$work/loose/setup.sh"
out="$(cd "$proj" && ANTHROPIC_API_KEY=k PATH="$(make_shim_path '')" bash "$work/loose/setup.sh" 2>&1)"
assert_contains "$out" "Setup complete" "script outside a project: falls back to the working directory"
assert_contains "$(cat "$proj/.env" 2>/dev/null)" "ANTHROPIC_API_KEY=k" "script outside a project: sets up the folder you are in"
cd "$HERE" || exit 1

# -- the wrong folder: the common CoderPad mistake is the project's parent,
# so the message has to name the folder it is in and point at the right one --
work="$TMP_ROOT/t7" && mkdir -p "$work" && cd "$work" || exit 1
proj="$(make_project "$FIXTURE_SRC")"
out="$(ANTHROPIC_API_KEY=k PATH="$(make_shim_path '')" bash "$SETUP" "$work" 2>&1)" && status=0 || status=$?
assert_contains "$out" "doesn't look like the interview project" "wrong folder: says so plainly"
assert_contains "$out" "Did you mean" "wrong folder: suggests the project it can see alongside"
assert_contains "$out" "fixture" "wrong folder: names that project in the suggestion"
# The message alone is not enough: without this, dropping the `die` leaves the
# warning on screen and carries on into the install in the wrong directory.
assert_eq "$status" "1" "wrong folder: stops instead of carrying on"
assert_not_contains "$out" "Setup complete" "wrong folder: never reports success"
assert_not_contains "$(cat "$proj/.env" 2>/dev/null)" "ANTHROPIC_API_KEY=k" "wrong folder: writes nothing into the project it found"
cd "$HERE" || exit 1

# -- an argument that is not a directory at all --
work="$TMP_ROOT/t8" && mkdir -p "$work" && cd "$work" || exit 1
out="$(ANTHROPIC_API_KEY=k PATH="$(make_shim_path '')" bash "$SETUP" "$work/nope" 2>&1 || true)"
assert_contains "$out" "isn't a directory" "a non-directory argument is explained"
cd "$HERE" || exit 1

# -- an old command from an older setup email, still passing a repo URL --
work="$TMP_ROOT/t9" && mkdir -p "$work" && cd "$work" || exit 1
out="$(ANTHROPIC_API_KEY=k PATH="$(make_shim_path '')" bash "$SETUP" --claim GOODCODE "https://github.com/Fuse-Energy-Interviews/ai-chatbot-interview" 2>&1 || true)"
assert_contains "$out" "no longer clones anything" "a repo URL argument explains that nothing is cloned"
out="$(ANTHROPIC_API_KEY=k PATH="$(make_shim_path '')" bash "$SETUP" "git@github.com:Fuse-Energy-Interviews/ai-chatbot-interview.git" 2>&1 || true)"
assert_contains "$out" "no longer clones anything" "an ssh repo URL argument is caught the same way"
cd "$HERE" || exit 1

# -- git withheld entirely: the point of the change. CoderPad hands over an
# unpacked folder, sometimes with no git at all --
work="$TMP_ROOT/t10" && mkdir -p "$work" && cd "$work" || exit 1
proj="$(make_project "$FIXTURE_SRC")"
out="$(ANTHROPIC_API_KEY=k PATH="$(make_shim_path 'git')" bash "$SETUP" "$proj" 2>&1)"
assert_contains "$out" "Setup complete" "works with no git installed at all"
assert_not_contains "$out" "git is not installed" "never asks for git"
cd "$HERE" || exit 1

echo "== the lockfile ==="

# -- with a uv.lock present the install must be --frozen, so the interview
# environment is the one the exercise was tested against. A plain `uv sync`
# re-resolves to the newest versions pyproject.toml allows, which is how
# litellm moved from 1.104.2 to 1.108.3 under a candidate and failed as
# "No module named 'mcp'" mid-setup --
work="$TMP_ROOT/l1" && mkdir -p "$work" && cd "$work" || exit 1
proj="$(make_project "$FIXTURE_SRC")"
printf 'version = 1
' > "$proj/uv.lock"
shim="$(make_shim_path 'uv')"
rm -f "$shim/uv"
cat > "$shim/uv" <<'FAKEUV'
#!/usr/bin/env bash
echo "UV CALLED: $*"
exit 0
FAKEUV
chmod +x "$shim/uv"
out="$(ANTHROPIC_API_KEY=k PATH="$shim" bash "$SETUP" "$proj" 2>&1)"
assert_contains "$out" "UV CALLED: sync --frozen" "with a lockfile: installs --frozen, never re-resolving"
assert_not_contains "$out" "no uv.lock" "with a lockfile: no warning"
cd "$HERE" || exit 1

# -- and without one it still installs, but says so loudly: a silent fresh
# resolve is the failure mode this is here to make visible --
work="$TMP_ROOT/l2" && mkdir -p "$work" && cd "$work" || exit 1
proj="$(make_project "$FIXTURE_SRC")"
shim="$(make_shim_path 'uv')"
rm -f "$shim/uv"
cat > "$shim/uv" <<'FAKEUV'
#!/usr/bin/env bash
echo "UV CALLED: $*"
exit 0
FAKEUV
chmod +x "$shim/uv"
out="$(ANTHROPIC_API_KEY=k PATH="$shim" bash "$SETUP" "$proj" 2>&1)"
assert_contains "$out" "no uv.lock" "without a lockfile: warns that versions are unpinned"
assert_contains "$out" "not the tested environment" "without a lockfile: says what that means"
assert_contains "$out" "UV CALLED: sync" "without a lockfile: still installs"
assert_not_contains "$out" "--frozen" "without a lockfile: cannot use --frozen"
assert_contains "$out" "Setup complete" "without a lockfile: does not block the candidate"
cd "$HERE" || exit 1

echo "== litellm's undeclared mcp dependency =="

# A uv stub whose `run` arm decides the probe's answer, so both branches can
# be driven without a real litellm in the venv.
make_uv_stub() {
  # make_uv_stub <shim-dir> <probe-exit-code>
  rm -f "$1/uv"
  cat > "$1/uv" <<FAKEUV
#!/usr/bin/env bash
echo "UV CALLED: \$*"
case "\$*" in
  # litellm is present in this project...
  *"import litellm'"*) exit 0 ;;
  # ...but whether its MCP handler loads is what the test is driving.
  *litellm_proxy_mcp_handler*) exit $2 ;;
  *) exit 0 ;;
esac
FAKEUV
  chmod +x "$1/uv"
}

# -- probe fails (a litellm whose MCP path needs `mcp`): the dependency is
# added, and after `uv sync`, never before - sync prunes anything absent from
# the lock, so an install above it is silently undone --
work="$TMP_ROOT/m1" && mkdir -p "$work" && cd "$work" || exit 1
proj="$(make_project "$FIXTURE_SRC")"
printf 'version = 1
' > "$proj/uv.lock"
shim="$(make_shim_path 'uv')"
make_uv_stub "$shim" 1
out="$(ANTHROPIC_API_KEY=k PATH="$shim" bash "$SETUP" "$proj" 2>&1)"
assert_contains "$out" "Adding litellm's MCP dependency" "probe fails: says it is adding the dependency"
assert_contains "$out" "UV CALLED: add mcp>=2.3.0,<3" "probe fails: adds mcp, pinned to what litellm's extra asks for"
# Ordering: the sync must appear before the add, or the sync undoes it.
sync_line="$(printf '%s
' "$out" | grep -n 'UV CALLED: sync' | head -1 | cut -d: -f1)"
add_line="$(printf '%s
' "$out" | grep -n 'UV CALLED: add' | head -1 | cut -d: -f1)"
if [ -n "$sync_line" ] && [ -n "$add_line" ] && [ "$sync_line" -lt "$add_line" ]; then
  ok "probe fails: the add comes after the sync, so sync cannot prune it"
else
  fail "probe fails: the add comes after the sync (sync=$sync_line add=$add_line)"
fi
# And before the claim, so a failure here cannot spend a single-use code.
assert_not_contains "$out" "Fetching your API key" "probe fails: repair runs before the claim"
cd "$HERE" || exit 1

# -- probe passes (a correctly pinned litellm that needs no `mcp`): nothing is
# installed. Probing the exact module litellm fails on, rather than importing
# `mcp` itself, is what makes this branch possible --
work="$TMP_ROOT/m2" && mkdir -p "$work" && cd "$work" || exit 1
proj="$(make_project "$FIXTURE_SRC")"
printf 'version = 1
' > "$proj/uv.lock"
shim="$(make_shim_path 'uv')"
make_uv_stub "$shim" 0
out="$(ANTHROPIC_API_KEY=k PATH="$shim" bash "$SETUP" "$proj" 2>&1)"
assert_not_contains "$out" "Adding litellm's MCP dependency" "probe passes: says nothing"
assert_not_contains "$out" "UV CALLED: add" "probe passes: installs nothing"
assert_contains "$out" "Setup complete" "probe passes: completes normally"
cd "$HERE" || exit 1

echo "== installing uv =="

# -- uv missing: installed without asking. On a personal laptop a prompt was
# right; in a disposable interview container it is friction, and hangs the
# setup outright when there is no terminal to answer from. A fake curl keeps
# this off the network - the real installer must never run from the suite --
work="$TMP_ROOT/u1" && mkdir -p "$work" && cd "$work" || exit 1
shim="$(make_shim_path 'uv')"
# rm first: make_shim_path leaves a *symlink* to the real curl here, and
# writing through a symlink writes to its target - /usr/bin/curl - not to the
# shim. Root owns that file so the write is refused rather than destructive,
# but the fake then never exists and the test quietly proves nothing.
rm -f "$shim/curl"
cat > "$shim/curl" <<'FAKE'
#!/usr/bin/env bash
echo "FAKE CURL CALLED: $*" >&2
exit 7
FAKE
chmod +x "$shim/curl"
proj="$(make_project "$FIXTURE_SRC")"
out="$(ANTHROPIC_API_KEY=k PATH="$shim" bash "$SETUP" "$proj" 2>&1)" && status=0 || status=$?
assert_contains "$out" "Installing uv" "missing uv: says it is installing it"
assert_not_contains "$out" "[y/N]" "missing uv: never prompts"
assert_contains "$out" "FAKE CURL CALLED" "missing uv: goes through curl (and only the fake one here)"
assert_eq "$status" "1" "missing uv: a failed install stops the run"
assert_contains "$out" "Couldn't download uv" "missing uv: a failed download is explained, not a bare exit code"
assert_not_contains "$out" "Setup complete" "missing uv: never reports success"
cd "$HERE" || exit 1

echo "== --claim: fetching the key from the service =="

# A stub claim service, so these tests never touch the real one. Mirrors the
# contract the service actually implements: the code arrives in the
# X-Claim-Code header, and the key comes back as the entire body on 200, with
# a human-readable explanation plus a non-200 status on every refusal.
#
# Header, not query string. The code is a credential and a query string is
# written verbatim into access logs; reading only the header here means a
# regression back to the query string fails these tests instead of passing
# them quietly.
CLAIM_PORT=18731
CLAIM_DIR="$TMP_ROOT/claim"
mkdir -p "$CLAIM_DIR"
cat > "$CLAIM_DIR/server.py" <<'PY'
import http.server, urllib.parse, sys

CASES = {
    "GOODCODE": (200, "sk-ant-api03-fetched-by-claim-code"),
    # A later interview's code: a different key, so a test can tell which one
    # the script ended up with.
    "NEXTCODE": (200, "sk-ant-api03-second-interview-key"),
    "TOOEARLY": (409, "Your key unlocks at 14:55 UTC, just before your interview starts. Re-run this then.\n"),
    "USEDCODE": (410, "That claim code has already been used. If you need the key again, ask your interviewer.\n"),
    "NOSUCHCD": (404, "That claim code isn't recognised. Check it with your interviewer.\n"),
}

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        raw = self.headers.get("X-Claim-Code", "")
        code = raw.upper().replace("-", "").replace(" ", "")
        if urllib.parse.urlparse(self.path).query:
            status, body = 400, "the claim code must not travel in the query string\n"
        else:
            status, body = CASES.get(code, (404, "unknown\n"))
        payload = body.encode()
        self.send_response(status)
        self.send_header("content-type", "text/plain; charset=utf-8")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

CLAIM_PY="$(command -v python3 || command -v python || true)"
if [ -z "$CLAIM_PY" ]; then
  echo "  SKIP - no python available to run the stub claim service"
else
  "$CLAIM_PY" "$CLAIM_DIR/server.py" "$CLAIM_PORT" &
  CLAIM_PID=$!
  # Wait for it to accept connections rather than sleeping a fixed guess.
  for _ in $(seq 1 50); do
    curl -fsS -o /dev/null "http://127.0.0.1:$CLAIM_PORT/?code=GOODCODE" 2>/dev/null && break
    sleep 0.1
  done
  CLAIM_URL_TEST="http://127.0.0.1:$CLAIM_PORT/"

  # -- happy path: key fetched, written to .env, nothing pasted --
  work="$TMP_ROOT/c1" && mkdir -p "$work" && cd "$work" || exit 1
  out="$(CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" bash "$SETUP" --claim GOODCODE "$(make_project "$FIXTURE_SRC")" 2>&1)"
  status=$?
  assert_eq "$status" "0" "--claim: exits 0 on a valid code"
  assert_contains "$out" "Key received automatically" "--claim: says the key came automatically"
  assert_contains "$(cat "$work/fixture/.env" 2>/dev/null)" \
    "ANTHROPIC_API_KEY=sk-ant-api03-fetched-by-claim-code" "--claim: fetched key written to .env"
  assert_not_contains "$out" "Paste your API key" "--claim: never prompts for a paste"
  cd "$HERE" || exit 1

  # -- the case this was built for: candidate runs setup before the window --
  work="$TMP_ROOT/c2" && mkdir -p "$work" && cd "$work" || exit 1
  out="$(CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" bash "$SETUP" --claim TOOEARLY "$(make_project "$FIXTURE_SRC")" 2>&1)"
  status=$?
  assert_eq "$status" "1" "--claim too early: exits non-zero"
  assert_contains "$out" "Your key unlocks at 14:55 UTC" "--claim too early: shows the unlock time from the service"
  assert_not_contains "$(cat "$work/fixture/.env" 2>/dev/null)" "sk-ant" "--claim too early: writes no key to .env"
  cd "$HERE" || exit 1

  # -- already used / unrecognised: the service's wording is passed through --
  work="$TMP_ROOT/c3" && mkdir -p "$work" && cd "$work" || exit 1
  out="$(CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" bash "$SETUP" --claim USEDCODE "$(make_project "$FIXTURE_SRC")" 2>&1)"
  assert_contains "$out" "already been used" "--claim used: passes the service's message through"
  cd "$HERE" || exit 1

  work="$TMP_ROOT/c4" && mkdir -p "$work" && cd "$work" || exit 1
  out="$(CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" bash "$SETUP" --claim NOSUCHCD "$(make_project "$FIXTURE_SRC")" 2>&1)"
  assert_contains "$out" "isn't recognised" "--claim unknown: passes the service's message through"
  cd "$HERE" || exit 1

  # -- lowercase/hyphenated as a candidate would actually type it --
  work="$TMP_ROOT/c5" && mkdir -p "$work" && cd "$work" || exit 1
  out="$(CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" bash "$SETUP" --claim "good-code" "$(make_project "$FIXTURE_SRC")" 2>&1)"
  assert_contains "$(cat "$work/fixture/.env" 2>/dev/null)" \
    "ANTHROPIC_API_KEY=sk-ant-api03-fetched-by-claim-code" "--claim: lowercase and hyphenated code still works"
  cd "$HERE" || exit 1

  # -- a too-early code is the ordinary case, and the install now runs before
  # the claim. So the candidate waits once, and the retry at the unlock time
  # only has to fetch the key. What matters is that the code is unspent and
  # nothing is left in a state that blocks the retry --
  work="$TMP_ROOT/c8" && mkdir -p "$work" && cd "$work" || exit 1
  proj="$(make_project "$FIXTURE_SRC")"
  out="$(CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" bash "$SETUP" --claim TOOEARLY "$proj" 2>&1)"
  assert_not_contains "$(cat "$proj/.env" 2>/dev/null)" "sk-ant" "--claim too early: leaves no key behind"
  out="$(CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" bash "$SETUP" --claim GOODCODE "$proj" 2>&1)"
  assert_contains "$out" "Setup complete" "--claim too early: the retry completes"
  assert_contains "$(cat "$proj/.env" 2>/dev/null)" \
    "ANTHROPIC_API_KEY=sk-ant-api03-fetched-by-claim-code" "--claim too early: the retry claims the key"
  cd "$HERE" || exit 1

  # -- and the retry with a good code then works from the same directory --
  work="$TMP_ROOT/c9" && mkdir -p "$work" && cd "$work" || exit 1
  CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" bash "$SETUP" --claim NOSUCHCD "$(make_project "$FIXTURE_SRC")" >/dev/null 2>&1
  out="$(CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" bash "$SETUP" --claim GOODCODE "$(make_project "$FIXTURE_SRC")" 2>&1)"
  assert_contains "$out" "Setup complete" "retry after a failed claim succeeds"
  assert_not_contains "$out" "already exists" "retry after a failed claim: no 'already exists' error"
  assert_contains "$(cat "$work/fixture/.env" 2>/dev/null)" \
    "ANTHROPIC_API_KEY=sk-ant-api03-fetched-by-claim-code" "retry after a failed claim writes the key"
  cd "$HERE" || exit 1

  # -- re-running in a folder the candidate has already worked in. Nothing is
  # cloned or cleaned, so their files have to survive untouched --
  work="$TMP_ROOT/c10" && mkdir -p "$work" && cd "$work" || exit 1
  proj="$(make_project "$FIXTURE_SRC")"
  CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" bash "$SETUP" --claim GOODCODE "$proj" >/dev/null 2>&1
  echo "candidate work in progress" > "$proj/MY_NOTES.txt"
  out="$(CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" bash "$SETUP" --claim GOODCODE "$proj" 2>&1)"
  assert_contains "$out" "Setup complete" "second run completes"
  if [ -f "$proj/MY_NOTES.txt" ]; then
    ok "second run preserves the candidate's own files"
  else
    fail "second run preserves the candidate's own files"
  fi
  assert_contains "$(cat "$proj/MY_NOTES.txt" 2>/dev/null)" "candidate work in progress" \
    "second run leaves their contents alone"
  cd "$HERE" || exit 1

  # -- a failed dependency install must not spend the claim code. The install
  # runs before the claim, so a failure there leaves the code untouched and
  # the retry can still use it. This is what keeps a failed install a
  # retryable annoyance rather than a call to the interviewer mid-interview --
  work="$TMP_ROOT/c12" && mkdir -p "$work" && cd "$work" || exit 1
  # uv withheld so the install step fails - and curl withheld with it, because
  # uv is now installed without asking, and with curl present this test would
  # fetch the real installer from astral.sh on every run.
  out="$(CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path 'uv curl')" \
    bash "$SETUP" --claim GOODCODE "$(make_project "$FIXTURE_UV_SRC")" 2>&1 || true)"
  assert_not_contains "$out" "Fetching your API key" \
    "failed install never reaches the claim (code not spent)"
  # and the retry, with uv available, takes the key the first run never claimed
  out="$(CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" \
    bash "$SETUP" --claim GOODCODE "$(make_project "$FIXTURE_UV_SRC")" 2>&1 || true)"
  assert_contains "$(cat "$work/fixture-uv/.env" 2>/dev/null)" \
    "ANTHROPIC_API_KEY=sk-ant-api03-fetched-by-claim-code" \
    "retry after a failed install claims the key"
  cd "$HERE" || exit 1

  # -- the failure that interrupted a live interview: setup failed after the
  # claim had already succeeded, so re-running the command spent the
  # single-use code a second time and got a 410, while a working key sat on
  # disk. The re-run must not reach the service at all - so this points it at
  # a dead port, where any call would fail loudly rather than silently pass --
  work="$TMP_ROOT/c13" && mkdir -p "$work" && cd "$work" || exit 1
  CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" \
    bash "$SETUP" --claim GOODCODE "$(make_project "$FIXTURE_SRC")" >/dev/null 2>&1
  out="$(CLAIM_URL="http://127.0.0.1:1/" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" \
    bash "$SETUP" --claim GOODCODE "$(make_project "$FIXTURE_SRC")" 2>&1)"
  status=$?
  assert_eq "$status" "0" "re-running the same command succeeds without re-claiming"
  assert_contains "$out" "reusing it, no need to claim again" "re-run reuses the key that code already bought"
  assert_not_contains "$out" "Couldn't reach" "re-run makes no network call at all"
  assert_contains "$(cat "$work/fixture/.env" 2>/dev/null)" \
    "ANTHROPIC_API_KEY=sk-ant-api03-fetched-by-claim-code" "re-run keeps the key"
  cd "$HERE" || exit 1

  # -- and from a different folder, where there is no .env to fall back on.
  # This is why the key is remembered under the code in a fixed location
  # rather than in the checkout --
  work2="$TMP_ROOT/c13b" && mkdir -p "$work2" && cd "$work2" || exit 1
  cp -R "$FIXTURE_SRC" "$work2/fixture"
  out="$(CLAIM_URL="http://127.0.0.1:1/" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" \
    bash "$SETUP" --claim GOODCODE "$work2/fixture" 2>&1)"
  assert_contains "$out" "reusing it, no need to claim again" \
    "a re-run from another folder still finds the key that code bought"
  assert_contains "$(cat "$work2/fixture/.env" 2>/dev/null)" \
    "ANTHROPIC_API_KEY=sk-ant-api03-fetched-by-claim-code" "the other folder gets the same key"
  cd "$HERE" || exit 1

  # -- a *different* code is a different interview, and must claim its own
  # key. Reusing the previous one would hand the candidate a key revoked
  # minutes after that interview ended: a 401 with nothing explaining it --
  work="$TMP_ROOT/c13c" && mkdir -p "$work" && cd "$work" || exit 1
  CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" \
    bash "$SETUP" --claim GOODCODE "$(make_project "$FIXTURE_SRC")" >/dev/null 2>&1
  out="$(CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" \
    bash "$SETUP" --claim NEXTCODE "$(make_project "$FIXTURE_SRC")" 2>&1)"
  assert_not_contains "$out" "no need to claim again" "a new code does not reuse the previous interview's key"
  assert_contains "$(cat "$work/fixture/.env" 2>/dev/null)" \
    "ANTHROPIC_API_KEY=sk-ant-api03-second-interview-key" "a new code claims and writes its own key"
  cd "$HERE" || exit 1

  # -- a claim code that is plainly not one is rejected before any work. The
  # claim runs last now, so without this a bad paste costs a full dependency
  # install before the service gets to say so --
  work="$TMP_ROOT/c14" && mkdir -p "$work" && cd "$work" || exit 1
  proj="$(make_project "$FIXTURE_SRC")"
  out="$(CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" \
    bash "$SETUP" --claim "the code from my email is GOODCODE i think" "$proj" 2>&1 || true)"
  assert_contains "$out" "doesn't look like a claim code" "a pasted sentence is rejected as a claim code"
  assert_not_contains "$out" "Fetching your API key" "a rejected claim code reaches no service"
  if [ -e "$proj/.env" ]; then
    fail "a rejected claim code touches nothing in the project"
  else
    ok "a rejected claim code touches nothing in the project"
  fi
  cd "$HERE" || exit 1

  # -- if .env cannot be written the key must still reach the candidate. The
  # code is spent by then, so a silent failure here is the one path that ends
  # with a used code and no key at all --
  work="$TMP_ROOT/c15" && mkdir -p "$work" && cd "$work" || exit 1
  proj="$(make_project "$FIXTURE_SRC")"
  printf 'SOMETHING_ELSE=keepme\n' > "$proj/.env"
  chmod 444 "$proj/.env"
  out="$(CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" \
    bash "$SETUP" --claim GOODCODE "$proj" 2>&1 || true)"
  chmod 644 "$proj/.env"
  assert_contains "$out" "couldn't write the key" "an unwritable .env is reported, not swallowed"
  assert_contains "$out" "sk-ant-api03-fetched-by-claim-code" \
    "an unwritable .env still hands the candidate the key it already claimed"
  cd "$HERE" || exit 1

  # -- an explicit key beats --claim, so the manual path still works --
  work="$TMP_ROOT/c6" && mkdir -p "$work" && cd "$work" || exit 1
  out="$(ANTHROPIC_API_KEY=explicit-wins CLAIM_URL="$CLAIM_URL_TEST" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" \
    bash "$SETUP" --claim GOODCODE "$(make_project "$FIXTURE_SRC")" 2>&1)"
  assert_contains "$(cat "$work/fixture/.env" 2>/dev/null)" "ANTHROPIC_API_KEY=explicit-wins" \
    "--claim: an explicitly supplied key takes precedence"
  cd "$HERE" || exit 1

  kill "$CLAIM_PID" 2>/dev/null
  wait "$CLAIM_PID" 2>/dev/null
fi

# -- service unreachable: a clear message, not a stack trace or a hang --
work="$TMP_ROOT/c7" && mkdir -p "$work" && cd "$work" || exit 1
out="$(CLAIM_URL="http://127.0.0.1:1/" XDG_CACHE_HOME="$work/cache" PATH="$(make_shim_path '')" bash "$SETUP" --claim GOODCODE "$(make_project "$FIXTURE_SRC")" 2>&1)"
assert_contains "$out" "Couldn't reach the key service" "--claim unreachable: explains the connection failure"
cd "$HERE" || exit 1

echo
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$SETUP"; then ok "shellcheck: no findings on setup.sh"; else fail "shellcheck: findings on setup.sh"; fi
else
  echo "  SKIP - shellcheck not installed"
fi

echo
echo "---------------------------------------------"
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
