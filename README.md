# interview-setup

Machine setup for a code interview. This repo has no secrets and no exercise
content — it is the source of truth for one script, `setup.sh`, which ships
inside the interview project itself.

**You can open `setup.sh` in any text editor and read every line before you
run it.** The script needs no git, and clones nothing: the interview project
is already in place for you, and the script sits in it.

Most of what's in it is installing prerequisites for you across macOS and the
main Linux package managers (Homebrew, apt, dnf, pacman, zypper), so that one
command works whatever you're on. The setup itself — install dependencies,
fetch the key, write `.env` — is about a hundred lines.

## Prerequisites

- **Python 3** — any version, just to run the script itself. The interview
  project needs 3.11+, and `uv` fetches a suitable interpreter on its own if
  your system Python is older
- **uv** ([docs.astral.sh/uv](https://docs.astral.sh/uv/)) — the script offers
  to install it for you
- An internet connection (to reach `astral.sh` and the key service)

You don't need any of these installed beforehand — the script offers to
install what's missing, and tells you the exact command if you'd rather do it
yourself. You do **not** need git.

### Checking it before you run it

You're being asked to run a script from a company you don't work for yet.
`setup.sh` is right there in your project folder — open it in the editor and
read it. It is about a hundred lines of actual work, and every step says why
it is in that order.

## Running it

Your interview environment opens with the project already there, `setup.sh`
included. One command. Substitute the **claim code** you were given:

```bash
bash setup.sh --claim YOUR-CODE
```

That installs the project's dependencies, fetches your API key and writes it to
`.env`. Nothing to paste, and you're ready to use it.

It sets up the folder the script itself is in, so it works whatever directory
you run it from. To point it somewhere else, pass that folder:
`bash setup.sh --claim YOUR-CODE path/to/project`.

**The claim code works from a few minutes before your interview starts, and
only once.** Run it earlier and it tells you what time to try again — that's
expected, not a problem with your setup.

If you weren't given a claim code, drop the `--claim YOUR-CODE` part and the
script will ask you to paste the API key shared with you on the call instead.

## Troubleshooting

- **"this doesn't look like the interview project"** — you're one folder out.
  The script prints the folder it's in and, if it can see the project next to
  you, the exact command to run instead.
- **"uv is required but not installed"** — say yes to the prompt, or install
  it yourself from [docs.astral.sh/uv](https://docs.astral.sh/uv/).
- **A `sudo` install fails, or you don't have sudo rights** — the script
  prints the exact command it would have run. Ask whoever manages your
  machine to run that command, then re-run the setup.
- **tkinter warning on Linux** — only some interviews' manual-testing tools
  need this; the script offers to install the right package for your distro.
- **Can't reach `astral.sh`** — usually a corporate VPN, proxy, or firewall.
  Try from a different network, or ask your network admin to allow that host.
- **Nothing happens when pasting the key** — that's expected, input is
  hidden on purpose. Paste once, then press Enter.

If something goes wrong on the call, tell your interviewer — don't spend call
time debugging your machine.
