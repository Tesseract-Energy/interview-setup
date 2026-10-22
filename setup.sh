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
set -euo pipefail

# ---------- helpers (needed before argument parsing can use them) ----------
die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage:
  bash setup.sh <repo-url>

  <repo-url>        Clone this repo and set it up for the interview.
  --claim CODE      Fetch your API key automatically using the claim code
                     your interviewer gave you, instead of pasting a key.
                     The code only works from shortly before your interview
                     starts, and only once.
EOF
}

# ---------- argument parsing ----------
REPO_URL=""
CLAIM_CODE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --claim) CLAIM_CODE="${2:-}"
             [ -n "$CLAIM_CODE" ] || die "--claim needs your claim code after it, e.g. --claim ABCD-2345"
             # The claim now runs after the clone and the install, so a code
             # that was never going to work costs a few minutes before the
             # service says so. This catches the pastes that are not a code at
             # all - a sentence, a URL, a truncated fragment. Deliberately
             # checks length only, not the service's alphabet: duplicating
             # that here would start rejecting valid codes the day it changes.
             CLAIM_BARE="$(printf '%s' "$CLAIM_CODE" | tr -cd '[:alnum:]')"
             case "${#CLAIM_BARE}" in
               [4-9]|1[0-6]) ;;
               *) die "'$CLAIM_CODE' doesn't look like a claim code. It's the 8-character code from your setup email, e.g. ABCD-2345." ;;
             esac
             shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "Unknown option: $1 (see: bash $0 --help)" ;;
    *) REPO_URL="$1"; shift ;;
  esac
done

KEY_NAME="${KEY_NAME:-ANTHROPIC_API_KEY}"
# Overridable so tests can point at a local instance.
CLAIM_URL="${CLAIM_URL:-https://onboarding-service-chi.vercel.app/api/claim}"

[ -n "$REPO_URL" ] || { usage >&2; exit 1; }

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
# and is 3.11+, which the interview repo's pyproject.toml requires.
PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"

# ---------- prerequisite installers ----------
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
# Main flow: clone, install, ask for the key, write .env
# ============================================================
have git || try_install_git || die "git is not installed. Install it from https://git-scm.com/downloads and re-run."
# Only that *a* Python 3 exists. This script uses it for one small .env edit
# (os and re, fine on 3.6+). The interview repo's own >=3.11 floor belongs to
# uv, which resolves an interpreter from requires-python and downloads a
# suitable one when none is installed - so testing the *system* interpreter
# here can only reject candidates uv would have served. 273a545 added that
# gate so --check could warn days early; a4e32bb removed --check.
[ -n "$PY" ] || die "Python 3 is not installed. Install it from https://www.python.org/downloads/ and re-run."

# ---------- clone ----------
REPO_DIR="$(basename "${REPO_URL%/}")"
REPO_DIR="${REPO_DIR%.git}"

# Reuse an existing checkout so re-running works. Never deletes it - by the
# second run it may hold your work.
if [ -d "$REPO_DIR/.git" ]; then
  echo "Found an existing $REPO_DIR - reusing it instead of cloning again."
  cd "$REPO_DIR"
elif [ -e "$REPO_DIR" ]; then
  die "'$REPO_DIR' already exists here but isn't a git clone. Move or rename it, then re-run."
else
  git clone "$REPO_URL" "$REPO_DIR"
  cd "$REPO_DIR"
fi

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
fi

# ---------- API key ----------
# Last, on purpose. The claim code is single-use, so everything that can fail
# - the clone, and the dependency install above all - happens before it is
# spent. The only step left after the claim is writing .env, a local file
# write that effectively cannot fail, so a failed setup never costs a code
# that cannot be used again.

API_KEY="${!KEY_NAME:-}"

# A key already on disk beats claiming again. The code is single-use, so a
# second claim returns 410 and throws away a key that is already saved. Guards
# the re-run of a first attempt that got as far as writing the key.
if [ -z "$API_KEY" ] && [ -f ".env" ]; then
  # Same pattern as the writer further down, so the two cannot disagree about
  # which line holds the key.
  SAVED_KEY="$(SETUP_KEY_NAME="$KEY_NAME" "$PY" - ".env" <<'PY' || true
import os, re, sys

name = os.environ["SETUP_KEY_NAME"]
pat = re.compile(r"\s*(?:export\s+)?" + re.escape(name) + r"\s*=(.*)")

found = ""
with open(sys.argv[1]) as f:
    for line in f:
        m = pat.match(line)
        if m:
            found = m.group(1).strip()
print(found)
PY
)"
  # Only something that looks like a key. A placeholder or a half-written
  # value would otherwise be reused on every run, turning a recoverable setup
  # failure into an auth error with no way back.
  case "$SAVED_KEY" in
    sk-ant-*)
      API_KEY="$SAVED_KEY"
      echo
      echo "Found your key already saved in .env - reusing it instead of claiming again."
      ;;
  esac
fi

# --claim swaps the code for the key: the service returns the key as the whole
# body, or a message meant for you (e.g. "your key unlocks at HH:MM") on refusal.
if [ -z "$API_KEY" ] && [ -n "$CLAIM_CODE" ]; then
  have curl || die "This needs curl to fetch your key. Install curl, or ask your interviewer for the key to paste instead."
  echo
  echo "Fetching your API key with claim code $CLAIM_CODE ..."

  # No -f (it discards the 4xx body, which carries the explanation); status is
  # appended as a trailing line. --data-urlencode so odd characters are safe.
  CLAIM_RESPONSE="$(curl -sS -w $'\n%{http_code}' --max-time 30 \
    --get --data-urlencode "code=${CLAIM_CODE}" \
    "$CLAIM_URL" 2>/dev/null || true)"

  CLAIM_STATUS="${CLAIM_RESPONSE##*$'\n'}"
  CLAIM_BODY="${CLAIM_RESPONSE%$'\n'*}"

  case "$CLAIM_STATUS" in
    200)
      # Stripped here, not just with the other key sources below, because the
      # check on the next line needs the bare value. A 200 isn't proof it's a
      # key: a captive portal or proxy can return HTML with one, which would
      # fail much later as a confusing auth error.
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

# ---------- .env ----------
# The last step, and the only one after the claim. Nothing that can fail may
# be added below this point: by here the code is spent.
if [ -f .env.example ] && [ ! -f .env ]; then
  cp .env.example .env
elif [ ! -f .env ]; then
  touch .env
fi

# The key goes to Python through the environment, never the command line.
#
# Printed on failure, and only on failure: the code is spent by now, so a
# write that fails (full disk, read-only checkout) would otherwise leave the
# candidate with a used code and no key at all - the one remaining way to end
# up stuck. Putting it on screen is worse than .env and far better than gone.
if ! SETUP_KEY_NAME="$KEY_NAME" SETUP_KEY_VALUE="$API_KEY" "$PY" - <<'PY'
import os, re

name, value = os.environ["SETUP_KEY_NAME"], os.environ["SETUP_KEY_VALUE"]
pat = re.compile(r"\s*(?:export\s+)?" + re.escape(name) + r"\s*=")

with open(".env") as f:
    lines = [l for l in f.read().splitlines() if not pat.match(l)]
lines.append(f"{name}={value}")

with open(".env", "w") as f:
    f.write("\n".join(lines) + "\n")
PY
then
  echo >&2
  echo "ERROR: couldn't write the key to $(pwd)/.env" >&2
  echo "Your claim code is already used, so here is the key itself - save it as" >&2
  echo "$KEY_NAME in .env yourself, or tell your interviewer the write failed." >&2
  echo >&2
  echo "$API_KEY" >&2
  exit 1
fi
chmod 600 .env 2>/dev/null || true

echo "Setup complete. Project is in $(pwd)"
