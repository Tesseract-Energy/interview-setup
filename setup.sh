#!/usr/bin/env bash
# Usage: bash setup.sh <repo-url>
#
# Clones the repo, checks/installs prerequisites, installs dependencies, then
# asks you to paste the API key (input is hidden) and writes it to .env.
#
# Or fetch the key automatically with the claim code your interviewer gave you:
#   bash setup.sh --claim ABCD-2345 <repo-url>
#
# Non-interactive alternative: ANTHROPIC_API_KEY=... bash setup.sh <repo-url>
# Set KEY_NAME to use a different env var name (default: ANTHROPIC_API_KEY).
#
# Dry run, no clone, no key, no .env changes:
#   bash setup.sh --check
#   bash setup.sh --check --needs git,uv,node   (default needs: git,python,uv)
set -euo pipefail

# ---------- helpers (needed before argument parsing can use them) ----------
die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage:
  bash setup.sh <repo-url>
  bash setup.sh --check [--needs git,uv,node]

  <repo-url>        Clone this repo and set it up for the interview.
  --claim CODE      Fetch your API key automatically using the claim code
                     your interviewer gave you, instead of pasting a key.
                     The code only works from shortly before your interview
                     starts, and only once.
  --check           Verify your machine is ready. Never clones, never asks
                     for a key, never touches .env.
  --needs LIST      Comma-separated prerequisites to check (with --check).
                     One or more of: git,python,uv,tkinter
                     Default: git,python,uv
EOF
}

# ---------- argument parsing ----------
CHECK_MODE=0
NEEDS=""
REPO_URL=""
CLAIM_CODE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_MODE=1; shift ;;
    # The value is checked before shifting: with the flag last, `shift 2` fails
    # and set -e kills the script with no output at all, so a typo'd command
    # told the candidate nothing.
    --claim) CLAIM_CODE="${2:-}"
             [ -n "$CLAIM_CODE" ] || die "--claim needs your claim code after it, e.g. --claim ABCD-2345"
             shift 2 ;;
    --claim=*) CLAIM_CODE="${1#*=}"; shift ;;
    --needs) NEEDS="${2:-}"
             [ -n "$NEEDS" ] || die "--needs needs a comma-separated list after it, e.g. --needs git,uv"
             shift 2 ;;
    --needs=*) NEEDS="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "Unknown option: $1 (see: bash $0 --help)" ;;
    *) REPO_URL="$1"; shift ;;
  esac
done

KEY_NAME="${KEY_NAME:-ANTHROPIC_API_KEY}"
# Overridable so the service can be pointed at a local/staging instance while
# testing, without editing the copy candidates download.
CLAIM_URL="${CLAIM_URL:-https://onboarding-service-chi.vercel.app/api/claim}"

if [ "$CHECK_MODE" = 0 ] && [ -z "$REPO_URL" ]; then
  usage >&2
  exit 1
fi

OS="$(uname -s)"
case "$OS" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
  *) IS_WINDOWS=0 ;;
esac

# Prompts read from the terminal even if stdin is a pipe (e.g. curl ... | bash)
if [ -t 0 ]; then TTY=/dev/stdin; elif [ -r /dev/tty ]; then TTY=/dev/tty; else TTY=""; fi

confirm() {
  [ -n "$TTY" ] || return 1
  local ans
  read -r -p "$1 [y/N] " ans < "$TTY" || return 1
  case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# Best-effort Python discovery. Main flow (below) enforces that this exists
# and is 3.11+ (what the interview repo's pyproject.toml requires); --check
# reports on it as just another pass/fail item instead.
PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"

# ---------- install helpers (shared by --check and the main flow) ----------
# Each try_install_* function explains the fix, asks before doing anything,
# never runs sudo silently, and leaves the exact command on screen if it
# can't (or you don't want it to) install something for you.

git_install_cmd() {
  if   have apt-get; then echo "sudo apt-get install -y git"
  elif have dnf;     then echo "sudo dnf install -y git"
  elif [ "$OS" = "Darwin" ] && have brew; then echo "brew install git"
  elif [ "$IS_WINDOWS" = 1 ] && have winget; then echo "winget install --id Git.Git -e"
  else echo ""
  fi
}

try_install_git() {
  local cmd; cmd="$(git_install_cmd)"
  if [ -z "$cmd" ]; then
    echo "No known installer for your platform. Install git from https://git-scm.com/downloads"
    return 1
  fi
  echo "git is not installed."
  echo "Fix: $cmd"
  confirm "Install it now?" || return 1
  eval "$cmd"
  have git
}

# uv bundles its own Python builds. We verified directly that uv-managed
# Python on macOS already ships a working tkinter (no system Tk needed) -
tkinter_install_cmd() {
  if   have apt-get; then echo "sudo apt-get install -y python3-tk"
  elif have dnf;     then echo "sudo dnf install -y python3-tkinter"
  elif have pacman;  then echo "sudo pacman -S --noconfirm tk"
  elif have zypper;  then echo "sudo zypper install -y python3-tk"
  else echo ""
  fi
}

try_install_tkinter() {
  local cmd; cmd="$(tkinter_install_cmd)"
  if [ -z "$cmd" ]; then
    echo "No known installer for your platform/Python."
    echo "If you're using uv-managed Python, it already bundles a working tkinter (verified on macOS)."
    echo "Otherwise see your distro's docs for the python3-tk / tkinter package."
    return 1
  fi
  echo "tkinter is not available for $PY."
  echo "Fix: $cmd"
  confirm "Install it now?" || return 1
  eval "$cmd"
  "$PY" -c 'import tkinter' >/dev/null 2>&1
}

try_install_uv() {
  echo "uv is required but not installed."
  echo "Fix: curl -LsSf https://astral.sh/uv/install.sh | sh"
  confirm "Install it now with the official installer?" || return 1
  if [ "$IS_WINDOWS" = 1 ]; then
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex"
  elif have curl; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
  elif have wget; then
    wget -qO- https://astral.sh/uv/install.sh | sh
  else
    echo "Need curl or wget to install uv. Install uv manually: https://docs.astral.sh/uv/"
    return 1
  fi
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
  have uv
}

# ============================================================
# --check mode: verify, never clone/ask-for-a-key/touch .env
# ============================================================
CHECK_FAILED=0

report() {
  # $1=PASS|FAIL|INFO  $2=label  $3=detail (FAIL only)  $4=fix (FAIL only)
  case "$1" in
    PASS) printf '  [PASS] %s\n' "$2" ;;
    INFO) printf '  [INFO] %s\n' "$2" ;;
    FAIL)
      printf '  [FAIL] %s - %s\n' "$2" "$3"
      [ -n "${4:-}" ] && printf '         Fix: %s\n' "$4"
      CHECK_FAILED=1
      ;;
  esac
}

check_git() {
  have git || try_install_git || true
  if have git; then report PASS "git ($(git --version))"
  else report FAIL "git" "not installed" "https://git-scm.com/downloads"
  fi
}

check_python() {
  if [ -n "$PY" ] && "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
    report PASS "python ($("$PY" -V 2>&1))"
  elif [ -n "$PY" ]; then
    report FAIL "python" "found but older than 3.11" "install Python 3.11+ from https://www.python.org/downloads/"
  else
    report FAIL "python" "not installed" "install Python 3.11+ from https://www.python.org/downloads/"
  fi
}

check_uv() {
  have uv || try_install_uv || true
  if have uv; then report PASS "uv ($(uv --version))"
  else report FAIL "uv" "not installed" "curl -LsSf https://astral.sh/uv/install.sh | sh"
  fi
}

check_tkinter() {
  if [ "$OS" != "Linux" ]; then
    report INFO "tkinter check only applies to Linux, skipped on $OS"
    return
  fi
  if [ -z "$PY" ]; then
    report FAIL "tkinter" "no Python interpreter found to check it with" "install Python first"
    return
  fi
  if ! "$PY" -c 'import tkinter' >/dev/null 2>&1; then
    try_install_tkinter || true
  fi
  if "$PY" -c 'import tkinter' >/dev/null 2>&1; then
    report PASS "tkinter"
  else
    report FAIL "tkinter" "not available for $PY" "$(tkinter_install_cmd)"
  fi
}

check_network() {
  local host ok
  for host in github.com astral.sh; do
    ok=1
    if have curl; then
      curl -fsS --max-time 5 -o /dev/null "https://$host" || ok=0
    elif have wget; then
      wget -q --timeout=5 -O /dev/null "https://$host" || ok=0
    else
      ok=0
    fi
    if [ "$ok" = 1 ]; then
      report PASS "network: $host reachable"
    else
      report FAIL "network: $host" "could not reach $host" "check your internet connection, VPN, or firewall"
    fi
  done
}

check_github_auth() {
  # Informational only: the candidate may not have been invited yet.
  if have gh && gh auth status >/dev/null 2>&1; then
    report INFO "GitHub auth: signed in via gh CLI"
    return
  fi
  if have ssh && ssh -T git@github.com -o BatchMode=yes -o ConnectTimeout=5 2>&1 | grep -qi "successfully authenticated"; then
    report INFO "GitHub auth: SSH key authenticated"
    return
  fi
  if have git; then
    local helper
    helper="$(git config --get credential.helper 2>/dev/null || true)"
    if [ -n "$helper" ]; then
      report INFO "GitHub auth: a git credential helper ('$helper') is configured (not verified)"
      return
    fi
  fi
  report INFO "GitHub auth: not detected yet (fine if you haven't been invited to the repo yet)"
}

run_check() {
  local valid="git python uv tkinter"
  local needs="${NEEDS:-git python uv}"
  needs="$(echo "$needs" | tr ',' ' ')"

  local item
  for item in $needs; do
    case " $valid " in
      *" $item "*) ;;
      *) die "Unknown --needs item '$item'. Supported: git, python, uv, tkinter" ;;
    esac
  done

  echo "Checking your machine for the interview..."
  echo
  for item in $needs; do
    case "$item" in
      git)     check_git ;;
      python)  check_python ;;
      uv)      check_uv ;;
      tkinter) check_tkinter ;;
    esac
  done
  check_network
  check_github_auth

  echo
  if [ "$CHECK_FAILED" = 1 ]; then
    echo "Result: fix the items above."
    exit 1
  else
    echo "Result: ready for the interview."
    exit 0
  fi
}

[ "$CHECK_MODE" = 1 ] && run_check

# ============================================================
# Main flow: clone, install, ask for the key, write .env
# ============================================================
have git || try_install_git || die "git is not installed. Install it from https://git-scm.com/downloads and re-run."
[ -n "$PY" ] || die "Python 3 is not installed. Install Python 3.11+ from https://www.python.org/downloads/ and re-run."
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' \
  || die "Python 3.11+ is required by the interview repo."

# ---------- API key (before the clone, on purpose) ----------
# A claim code is single-use. Cloning first meant a wrong or too-early code
# left a half-built directory behind, so the retry died on "destination path
# already exists" - and with a burned code there was nothing left to retry
# with. Nothing touches the disk until the key is in hand.
API_KEY="${!KEY_NAME:-}"

# With --claim, swap the code for the key instead of asking the candidate to
# paste one. The service returns the key as the whole body on success, and a
# human-readable explanation on any failure - including "your key unlocks at
# HH:MM UTC" when setup is run before the interview window opens - so the
# wording lives server-side and this script just prints what it's told.
if [ -z "$API_KEY" ] && [ -n "$CLAIM_CODE" ]; then
  have curl || die "This needs curl to fetch your key. Install curl, or ask your interviewer for the key to paste instead."
  echo
  echo "Fetching your API key with claim code $CLAIM_CODE ..."

  # The key is kept in a shell variable and never written to a temp file -
  # it only ever lands on disk in .env, where it's meant to be.
  #
  # No -f: it makes curl discard the response body on a 4xx, which is exactly
  # the body carrying the explanation the candidate needs to read. The status
  # is appended as a trailing line instead, and split back off below.
  # --get/--data-urlencode so an odd character in the code can't break the URL.
  CLAIM_RESPONSE="$(curl -sS -w $'\n%{http_code}' --max-time 30 \
    --get --data-urlencode "code=${CLAIM_CODE}" \
    "$CLAIM_URL" 2>/dev/null || true)"

  CLAIM_STATUS="${CLAIM_RESPONSE##*$'\n'}"
  CLAIM_BODY="${CLAIM_RESPONSE%$'\n'*}"

  case "$CLAIM_STATUS" in
    200)
      # Don't trust a 200 to mean "this is a key". A captive portal or an
      # intercepting corporate proxy will happily return HTML with a 200, and
      # writing that into .env fails much later as a confusing auth error.
      CLAIM_BODY="$(printf '%s' "$CLAIM_BODY" | tr -d '[:space:]')"
      case "$CLAIM_BODY" in
        sk-ant-*) ;;
        *)
          die "The key service replied, but not with a key. You may be behind a proxy or captive portal that intercepted the request. Check your network and re-run, or ask your interviewer for the key to paste instead."
          ;;
      esac
      API_KEY="$CLAIM_BODY"
      echo "Key received automatically - nothing to paste."
      ;;
    000|"")
      die "Couldn't reach the key service. Check your internet connection and re-run, or ask your interviewer for the key to paste instead."
      ;;
    *)
      # 409 = too early (includes the unlock time), 410 = used or finished,
      # 404 = unrecognised. The body already says which, in words written for
      # the candidate, so print it as-is rather than second-guessing it.
      printf '\n%s\n' "$CLAIM_BODY" >&2
      exit 1
      ;;
  esac
fi

if [ -z "$API_KEY" ]; then
  [ -n "$TTY" ] || die "No terminal available to ask for the key. Re-run with $KEY_NAME=... set."
  echo
  echo "Paste your API key and press Enter (nothing will appear as you paste - that's normal)."
  read -r -s -p "$KEY_NAME: " API_KEY < "$TTY"
  echo
fi
# Strip stray whitespace/newlines from pasting
API_KEY="$(printf '%s' "$API_KEY" | tr -d '[:space:]')"
[ -n "$API_KEY" ] || die "No key entered. Re-run the script and paste the key when asked."
echo "Key received (${#API_KEY} characters)."

# ---------- clone ----------
REPO_DIR="$(basename "${REPO_URL%/}")"
REPO_DIR="${REPO_DIR%.git}"

# Reuse an existing checkout rather than failing. A candidate who re-runs this
# - after a failed claim, a dropped connection, or just twice - would otherwise
# hit "destination path already exists" and be stuck. Never deletes it: by the
# second run it may hold their work.
if [ -d "$REPO_DIR/.git" ]; then
  echo "Found an existing $REPO_DIR - reusing it instead of cloning again."
  cd "$REPO_DIR"
elif [ -e "$REPO_DIR" ]; then
  die "'$REPO_DIR' already exists here but isn't a git clone. Move or rename it, then re-run."
else
  git clone "$REPO_URL" "$REPO_DIR"
  cd "$REPO_DIR"
fi

# ---------- .env (before installing, on purpose) ----------
# A claim code is single-use, so it's spent by the time we get here. If the
# dependency install below failed first, the key would be gone with nothing
# written, and the retry couldn't fetch it again - the candidate would need
# someone to read it to them. Getting it onto disk first makes a failed
# install a retryable annoyance instead.
if [ -f .env.example ] && [ ! -f .env ]; then
  cp .env.example .env
fi
touch .env

# The key goes to Python through the environment, never the command line
SETUP_KEY_NAME="$KEY_NAME" SETUP_KEY_VALUE="$API_KEY" "$PY" - <<'PY'
import os, re

name, value = os.environ["SETUP_KEY_NAME"], os.environ["SETUP_KEY_VALUE"]
pat = re.compile(r"\s*(?:export\s+)?" + re.escape(name) + r"\s*=")

with open(".env") as f:
    lines = [l for l in f.read().splitlines() if not pat.match(l)]
lines.append(f"{name}={value}")

with open(".env", "w") as f:
    f.write("\n".join(lines) + "\n")
PY
chmod 600 .env 2>/dev/null || true

echo "Setup complete. Project is in $(pwd)"

# ---------- repo-specific prerequisites ----------
if [ -f pyproject.toml ]; then
  have uv || try_install_uv || die "Please install uv (https://docs.astral.sh/uv/) and re-run."
fi

if [ "$OS" = "Linux" ] && grep -rIlq --include='*.py' -E '^\s*(import tkinter|from tkinter|import Tkinter)' . 2>/dev/null; then
  if ! "$PY" -c 'import tkinter' >/dev/null 2>&1; then
    echo
    echo "This repo uses tkinter for a manual-testing tool, but it isn't available for $PY."
    try_install_tkinter || echo "Continuing without it - install later if you need that tool."
    echo
  fi
fi

# ---------- install dependencies ----------
if [ -f pyproject.toml ]; then
  uv sync
elif [ -f requirements.txt ]; then
  "$PY" -m pip install -r requirements.txt
fi

