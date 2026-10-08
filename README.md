# interview-setup

Machine setup for a code interview. This repo has no secrets and no exercise
content — it only contains two small, readable scripts that get your laptop
ready before the call.

**You can open `setup.sh` / `setup.ps1` in any text editor and read every
line before you run them.** Neither script needs git to download — you only
need git for the clone step that comes after.

## Prerequisites

- **git**, the scripts can offer to install it for you if it's missing
- **Python 3.8+**
- **uv** ([docs.astral.sh/uv](https://docs.astral.sh/uv/)) — only if the
  interview repo needs it; the script offers to install it for you
- An internet connection (to clone the interview repo and reach
  `github.com` and `astral.sh`)

You don't need any of these installed before you run `--check` below — it
tells you exactly what's missing and how to fix it.

## 1. Check your machine (do this a day or two before the interview)

This step never clones anything, never asks for a key, and never writes any
files. It only looks at what's on your machine.

**macOS / Linux**

```bash
curl -LsSf https://raw.githubusercontent.com/Tesseract-Energy/interview-setup/1f4211f/setup.sh -o setup.sh
bash setup.sh --check
```

**Windows (PowerShell)**

```powershell
irm https://raw.githubusercontent.com/Tesseract-Energy/interview-setup/1f4211f/setup.ps1 -OutFile setup.ps1
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Check
```

> We download the script first and run it as a second step on purpose,
> rather than piping it straight into your shell, so you have the chance to
> open and read it first. The link above points at one fixed, reviewable
> version of the script (not a moving branch).

If it prints `ready for the interview`, you're done. If it prints
`fix the items above`, follow the fix listed next to each failed item and
run `--check` again.

## 2. On the day, once you've accepted the repo invite

Run the same script again, this time with the interview repo's URL (you'll
be given this separately):

**macOS / Linux**

```bash
bash setup.sh <repo-url>
```

**Windows (PowerShell)**

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1 <repo-url>
```

This clones the repo, installs its dependencies, and asks you to paste the
API key shared with you on the call. Afterwards, it will be setup and ready to use.

## Troubleshooting

- **"git is not installed"** — the script offers to install it for you on
  macOS (Homebrew) and Linux (apt/dnf/pacman/zypper), or points you to
  [git-scm.com/downloads](https://git-scm.com/downloads).
- **"uv is required but not installed"** — same idea; say yes to the prompt,
  or install it yourself from [docs.astral.sh/uv](https://docs.astral.sh/uv/).
- **A `sudo` install fails, or you don't have sudo rights** — the script
  prints the exact command it would have run. Ask whoever manages your
  machine to run that command, then re-run `--check`.
- **tkinter warning on Linux** — only some interviews' manual-testing tools
  need this; the script offers to install the right package for your distro.
- **PowerShell won't run the script** — Windows blocks unsigned scripts by
  default. Use `powershell -ExecutionPolicy Bypass -File .\setup.ps1 ...`
  exactly as shown above; this doesn't change any system setting, it only
  applies to that one run.
- **Network check fails for `github.com` or `astral.sh`** — usually a
  corporate VPN, proxy, or firewall. Try from a different network, or ask
  your network admin to allow those two hosts.
- **Nothing happens when pasting the key** — that's expected, input is
  hidden on purpose. Paste once, then press Enter.

If `--check` says you're ready but something still goes wrong on the call,
tell your interviewer — don't spend call time debugging your machine.
