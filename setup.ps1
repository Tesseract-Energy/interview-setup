# Usage (PowerShell):
#   powershell -ExecutionPolicy Bypass -File .\setup.ps1 <repo-url>
#   powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Check [-Needs git,uv,node]
#
# Windows counterpart of setup.sh: clones the repo, checks/installs prerequisites,
# installs dependencies, then asks you to paste the API key (input is hidden)
# and writes it to .env.
#
# Non-interactive alternative: set $env:ANTHROPIC_API_KEY before running.
# Set $env:KEY_NAME to use a different env var name (default: ANTHROPIC_API_KEY).
#
# -Check is a dry run: never clones, never asks for a key, never touches .env.
# -Needs tailors which prerequisites -Check verifies (default: git,python,uv).
param(
    [Parameter(Position = 0)][string]$RepoUrl,
    [switch]$Check,
    [string]$Needs
)

$ErrorActionPreference = 'Stop'

function Have($name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Check-Exit($what) { if ($LASTEXITCODE -ne 0) { Fail "$what failed (exit code $LASTEXITCODE)." } }

function Confirm($prompt) {
    if ([Console]::IsInputRedirected) { return $false }
    $ans = Read-Host "$prompt [y/N]"
    return ($ans -match '^[Yy]')
}

$keyName = if ($env:KEY_NAME) { $env:KEY_NAME } else { 'ANTHROPIC_API_KEY' }

if (-not $Check -and [string]::IsNullOrWhiteSpace($RepoUrl)) {
    Write-Host "Usage:"
    Write-Host "  .\setup.ps1 <repo-url>"
    Write-Host "  .\setup.ps1 -Check [-Needs git,uv,node]"
    exit 1
}

# ---------- install helpers (shared by -Check and the main flow) ----------

function Get-PythonCommand {
    if (Have 'py') { return 'py' }
    if (Have 'python') { return 'python' }
    return $null
}

function Try-InstallGit {
    if (-not (Have 'winget')) {
        Write-Host "No known installer for your platform. Install git from https://git-scm.com/downloads"
        return $false
    }
    Write-Host "git is not installed."
    Write-Host "Fix: winget install --id Git.Git -e"
    if (-not (Confirm "Install it now?")) { return $false }
    winget install --id Git.Git -e
    return (Have 'git')
}

function Try-InstallUv {
    Write-Host "uv is required but not installed."
    Write-Host "Fix: powershell -c `"irm https://astral.sh/uv/install.ps1 | iex`""
    if (-not (Confirm "Install it now with the official installer?")) { return $false }
    powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex"
    $env:Path = "$env:USERPROFILE\.local\bin;$env:USERPROFILE\.cargo\bin;$env:Path"
    return (Have 'uv')
}

# ============================================================
# -Check mode: verify, never clone/ask-for-a-key/touch .env
# ============================================================
$script:CheckFailed = $false

function Report {
    param([string]$Level, [string]$Label, [string]$Detail, [string]$FixCmd)
    switch ($Level) {
        'PASS' { Write-Host "  [PASS] $Label" }
        'INFO' { Write-Host "  [INFO] $Label" }
        'FAIL' {
            Write-Host "  [FAIL] $Label - $Detail"
            if ($FixCmd) { Write-Host "         Fix: $FixCmd" }
            $script:CheckFailed = $true
        }
    }
}

function Check-Git {
    if (-not (Have 'git')) { [void](Try-InstallGit) }
    if (Have 'git') {
        $v = (git --version)
        Report PASS "git ($v)"
    } else {
        Report FAIL "git" "not installed" "https://git-scm.com/downloads"
    }
}

function Check-Python {
    $py = Get-PythonCommand
    if (-not $py) {
        Report FAIL "python" "not installed" "install Python 3.11+ from https://www.python.org/downloads/"
        return
    }
    & $py -c "import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)" 2>$null
    if ($LASTEXITCODE -eq 0) {
        $v = (& $py -V 2>&1)
        Report PASS "python ($v)"
    } else {
        Report FAIL "python" "found but older than 3.8" "install Python 3.11+ from https://www.python.org/downloads/"
    }
}

function Check-Uv {
    if (-not (Have 'uv')) { [void](Try-InstallUv) }
    if (Have 'uv') {
        $v = (uv --version)
        Report PASS "uv ($v)"
    } else {
        Report FAIL "uv" "not installed" "irm https://astral.sh/uv/install.ps1 | iex"
    }
}

function Check-Node {
    if (Have 'node') {
        $v = (node --version)
        Report PASS "node ($v)"
    } else {
        Report FAIL "node" "not installed" "install from https://nodejs.org"
    }
}

function Check-Tkinter {
    # tkinter only matters on Linux for this interview's manual-testing tool;
    # Windows candidates are never asked to install it.
    Report INFO "tkinter check does not apply on Windows, skipped"
}

function Check-Network {
    foreach ($host_ in @('github.com', 'astral.sh')) {
        $ok = $true
        try {
            $null = Invoke-WebRequest -Uri "https://$host_" -Method Head -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        } catch {
            $ok = $false
        }
        if ($ok) {
            Report PASS "network: $host_ reachable"
        } else {
            Report FAIL "network: $host_" "could not reach $host_" "check your internet connection, VPN, or firewall"
        }
    }
}

function Check-GitHubAuth {
    # Informational only: the candidate may not have been invited yet.
    if (Have 'gh') {
        gh auth status *> $null
        if ($LASTEXITCODE -eq 0) {
            Report INFO "GitHub auth: signed in via gh CLI"
            return
        }
    }
    if (Have 'ssh') {
        $out = (ssh -T git@github.com -o BatchMode=yes -o ConnectTimeout=5 2>&1) -join "`n"
        if ($out -match 'successfully authenticated') {
            Report INFO "GitHub auth: SSH key authenticated"
            return
        }
    }
    if (Have 'git') {
        $helper = (git config --get credential.helper 2>$null)
        if ($helper) {
            Report INFO "GitHub auth: a git credential helper ('$helper') is configured (not verified)"
            return
        }
    }
    Report INFO "GitHub auth: not detected yet (fine if you haven't been invited to the repo yet)"
}

function Run-Check {
    $valid = @('git', 'python', 'uv', 'node', 'tkinter')
    $needsList = if ($Needs) { $Needs -split ',' | ForEach-Object { $_.Trim() } } else { @('git', 'python', 'uv') }

    foreach ($item in $needsList) {
        if ($valid -notcontains $item) {
            Fail "Unknown -Needs item '$item'. Supported: $($valid -join ', ')"
        }
    }

    Write-Host "Checking your machine for the interview..."
    Write-Host ""
    foreach ($item in $needsList) {
        switch ($item) {
            'git'     { Check-Git }
            'python'  { Check-Python }
            'uv'      { Check-Uv }
            'node'    { Check-Node }
            'tkinter' { Check-Tkinter }
        }
    }
    Check-Network
    Check-GitHubAuth

    Write-Host ""
    if ($script:CheckFailed) {
        Write-Host "Result: fix the items above."
        exit 1
    } else {
        Write-Host "Result: ready for the interview."
        exit 0
    }
}

if ($Check) { Run-Check }

# ============================================================
# Main flow: clone, install, ask for the key, write .env
# ============================================================
if (-not (Have 'git')) {
    if (-not (Try-InstallGit)) {
        Fail "git is not installed. Install it from https://git-scm.com/downloads and re-run."
    }
}

# ---------- clone ----------
$repoDir = [System.IO.Path]::GetFileName($RepoUrl.TrimEnd('/', '\'))
if ($repoDir.EndsWith('.git')) { $repoDir = $repoDir.Substring(0, $repoDir.Length - 4) }

git clone $RepoUrl $repoDir
Check-Exit "git clone"
Set-Location $repoDir

# ---------- repo-specific prerequisites + dependencies ----------
if (Test-Path 'pyproject.toml') {
    if (-not (Have 'uv')) {
        if (-not (Try-InstallUv)) { Fail "Please install uv (https://docs.astral.sh/uv/) and re-run." }
    }
    uv sync
    Check-Exit "uv sync"
} elseif (Test-Path 'requirements.txt') {
    $py = Get-PythonCommand
    if (-not $py) { Fail "Python 3 is not installed. Install it from https://www.python.org/downloads/ and re-run." }
    & $py -m pip install -r requirements.txt
    Check-Exit "pip install"
}

if (Test-Path 'package.json') {
    if (-not (Have 'npm')) { Fail "This repo needs Node.js/npm. Install from https://nodejs.org and re-run." }
    if ((Test-Path 'pnpm-lock.yaml') -and (Have 'pnpm')) { pnpm install }
    elseif ((Test-Path 'yarn.lock') -and (Have 'yarn')) { yarn install }
    else { npm install }
    Check-Exit "dependency install"
}

# ---------- API key ----------
$apiKey = [Environment]::GetEnvironmentVariable($keyName)
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Host ""
    Write-Host "Paste your API key and press Enter (nothing will appear as you paste - that's normal)."
    $secure = Read-Host -Prompt $keyName -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
$apiKey = ($apiKey -replace '\s', '')
if ([string]::IsNullOrEmpty($apiKey)) { Fail "No key entered. Re-run the script and paste the key when asked." }
Write-Host "Key received ($($apiKey.Length) characters)."

# ---------- .env ----------
if ((Test-Path '.env.example') -and -not (Test-Path '.env')) {
    Copy-Item '.env.example' '.env'
}
$envPath = Join-Path (Get-Location).Path '.env'
$lines = @()
if (Test-Path $envPath) { $lines = @(Get-Content -LiteralPath $envPath) }

$pattern = '^\s*(?:export\s+)?' + [regex]::Escape($keyName) + '\s*='
$kept = @($lines | Where-Object { $_ -notmatch $pattern })
$kept += "$keyName=$apiKey"

# UTF-8 without BOM so dotenv parsers read the first key correctly
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($envPath, [string[]]$kept, $utf8)

Write-Host "Setup complete. Project is in $((Get-Location).Path)"
