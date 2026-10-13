#!/usr/bin/env bash
# Automated tests for ../setup.sh.
#
# Uses a local bare git repo as the "interview repo" (no network needed for
# cloning) and a restricted PATH to simulate missing tools, instead of a
# real uv/network dependency. Interactive prompts are driven with `expect`,
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

# ---------- fixture: a local bare repo to clone instead of hitting the network ----------
FIXTURE_SRC="$TMP_ROOT/fixture-src"
mkdir -p "$FIXTURE_SRC"
git init -q -b main "$FIXTURE_SRC"
cat > "$FIXTURE_SRC/.env.example" <<'EOF'
ANTHROPIC_API_KEY=
OTHER_VAR=keep-me
EOF
git -C "$FIXTURE_SRC" add -A
git -C "$FIXTURE_SRC" -c user.email=test@example.com -c user.name=test commit -qm init
BARE_REPO="$TMP_ROOT/fixture.git"
git clone -q --bare "$FIXTURE_SRC" "$BARE_REPO"

# A second fixture whose repo already *commits* a .env (simulating "the key
# merge logic must handle a .env that already exists in the fresh clone",
# e.g. a repeat run against a repo that tracks one, rather than relying on
# .env.example). Real clones can't pre-exist on disk before `git clone` runs
# (git refuses to clone into a non-empty directory), so this has to come
# from the repo's own history instead of being written to disk afterwards.
FIXTURE_ENV_SRC="$TMP_ROOT/fixture-env-src"
cp -R "$FIXTURE_SRC" "$FIXTURE_ENV_SRC"
rm -rf "$FIXTURE_ENV_SRC/.git"
git init -q -b main "$FIXTURE_ENV_SRC"
cat > "$FIXTURE_ENV_SRC/.env" <<'EOF'
ANTHROPIC_API_KEY=old-stale-value
UNRELATED=stays
EOF
git -C "$FIXTURE_ENV_SRC" add -A
git -C "$FIXTURE_ENV_SRC" -c user.email=test@example.com -c user.name=test commit -qm init
BARE_REPO_WITH_ENV="$TMP_ROOT/fixture-env.git"
git clone -q --bare "$FIXTURE_ENV_SRC" "$BARE_REPO_WITH_ENV"

# A repo carrying pyproject.toml, so the uv prerequisite check fires and the
# dependency install can be made to fail on demand (by withholding uv from the
# shimmed PATH). Used to prove a failed install doesn't lose a fetched key.
FIXTURE_UV_SRC="$TMP_ROOT/fixture-uv-src"
cp -R "$FIXTURE_SRC" "$FIXTURE_UV_SRC"
rm -rf "$FIXTURE_UV_SRC/.git"
git init -q -b main "$FIXTURE_UV_SRC"
cat > "$FIXTURE_UV_SRC/pyproject.toml" <<'EOF'
[project]
name = "fixture-uv"
version = "0.0.0"
EOF
git -C "$FIXTURE_UV_SRC" add -A
git -C "$FIXTURE_UV_SRC" -c user.email=test@example.com -c user.name=test commit -qm init
BARE_REPO_NEEDS_UV="$TMP_ROOT/fixture-uv.git"
git clone -q --bare "$FIXTURE_UV_SRC" "$BARE_REPO_NEEDS_UV"

# ---------- PATH shim helper: build a PATH containing only a whitelist of ----------
# real tools, letting us simulate "X is not installed" by omitting X.
# All the external (non-builtin) commands setup.sh can call are listed here.
ALL_SHIMMABLE="bash git python3 python uv curl wget grep tr basename cp touch chmod uname brew apt-get dnf pacman zypper node npm pnpm yarn ssh gh"

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
out="$(ANTHROPIC_API_KEY="  abc123  " PATH="$(make_shim_path '')" bash "$SETUP" "$BARE_REPO" 2>&1)"
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
out="$(KEY_NAME=MY_KEY MY_KEY="xyz" PATH="$(make_shim_path '')" bash "$SETUP" "$BARE_REPO" 2>&1)"
assert_contains "$(cat "$work/fixture/.env" 2>/dev/null)" "MY_KEY=xyz" "KEY_NAME override writes the right variable name"
cd "$HERE" || exit 1

# -- .env merge + replacement with special characters, against a repo that
# already has a real .env (not just .env.example) with a stale value --
special='AbC-123_+/=!@#%^&*()[]{}'
work="$TMP_ROOT/t3" && mkdir -p "$work" && cd "$work" || exit 1
out="$(ANTHROPIC_API_KEY="$special" PATH="$(make_shim_path '')" bash "$SETUP" "$BARE_REPO_WITH_ENV" 2>&1)"
content="$(cat "$work/fixture-env/.env" 2>/dev/null)"
assert_not_contains "$content" "old-stale-value" "special-char key: old value for the same name is replaced"
assert_contains "$content" "ANTHROPIC_API_KEY=$special" "special-char key: new value written verbatim"
assert_contains "$content" "UNRELATED=stays" "special-char key: unrelated existing lines are preserved"
cd "$HERE" || exit 1

echo "== interactive key entry (pseudo-terminal) =="
if command -v expect >/dev/null 2>&1; then
  work="$TMP_ROOT/t4" && mkdir -p "$work" && cd "$work" || exit 1
  shim_path="$(make_shim_path '')"
  out="$(expect -c "
    set timeout 20
    spawn env PATH=$shim_path bash $SETUP $BARE_REPO
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

echo "== folder-name derivation =="

# -- .git suffix --
work="$TMP_ROOT/t5" && mkdir -p "$work" && cd "$work" || exit 1
ANTHROPIC_API_KEY=k PATH="$(make_shim_path '')" bash "$SETUP" "$BARE_REPO" >/dev/null 2>&1
if [ -d "$work/fixture" ]; then ok "folder name: strips the .git suffix (fixture.git -> fixture)"; else fail "folder name: strips the .git suffix"; fi
cd "$HERE" || exit 1

# -- trailing slash --
work="$TMP_ROOT/t6" && mkdir -p "$work" && cd "$work" || exit 1
ANTHROPIC_API_KEY=k PATH="$(make_shim_path '')" bash "$SETUP" "$BARE_REPO/" >/dev/null 2>&1
if [ -d "$work/fixture" ]; then ok "folder name: strips a trailing slash"; else fail "folder name: strips a trailing slash"; fi
cd "$HERE" || exit 1

# -- a non-bare checkout path with no .git suffix at all --
work="$TMP_ROOT/t7" && mkdir -p "$work" && cd "$work" || exit 1
ANTHROPIC_API_KEY=k PATH="$(make_shim_path '')" bash "$SETUP" "$FIXTURE_SRC" >/dev/null 2>&1
if [ -d "$work/fixture-src" ]; then ok "folder name: plain path with no .git suffix"; else fail "folder name: plain path with no .git suffix"; fi
cd "$HERE" || exit 1

echo "== --check: pass / fail paths =="

out="$(PATH="$(make_shim_path '')" bash "$SETUP" --check </dev/null 2>&1)"
status=$?
assert_eq "$status" "0" "--check: exits 0 when everything is present"
assert_contains "$out" "[PASS] git" "--check: reports git as PASS"
assert_contains "$out" "[PASS] python" "--check: reports python as PASS"
assert_contains "$out" "[PASS] uv" "--check: reports uv as PASS"
assert_contains "$out" "ready for the interview" "--check: prints the ready message"

out="$(PATH="$(make_shim_path 'python3 python')" bash "$SETUP" --check --needs python </dev/null 2>&1)"
status=$?
assert_eq "$status" "1" "--check: exits non-zero when a required tool is missing"
assert_contains "$out" "[FAIL] python" "--check: reports python as FAIL when absent"
assert_contains "$out" "fix the items above" "--check: prints the fix-it message"

out="$(PATH="$(make_shim_path '')" bash "$SETUP" --check --needs bogus </dev/null 2>&1)"
status=$?
assert_eq "$status" "1" "--check --needs bogus: exits non-zero"
assert_contains "$out" "Unknown --needs item 'bogus'" "--check --needs bogus: clear error message"

# -- uv missing, offered an install, and the user declines (no network call should happen) --
if command -v expect >/dev/null 2>&1; then
  shim_path="$(make_shim_path 'uv')"
  out="$(expect -c "
    set timeout 20
    spawn env PATH=$shim_path bash $SETUP --check --needs uv
    expect \"Install it now\"
    send \"n\r\"
    expect eof
  " 2>&1)"
  assert_contains "$out" "[FAIL] uv" "--check: uv stays FAIL when the install offer is declined"
  assert_contains "$out" "fix the items above" "--check: declined uv install still ends with fix-it message"
else
  echo "  SKIP - 'expect' not installed, decline-install test skipped"
fi

echo "== tkinter: Linux-only check (uname spoofed, no Docker available here) =="
# setup.sh only runs the tkinter check on Linux. We don't have a Linux
# box/Docker in this environment, so we spoof `uname -s` to exercise that
# branch and verify the install-hint selection per package manager.
make_uname_shim() {
  # make_uname_shim "Linux|Darwin" -> echoes a dir with a fake `uname` first on PATH
  local os="$1" dir="$TMP_ROOT/uname-shim-$$-$RANDOM"
  mkdir -p "$dir"
  cat > "$dir/uname" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-s" ]; then echo "$os"; else command uname "\$@"; fi
EOF
  chmod +x "$dir/uname"
  echo "$dir"
}

for pm in apt-get dnf pacman zypper; do
  uname_dir="$(make_uname_shim Linux)"
  pm_dir="$TMP_ROOT/pm-$pm"
  mkdir -p "$pm_dir"
  cat > "$pm_dir/$pm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$pm_dir/$pm"
  shim_path="$(make_shim_path 'apt-get dnf pacman zypper brew')"
  out="$(PATH="$uname_dir:$pm_dir:$shim_path" bash "$SETUP" --check --needs tkinter </dev/null 2>&1)"
  case "$pm" in
    apt-get) expect_cmd="apt-get install -y python3-tk" ;;
    dnf)     expect_cmd="dnf install -y python3-tkinter" ;;
    pacman)  expect_cmd="pacman -S --noconfirm tk" ;;
    zypper)  expect_cmd="zypper install -y python3-tk" ;;
  esac
  assert_contains "$out" "$expect_cmd" "tkinter hint: picks the $pm command when $pm is present"
done

uname_dir="$(make_uname_shim Linux)"
shim_path="$(make_shim_path 'apt-get dnf pacman zypper brew')"
out="$(PATH="$uname_dir:$shim_path" bash "$SETUP" --check --needs tkinter </dev/null 2>&1)"
assert_contains "$out" "No known installer" "tkinter hint: falls back cleanly with no package manager available"
assert_contains "$out" "uv-managed Python, it already bundles a working tkinter" "tkinter hint: mentions the verified uv/macOS finding as a fallback tip"

# tkinter detection regex (used post-clone to decide whether to warn at all):
# sanity-check it matches real imports and ignores unrelated code, independent of OS.
detect_dir="$TMP_ROOT/detect"
mkdir -p "$detect_dir"
printf 'import tkinter\n' > "$detect_dir/a.py"
printf 'from tkinter import ttk\n' > "$detect_dir/b.py"
printf 'print("no gui here")\n' > "$detect_dir/c.py"
if grep -rIlq --include='*.py' -E '^\s*(import tkinter|from tkinter|import Tkinter)' "$detect_dir"; then
  ok "tkinter detection regex matches real tkinter imports"
else
  fail "tkinter detection regex matches real tkinter imports"
fi
rm -f "$detect_dir/a.py" "$detect_dir/b.py"
if grep -rIlq --include='*.py' -E '^\s*(import tkinter|from tkinter|import Tkinter)' "$detect_dir"; then
  fail "tkinter detection regex ignores files that don't import tkinter"
else
  ok "tkinter detection regex ignores files that don't import tkinter"
fi

echo
echo "== --claim: fetching the key from the service =="

# A stub claim service, so these tests never touch the real one. Mirrors the
# contract api/claim.ts actually implements: the key as the entire body on
# 200, a human-readable explanation plus a non-200 status on every refusal.
CLAIM_PORT=18731
CLAIM_DIR="$TMP_ROOT/claim"
mkdir -p "$CLAIM_DIR"
cat > "$CLAIM_DIR/server.py" <<'PY'
import http.server, urllib.parse, sys

CASES = {
    "GOODCODE": (200, "sk-ant-api03-fetched-by-claim-code"),
    "TOOEARLY": (409, "Your key unlocks at 14:55 UTC, just before your interview starts. Re-run this then.\n"),
    "USEDCODE": (410, "That claim code has already been used. If you need the key again, ask your interviewer.\n"),
    "NOSUCHCD": (404, "That claim code isn't recognised. Check it with your interviewer.\n"),
}

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        code = (q.get("code") or [""])[0].upper().replace("-", "").replace(" ", "")
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
  out="$(CLAIM_URL="$CLAIM_URL_TEST" PATH="$(make_shim_path '')" bash "$SETUP" --claim GOODCODE "$BARE_REPO" 2>&1)"
  status=$?
  assert_eq "$status" "0" "--claim: exits 0 on a valid code"
  assert_contains "$out" "Key received automatically" "--claim: says the key came automatically"
  assert_contains "$(cat "$work/fixture/.env" 2>/dev/null)" \
    "ANTHROPIC_API_KEY=sk-ant-api03-fetched-by-claim-code" "--claim: fetched key written to .env"
  assert_not_contains "$out" "Paste your API key" "--claim: never prompts for a paste"
  cd "$HERE" || exit 1

  # -- the case this was built for: candidate runs setup before the window --
  work="$TMP_ROOT/c2" && mkdir -p "$work" && cd "$work" || exit 1
  out="$(CLAIM_URL="$CLAIM_URL_TEST" PATH="$(make_shim_path '')" bash "$SETUP" --claim TOOEARLY "$BARE_REPO" 2>&1)"
  status=$?
  assert_eq "$status" "1" "--claim too early: exits non-zero"
  assert_contains "$out" "Your key unlocks at 14:55 UTC" "--claim too early: shows the unlock time from the service"
  assert_not_contains "$(cat "$work/fixture/.env" 2>/dev/null)" "sk-ant" "--claim too early: writes no key to .env"
  cd "$HERE" || exit 1

  # -- already used / unrecognised: the service's wording is passed through --
  work="$TMP_ROOT/c3" && mkdir -p "$work" && cd "$work" || exit 1
  out="$(CLAIM_URL="$CLAIM_URL_TEST" PATH="$(make_shim_path '')" bash "$SETUP" --claim USEDCODE "$BARE_REPO" 2>&1)"
  assert_contains "$out" "already been used" "--claim used: passes the service's message through"
  cd "$HERE" || exit 1

  work="$TMP_ROOT/c4" && mkdir -p "$work" && cd "$work" || exit 1
  out="$(CLAIM_URL="$CLAIM_URL_TEST" PATH="$(make_shim_path '')" bash "$SETUP" --claim NOSUCHCD "$BARE_REPO" 2>&1)"
  assert_contains "$out" "isn't recognised" "--claim unknown: passes the service's message through"
  cd "$HERE" || exit 1

  # -- lowercase/hyphenated as a candidate would actually type it --
  work="$TMP_ROOT/c5" && mkdir -p "$work" && cd "$work" || exit 1
  out="$(CLAIM_URL="$CLAIM_URL_TEST" PATH="$(make_shim_path '')" bash "$SETUP" --claim "good-code" "$BARE_REPO" 2>&1)"
  assert_contains "$(cat "$work/fixture/.env" 2>/dev/null)" \
    "ANTHROPIC_API_KEY=sk-ant-api03-fetched-by-claim-code" "--claim: lowercase and hyphenated code still works"
  cd "$HERE" || exit 1

  # -- a failed claim must leave nothing on disk: the code is single-use, so a
  # half-cloned directory plus a burned code leaves the candidate stuck --
  work="$TMP_ROOT/c8" && mkdir -p "$work" && cd "$work" || exit 1
  out="$(CLAIM_URL="$CLAIM_URL_TEST" PATH="$(make_shim_path '')" bash "$SETUP" --claim TOOEARLY "$BARE_REPO" 2>&1)"
  if [ -e "$work/fixture" ]; then
    fail "--claim too early: must not clone before the key is in hand (found $work/fixture)"
  else
    ok "--claim too early: nothing cloned, nothing left behind"
  fi
  assert_not_contains "$out" "Cloning into" "--claim too early: clone never started"
  cd "$HERE" || exit 1

  # -- and the retry with a good code then works from the same directory --
  work="$TMP_ROOT/c9" && mkdir -p "$work" && cd "$work" || exit 1
  CLAIM_URL="$CLAIM_URL_TEST" PATH="$(make_shim_path '')" bash "$SETUP" --claim NOSUCHCD "$BARE_REPO" >/dev/null 2>&1
  out="$(CLAIM_URL="$CLAIM_URL_TEST" PATH="$(make_shim_path '')" bash "$SETUP" --claim GOODCODE "$BARE_REPO" 2>&1)"
  assert_contains "$out" "Setup complete" "retry after a failed claim succeeds"
  assert_not_contains "$out" "already exists" "retry after a failed claim: no 'already exists' error"
  assert_contains "$(cat "$work/fixture/.env" 2>/dev/null)" \
    "ANTHROPIC_API_KEY=sk-ant-api03-fetched-by-claim-code" "retry after a failed claim writes the key"
  cd "$HERE" || exit 1

  # -- re-running over an existing clone reuses it instead of dying --
  work="$TMP_ROOT/c10" && mkdir -p "$work" && cd "$work" || exit 1
  CLAIM_URL="$CLAIM_URL_TEST" PATH="$(make_shim_path '')" bash "$SETUP" --claim GOODCODE "$BARE_REPO" >/dev/null 2>&1
  echo "candidate work in progress" > "$work/fixture/MY_NOTES.txt"
  out="$(CLAIM_URL="$CLAIM_URL_TEST" PATH="$(make_shim_path '')" bash "$SETUP" --claim GOODCODE "$BARE_REPO" 2>&1)"
  assert_contains "$out" "reusing it instead of cloning again" "second run reuses the existing clone"
  assert_contains "$out" "Setup complete" "second run completes"
  if [ -f "$work/fixture/MY_NOTES.txt" ]; then
    ok "second run preserves the candidate's own files"
  else
    fail "second run preserves the candidate's own files"
  fi
  cd "$HERE" || exit 1

  # -- a non-clone directory in the way gets a clear message, not a git error --
  work="$TMP_ROOT/c11" && mkdir -p "$work/fixture" && cd "$work" || exit 1
  echo "not a clone" > "$work/fixture/stray.txt"
  out="$(CLAIM_URL="$CLAIM_URL_TEST" PATH="$(make_shim_path '')" bash "$SETUP" --claim GOODCODE "$BARE_REPO" 2>&1)"
  assert_contains "$out" "isn't a git clone" "a non-clone directory in the way is explained"
  cd "$HERE" || exit 1

  # -- a failed dependency install must not lose the fetched key: the claim
  # code is single-use, so losing it here means the candidate can't retry --
  work="$TMP_ROOT/c12" && mkdir -p "$work" && cd "$work" || exit 1
  # uv withheld, against a repo that needs it, so the install step fails.
  out="$(CLAIM_URL="$CLAIM_URL_TEST" PATH="$(make_shim_path 'uv')" \
    bash "$SETUP" --claim GOODCODE "$BARE_REPO_NEEDS_UV" 2>&1 || true)"
  if grep -q "ANTHROPIC_API_KEY=sk-ant-api03-fetched-by-claim-code" "$work/fixture-uv/.env" 2>/dev/null; then
    ok "failed install still leaves the fetched key in .env (code not wasted)"
  else
    fail "failed install still leaves the fetched key in .env (code not wasted)"
    echo "---- output ----"; echo "$out" | tail -5; echo "----------------"
  fi
  cd "$HERE" || exit 1

  # -- an explicit key beats --claim, so the manual path still works --
  work="$TMP_ROOT/c6" && mkdir -p "$work" && cd "$work" || exit 1
  out="$(ANTHROPIC_API_KEY=explicit-wins CLAIM_URL="$CLAIM_URL_TEST" PATH="$(make_shim_path '')" \
    bash "$SETUP" --claim GOODCODE "$BARE_REPO" 2>&1)"
  assert_contains "$(cat "$work/fixture/.env" 2>/dev/null)" "ANTHROPIC_API_KEY=explicit-wins" \
    "--claim: an explicitly supplied key takes precedence"
  cd "$HERE" || exit 1

  kill "$CLAIM_PID" 2>/dev/null
  wait "$CLAIM_PID" 2>/dev/null
fi

# -- service unreachable: a clear message, not a stack trace or a hang --
work="$TMP_ROOT/c7" && mkdir -p "$work" && cd "$work" || exit 1
out="$(CLAIM_URL="http://127.0.0.1:1/" PATH="$(make_shim_path '')" bash "$SETUP" --claim GOODCODE "$BARE_REPO" 2>&1)"
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
