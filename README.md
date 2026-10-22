# interview-setup

Machine setup for a code interview. This repo has no secrets and no exercise
content — just two scripts that get your laptop ready before the call.

**You can open `setup.sh` / `setup.ps1` in any text editor and read every
line before you run them.** Neither script needs git to download — you only
need git for the clone step that comes after.

Most of what's in them is installing prerequisites for you across macOS and
the main Linux package managers (Homebrew, apt, dnf, pacman, zypper), so that
one command works whatever you're on. The setup itself — clone, fetch the key,
write `.env`, install dependencies — is about a hundred lines.

## Prerequisites

- **git**, the scripts can offer to install it for you if it's missing
- **Python 3** — any version, just to run the script itself. The interview
  repo needs 3.11+, and `uv` fetches a suitable interpreter on its own if
  your system Python is older
- **uv** ([docs.astral.sh/uv](https://docs.astral.sh/uv/)) — only if the
  interview repo needs it; the script offers to install it for you
- An internet connection (to clone the interview repo and reach
  `github.com` and `astral.sh`)

You don't need any of these installed beforehand — the script offers to
install what's missing, and tells you the exact command if you'd rather do it
yourself.

### Checking it before you run it

You're being asked to run a script from a company you don't work for yet. All
of these are reasonable, and none of them need our help:

**Read it in your browser first** — no download needed. These are permalinks
to one fixed commit, so what you read is exactly what the command below runs:
[setup.sh](https://github.com/Tesseract-Energy/interview-setup/blob/9aac773/setup.sh)
· [setup.ps1](https://github.com/Tesseract-Energy/interview-setup/blob/9aac773/setup.ps1)

**Download, read, then run** — drop the `&& bash ...` half of the command,
open the file in any editor, and run it yourself when you're satisfied.

**Check what you downloaded is what we published.** If these don't match, do
not run it — tell your interviewer. (A corporate proxy that rewrites downloads
is a more likely cause than anything sinister, but either way it's worth
knowing.)

```bash
shasum -a 256 setup.sh     # expect 1294313e68cbc0d763443c0edc3176691da56b671451fd09cbabb05b065e8c09
shasum -a 256 setup.ps1    # expect d3d5187767ded235c7afe7305e1c502dc2c5c43632cb94e1843be065a05d3d15
```

On Windows PowerShell: `Get-FileHash setup.ps1 -Algorithm SHA256`

## Running it, once you've accepted the repo invite

One command. Substitute the **claim code** and the **interview repo URL** you
were given:

**macOS / Linux**

```bash
curl -LsSf https://raw.githubusercontent.com/Tesseract-Energy/interview-setup/fb8bc1b/setup.sh -o setup.sh && bash setup.sh --claim YOUR-CODE <repo-url>
```

**Windows (PowerShell)**

```powershell
irm https://raw.githubusercontent.com/Tesseract-Energy/interview-setup/fb8bc1b/setup.ps1 -OutFile setup.ps1; powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Claim YOUR-CODE <repo-url>
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
  machine to run that command, then re-run the setup.
- **tkinter warning on Linux** — only some interviews' manual-testing tools
  need this; the script offers to install the right package for your distro.
- **PowerShell won't run the script** — Windows blocks unsigned scripts by
  default. Use `powershell -ExecutionPolicy Bypass -File .\setup.ps1 ...`
  exactly as shown above; this doesn't change any system setting, it only
  applies to that one run.
- **Can't reach `github.com` or `astral.sh`** — usually a corporate VPN,
  proxy, or firewall. Try from a different network, or ask your network admin
  to allow those two hosts.
- **Nothing happens when pasting the key** — that's expected, input is
  hidden on purpose. Paste once, then press Enter.

If something goes wrong on the call, tell your interviewer — don't spend call
time debugging your machine.
