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
curl -LsSf https://raw.githubusercontent.com/Tesseract-Energy/interview-setup/9b61d05/setup.sh -o setup.sh && bash setup.sh --check
```

**Windows (PowerShell)**

```powershell
irm https://raw.githubusercontent.com/Tesseract-Energy/interview-setup/9b61d05/setup.ps1 -OutFile setup.ps1; powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Check
```

> The script is saved to a file and run from there, rather than piped
> straight into your shell, so it's sitting next to you afterwards if you
> want to read what it did — and the link points at one fixed, reviewable
> version (not a moving branch). To read it *before* running anything, drop
> the `&& bash ...` part, open `setup.sh`, then run it yourself.

If it prints `ready for the interview`, you're done. If it prints
`fix the items above`, follow the fix listed next to each failed item and
run `--check` again.

## 2. On the day, once you've accepted the repo invite

One command. Substitute the **claim code** and the **interview repo URL** you
were given:

**macOS / Linux**

```bash
curl -LsSf https://raw.githubusercontent.com/Tesseract-Energy/interview-setup/9b61d05/setup.sh -o setup.sh && bash setup.sh --claim YOUR-CODE <repo-url>
```

**Windows (PowerShell)**

```powershell
irm https://raw.githubusercontent.com/Tesseract-Energy/interview-setup/9b61d05/setup.ps1 -OutFile setup.ps1; powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Claim YOUR-CODE <repo-url>
```

That clones the repo, installs its dependencies, fetches your API key and
writes it to `.env`. Nothing to paste, and you're ready to use it.

It re-downloads the script so this works whether or not you still have the
copy from step 1.

**The claim code works from a few minutes before your interview starts, and
only once.** Run it earlier and it tells you what time to try again — that's
expected, not a problem with your setup.

If you weren't given a claim code, drop the `--claim YOUR-CODE` part and the
script will ask you to paste the API key shared with you on the call instead.

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
