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

# Normalised the same way the service does it, so the same code typed with or
# without its hyphen names the same remembered key.
$claimBare = if ($Claim) { ($Claim -replace '[^A-Za-z0-9]', '').ToUpperInvariant() } else { '' }

# Where a claimed key is remembered, named after the code that bought it.
# Empty when there is nowhere sensible to put it, which only costs the re-run
# shortcut - the claim itself still works.
$claimCache = ''
if ($claimBare) {
    $cacheRoot = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME }
                 elseif ($env:LOCALAPPDATA) { $env:LOCALAPPDATA }
                 elseif ($HOME) { Join-Path $HOME '.cache' }
                 else { '' }
    if ($cacheRoot) { $claimCache = Join-Path (Join-Path $cacheRoot 'fuse-interview') $claimBare }
}

if ($Claim -and ($claimBare.Length -lt 4 -or $claimBare.Length -gt 16)) {
    # The claim runs after the clone and the install now, so a code that was
    # never going to work would otherwise cost minutes before the service says
    # so. Length only, not the service's alphabet: duplicating that here would
    # start rejecting valid codes the day it changes.
    Fail "'$Claim' doesn't look like a claim code. It's the 8-character code from your setup email, e.g. ABCD-2345."
}

if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
    Write-Host "Usage:"
    Write-Host "  .\setup.ps1 <repo-url>"
    exit 1
}

# ---------- install helpers ----------

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

# ---------- repo-specific prerequisites + dependencies ----------
if (Test-Path 'pyproject.toml') {
    if (-not (Have 'uv')) {
        if (-not (Try-InstallUv)) { Fail "Please install uv (https://docs.astral.sh/uv/) and re-run." }
    }
    uv sync
    Check-Exit "uv sync"
}

# ---------- API key (last, on purpose) ----------
# A claim code is single-use, so everything that can fail - the clone, and the
# dependency install above all - happens before it is spent. The only step
# left after the claim is writing .env. A candidate whose install failed after
# claiming used to re-run the whole command, spend the code a second time and
# get a 410 while holding a working key on disk.
$apiKey = [Environment]::GetEnvironmentVariable($keyName)

# A key this code already bought beats claiming again: the code is single-use,
# so a second claim returns 410 and throws away a key already in hand.
#
# Remembered under the code rather than in the checkout's .env, for two
# reasons. A fixed location is found again when the candidate re-runs from a
# different folder, where .env is not. And keying it by the code means a later
# interview - a new code - misses and claims its own key, instead of silently
# reusing the previous interview's, which is revoked minutes after that
# interview ended and would fail as an unexplained 401.
if ([string]::IsNullOrWhiteSpace($apiKey) -and $claimCache -and (Test-Path -LiteralPath $claimCache)) {
    $saved = ((Get-Content -LiteralPath $claimCache -Raw) -replace '\s', '')
    # Only something that looks like a key. A truncated or half-written value
    # would otherwise be reused on every run, turning a recoverable setup
    # failure into an auth error with no way back.
    if ($saved.StartsWith('sk-ant-')) {
        $apiKey = $saved
        Write-Host ""
        Write-Host "You already claimed a key with this code - reusing it, no need to claim again."
    }
}

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
        # Saved before the .env write, not after: the code is spent from here
        # on, so this is what makes a re-run free whatever happens next.
        # Best-effort - a cache we cannot write must not fail a setup that has
        # already succeeded.
        if ($claimCache) {
            try {
                $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $claimCache) -ErrorAction Stop
                Set-Content -LiteralPath $claimCache -Value $apiKey -NoNewline -ErrorAction Stop
            } catch { }
        }
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

# ---------- .env (last, on purpose) ----------
# The only step after the claim, and by here the code is spent. Nothing that
# can fail may be added below this point, and a write that fails anyway has to
# hand the key over rather than lose it - that is the one remaining way to end
# up with a used code and no key, so it is handled rather than left to
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
try {
    [System.IO.File]::WriteAllLines($envPath, [string[]]$kept, $utf8)
} catch {
    Write-Host ""
    Write-Host "ERROR: couldn't write the key to $envPath" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Your claim code is already used, so here is the key itself - save it as" -ForegroundColor Yellow
    Write-Host "$keyName in .env yourself, or tell your interviewer the write failed." -ForegroundColor Yellow
    Write-Host ""
    Write-Host $apiKey
    exit 1
}


Write-Host "Setup complete. Project is in $((Get-Location).Path)"
