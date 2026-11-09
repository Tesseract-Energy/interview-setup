#!/usr/bin/env bash
# Usage: bash setup.sh --claim ABCD-2345 [project-dir]
#
# Two jobs, in this order: install the project's dependencies, then exchange
# your claim code for an API key and write it to .env.
#
# It clones nothing and does not need git. This script ships inside the
# interview project, so by default it sets up the folder it is sitting in - run
# it from anywhere and it still finds the right one. Pass a directory to
# override that.
#
# Without --claim it asks you to paste the key instead (input is hidden).
# Non-interactive alternative: ANTHROPIC_API_KEY=... bash setup.sh
# Set KEY_NAME to use a different env var name (default: ANTHROPIC_API_KEY).
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage:
  bash setup.sh --claim CODE [project-dir]

  --claim CODE      Fetch your API key automatically using the claim code
                     your interviewer gave you, instead of pasting a key.
                     The code only works from shortly before your interview
                     starts, and only once.
  [project-dir]     The interview project folder. Defaults to the folder this
                     script is in, which is the project itself.
EOF
}

# ---------- arguments ----------
PROJECT_DIR=""
CLAIM_CODE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --claim) CLAIM_CODE="${2:-}"
             [ -n "$CLAIM_CODE" ] || die "--claim needs your claim code after it, e.g. --claim ABCD-2345"
             # The claim runs after the install, so a code that was never going
             # to work costs a few minutes before the service says so. This
             # catches the pastes that are not a code at all - a sentence, a
             # URL, a truncated fragment. Deliberately checks length only, not
             # the service's alphabet: duplicating that here would start
             # rejecting valid codes the day it changes.
             CLAIM_BARE="$(printf '%s' "$CLAIM_CODE" | tr -cd '[:alnum:]' | tr '[:lower:]' '[:upper:]')"
             case "${#CLAIM_BARE}" in
               [4-9]|1[0-6]) ;;
               *) die "'$CLAIM_CODE' doesn't look like a claim code. It's the 8-character code from your setup email, e.g. ABCD-2345." ;;
             esac
             shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "Unknown option: $1 (see: bash $0 --help)" ;;
    # A URL here is an older invocation, from before the project came
    # pre-placed. Caught by shape rather than ignored: treating it as a
    # directory would fail several lines later as "no pyproject.toml", which
    # says nothing about the real problem.
    *://*|git@*)
       die "This script no longer clones anything - the interview project is already in your folder. Re-run it as: bash setup.sh --claim YOUR-CODE" ;;
    *) PROJECT_DIR="$1"; shift ;;
  esac
done

KEY_NAME="${KEY_NAME:-ANTHROPIC_API_KEY}"
# Overridable so tests can point at a local instance.
CLAIM_URL="${CLAIM_URL:-https://onboarding-service-chi.vercel.app/api/claim}"

# Where a claimed key is remembered, named after the code that bought it.
# Empty when there is nowhere sensible to put it (no HOME), which only costs
# the re-run shortcut - the claim itself still works.
CLAIM_CACHE=""
if [ -n "${CLAIM_BARE:-}" ]; then
  CLAIM_CACHE_DIR="${XDG_CACHE_HOME:-${HOME:-}/.cache}"
  case "$CLAIM_CACHE_DIR" in
    /*) CLAIM_CACHE="$CLAIM_CACHE_DIR/fuse-interview/$CLAIM_BARE" ;;
  esac
fi

# Prompts read from the terminal even if stdin is a pipe (e.g. curl ... | bash)
if [ -t 0 ]; then TTY=/dev/stdin; elif [ -r /dev/tty ]; then TTY=/dev/tty; else TTY=""; fi

# Used only for one small .env edit (os and re, fine on 3.6+). The project's
# own >=3.11 floor belongs to uv, which resolves an interpreter from
# requires-python and downloads a suitable one when none is installed - so
# testing the *system* interpreter here could only reject candidates uv would
# have served.
PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
[ -n "$PY" ] || die "Python 3 is not installed, and this needs it to write .env. Tell your interviewer."

# ---------- find the project ----------
# The script ships in the project root, so its own directory is the project.
# Taking that over the working directory means `bash /path/to/setup.sh` works
# from anywhere, and the candidate cannot end up installing into the wrong
# folder by having cd'd somewhere first.
if [ -z "$PROJECT_DIR" ]; then
  # Parameter expansion and builtins, not `dirname`: this runs before any
  # prerequisite check, and an environment missing dirname would otherwise
  # skip project detection silently rather than say anything.
  case "$0" in
    */*) SCRIPT_DIR="${0%/*}" ;;
    *)   SCRIPT_DIR="." ;;
  esac
  SCRIPT_DIR="$(cd "$SCRIPT_DIR" 2>/dev/null && pwd)" || SCRIPT_DIR=""
  # Only when it is actually the project. A copy of this script somewhere else
  # - downloaded to a home directory, say - must still fall back to the
  # working directory rather than insist on its own folder.
  [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/pyproject.toml" ] && PROJECT_DIR="$SCRIPT_DIR"
fi

if [ -n "$PROJECT_DIR" ]; then
  [ -d "$PROJECT_DIR" ] || die "'$PROJECT_DIR' isn't a directory. Pass the interview project folder, or run this from inside it with no argument."
  cd "$PROJECT_DIR"
fi

# Checked before anything is installed, because every step below assumes it.
# The common mistake is running from the parent of the project rather than the
# project itself, so say that rather than only naming what is missing.
if [ ! -f pyproject.toml ]; then
  echo "No pyproject.toml in $(pwd), so this doesn't look like the interview project." >&2
  for candidate in */pyproject.toml; do
    [ -f "$candidate" ] || continue
    echo "Did you mean: bash setup.sh --claim YOUR-CODE ${candidate%/pyproject.toml}" >&2
    break
  done
  die "Run this from inside the interview project folder, or pass it as an argument."
fi

# ---------- 1. dependencies ----------
# uv is installed without asking. On a personal laptop that would be rude, but
# this runs in a disposable interview container, and a [y/N] prompt there is
# friction at best - and hangs the setup at worst, when there is no terminal
# to answer it from.
if ! have uv; then
  have curl || die "This needs curl to install uv. Tell your interviewer."
  echo "Installing uv (https://docs.astral.sh/uv/) ..."
  # Guarded rather than left to `set -e`: with `pipefail` a failed download
  # aborts the script with curl's own exit code and no message at all, which
  # tells the candidate nothing about what to do next.
  if ! curl -LsSf https://astral.sh/uv/install.sh | sh; then
    die "Couldn't download uv from astral.sh - usually a network or proxy problem. Check your connection and re-run, or tell your interviewer."
  fi
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
  have uv || die "uv installed but isn't on PATH. Open a new terminal and re-run."
fi

# --frozen, not a plain sync, when there is a lockfile: install exactly what
# uv.lock pins and never re-resolve. Without it `uv sync` silently resolves
# the latest versions allowed by pyproject.toml, so the interview environment
# differs from the one the exercise was tested against - and a dependency that
# moved under it fails as an import error mid-interview, with nothing on
# screen connecting that to the install.
if [ -f uv.lock ]; then
  uv sync --frozen
else
  # Not fatal: a candidate who can still install has a working interview. But
  # it is said plainly, because a missing lockfile is how the environment
  # drifts, and the interviewer needs to hear about it rather than debug an
  # import error later.
  echo
  echo "WARNING: no uv.lock in $(pwd), so dependency versions are being resolved" >&2
  echo "fresh rather than pinned. This is not the tested environment - tell your" >&2
  echo "interviewer, and mention it if anything fails to import." >&2
  echo
  uv sync
fi

# ---------- 1b. litellm's undeclared MCP dependency ----------
# litellm's completion() imports its MCP handler whenever the caller passes
# tools, and this project always passes tools. From some version after 1.104.2
# that path imports `mcp`, which litellm declares only under its [mcp] extra -
# so an install can satisfy every declared dependency and still be a litellm
# that cannot complete a single call. It surfaces on the candidate's first
# message as a ModuleNotFoundError deep inside litellm, with nothing on screen
# connecting it to setup.
#
# Checked rather than installed blindly: on a correctly pinned install the
# import already works and there is nothing to add. The probe is the exact
# module that chain fails on - importing `mcp` directly would be wrong, since
# the pinned litellm genuinely does not need it.
#
# After `uv sync`, never before: sync prunes anything absent from the lock,
# so an install placed above it is silently undone.
# Two probes, not one. The second alone would fire for any project without
# litellm at all, and "repair" it by adding a dependency it never wanted.
if uv run --no-sync python -c 'import litellm' >/dev/null 2>&1 &&
   ! uv run --no-sync python -c 'import litellm.responses.mcp.litellm_proxy_mcp_handler' >/dev/null 2>&1; then
  echo
  echo "Adding litellm's MCP dependency, which litellm does not declare ..."
  # `uv add` over `uv pip install` so it survives a later `uv sync` - a
  # candidate who runs one by hand should not silently lose this again.
  if ! uv add 'mcp>=2.3.0,<3'; then
    die "Couldn't install the 'mcp' package, which this version of litellm needs to make any model call. Check your network and re-run, or tell your interviewer."
  fi
  uv run --no-sync python -c 'import litellm.responses.mcp.litellm_proxy_mcp_handler' >/dev/null 2>&1 \
    || die "Installed 'mcp' but litellm still cannot load its MCP handler. Tell your interviewer - this needs a dependency fix, not a re-run."
fi

# ---------- 2. the API key ----------
# Last, on purpose. The claim code is single-use, so everything that can fail
# - the dependency install above all - happens before it is spent. The only
# step left after the claim is writing .env, a local file write that
# effectively cannot fail, so a failed setup never costs a code that cannot be
# used again.

API_KEY="${!KEY_NAME:-}"

# A key this code already bought beats claiming again: the code is single-use,
# so a second claim returns 410 and throws away a key that is already in hand.
#
# Remembered under the code rather than in the project's .env, for two reasons.
# A fixed location is found again when the candidate re-runs from a different
# folder, where .env is not. And keying it by the code means a later interview
# - a new code - misses and claims its own key, instead of silently reusing the
# previous interview's, which is revoked minutes after that interview ended and
# would fail as an unexplained 401.
if [ -z "$API_KEY" ] && [ -n "$CLAIM_CACHE" ] && [ -f "$CLAIM_CACHE" ]; then
  SAVED_KEY="$(tr -d '[:space:]' < "$CLAIM_CACHE" 2>/dev/null || true)"
  # Only something that looks like a key. A truncated or half-written value
  # would otherwise be reused on every run, turning a recoverable setup
  # failure into an auth error with no way back.
  case "$SAVED_KEY" in
    sk-ant-*)
      API_KEY="$SAVED_KEY"
      echo
      echo "You already claimed a key with this code - reusing it, no need to claim again."
      ;;
  esac
fi

# --claim swaps the code for the key: the service returns the key as the whole
# body, or a message meant for you (e.g. "your key unlocks at HH:MM") on refusal.
if [ -z "$API_KEY" ] && [ -n "$CLAIM_CODE" ]; then
  have curl || die "This needs curl to fetch your key. Ask your interviewer for the key to paste instead."
  echo
  echo "Fetching your API key with claim code $CLAIM_CODE ..."

  # No -f (it discards the 4xx body, which carries the explanation); status is
  # appended as a trailing line. The code travels in a header, not the query
  # string: it is a credential, and a query string is written verbatim into
  # access logs and error reports along the way.
  CLAIM_RESPONSE="$(curl -sS -w $'\n%{http_code}' --max-time 30 \
    -H "X-Claim-Code: ${CLAIM_CODE}" \
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
      # Saved before the .env write, not after: the code is spent from here
      # on, so this is what makes a re-run free no matter what happens next.
      # Best-effort - a home directory we cannot write to must not fail a
      # setup that has already succeeded.
      if [ -n "$CLAIM_CACHE" ] && mkdir -p "${CLAIM_CACHE%/*}" 2>/dev/null; then
        chmod 700 "${CLAIM_CACHE%/*}" 2>/dev/null || true
        ( umask 077; printf '%s\n' "$API_KEY" > "$CLAIM_CACHE" ) 2>/dev/null || true
      fi
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

# The paste path stays as the way out when the key service is unreachable
# mid-interview. Without it an outage ends the interview; with it the
# interviewer can read the key out and the candidate carries on.
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
# write that fails (full disk, read-only folder) would otherwise leave the
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
