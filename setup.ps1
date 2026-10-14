# Usage (PowerShell):
#   powershell -ExecutionPolicy Bypass -File .\setup.ps1 <repo-url>
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
    [string]$Claim
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

if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
    Write-Host "Usage:"
    Write-Host "  .\setup.ps1 <repo-url>"
    exit 1
}

# ---------- install helpers (shared by -Check and the main flow) ----------

function Get-PythonCommand {
    if (Have 'py') { return 'py' }
    if (Have 'python') { return 'python' }
    # pwsh is cross-platform, and python3 is the usual name off Windows.
    if (Have 'python3') { return 'python3' }
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


# ============================================================
# Main flow: clone, install, ask for the key, write .env
# ============================================================
if (-not (Have 'git')) {
    if (-not (Try-InstallGit)) {
        Fail "git is not installed. Install it from https://git-scm.com/downloads and re-run."
    }
}

# ---------- API key (before the clone, on purpose) ----------
# A claim code is single-use. Cloning first meant a wrong or too-early code
# left a half-built directory behind, so the retry died on "destination path
# already exists" - and with a burned code there was nothing left to retry
# with. Nothing touches the disk until the key is in hand.
$apiKey = [Environment]::GetEnvironmentVariable($keyName)

# With -Claim, swap the code for the key rather than asking for a paste. The
# service returns the key as the whole body on success and a human-readable
# explanation on refusal (including "your key unlocks at HH:MM UTC" when run
# before the interview window opens), so the wording stays server-side and
# this script just prints what it's told.
if ([string]::IsNullOrWhiteSpace($apiKey) -and -not [string]::IsNullOrWhiteSpace($Claim)) {
    Write-Host ""
    Write-Host "Fetching your API key with claim code $Claim ..."
    $claimUrl = if ($env:CLAIM_URL) { $env:CLAIM_URL } else { 'https://onboarding-service-chi.vercel.app/api/claim' }
    $uri = "$claimUrl`?code=$([Uri]::EscapeDataString($Claim))"

    # No -SkipHttpErrorCheck: that's PowerShell 7+ only, and the README tells
    # candidates to run this with `powershell` (Windows PowerShell 5.1), where
    # it's an unknown-parameter error. Instead let a 4xx throw and dig the
    # response body out of the exception, which differs between the two
    # versions - 5.1 exposes a readable stream, 7 puts it in ErrorDetails.
    $claimStatus = 0
    $claimBody = ''
    try {
        $resp = Invoke-WebRequest -Uri $uri -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
        $claimStatus = [int]$resp.StatusCode
        $claimBody = $resp.Content
    } catch {
        $webResponse = $_.Exception.Response
        if ($null -eq $webResponse) {
            # No response at all - DNS, connection refused, timeout.
            Fail "Couldn't reach the key service. Check your internet connection and re-run, or ask your interviewer for the key to paste instead."
        }
        $claimStatus = [int]$webResponse.StatusCode
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $claimBody = $_.ErrorDetails.Message          # PowerShell 7
        } else {
            try {                                          # Windows PowerShell 5.1
                $reader = New-Object System.IO.StreamReader($webResponse.GetResponseStream())
                $claimBody = $reader.ReadToEnd()
                $reader.Close()
            } catch { $claimBody = '' }
        }
    }

    if ($claimStatus -eq 200) {
        # Don't trust a 200 to mean "this is a key". A captive portal or an
        # intercepting corporate proxy will happily return HTML with a 200, and
        # writing that into .env fails much later as a confusing auth error.
        $claimBody = ($claimBody -replace '\s', '')
        if (-not $claimBody.StartsWith('sk-ant-')) {
            Fail "The key service replied, but not with a key. You may be behind a proxy or captive portal that intercepted the request. Check your network and re-run, or ask your interviewer for the key to paste instead."
        }
        $apiKey = $claimBody
        Write-Host "Key received automatically - nothing to paste."
    } else {
        # 409 = too early, 410 = used or finished, 404 = unrecognised.
        if ([string]::IsNullOrWhiteSpace($claimBody)) {
            $claimBody = "The key service refused the claim code (HTTP $claimStatus). Ask your interviewer for the key to paste instead."
        }
        Write-Host ""
        Write-Host $claimBody.Trim() -ForegroundColor Yellow
        exit 1
    }
}

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

# ---------- clone ----------
$repoDir = [System.IO.Path]::GetFileName($RepoUrl.TrimEnd('/', '\'))
if ($repoDir.EndsWith('.git')) { $repoDir = $repoDir.Substring(0, $repoDir.Length - 4) }

# Reuse an existing checkout rather than failing. A candidate who re-runs this
# - after a failed claim, a dropped connection, or just twice - would otherwise
# hit "destination path already exists" and be stuck. Never deletes it: by the
# second run it may hold their work.
if (Test-Path (Join-Path $repoDir '.git')) {
    Write-Host "Found an existing $repoDir - reusing it instead of cloning again."
    Set-Location $repoDir
} elseif (Test-Path $repoDir) {
    Fail "'$repoDir' already exists here but isn't a git clone. Move or rename it, then re-run."
} else {
    git clone $RepoUrl $repoDir
    Check-Exit "git clone"
    Set-Location $repoDir
}

# ---------- .env (before installing, on purpose) ----------
# A claim code is single-use, so it's spent by the time we get here. If the
# dependency install below failed first, the key would be gone with nothing
# written, and the retry couldn't fetch it again - the candidate would need
# someone to read it to them. Getting it onto disk first makes a failed
# install a retryable annoyance instead.
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

# ---------- repo-specific prerequisites + dependencies ----------
if (Test-Path 'pyproject.toml') {
    if (-not (Have 'uv')) {
        if (-not (Try-InstallUv)) { Fail "Please install uv (https://docs.astral.sh/uv/) and re-run." }
    }
    uv sync
    Check-Exit "uv sync"
}


