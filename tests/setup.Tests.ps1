# Pester tests for ../setup.ps1.
#
# setup.ps1 is a top-level script (not a module), so these exercise it as a
# black box via subprocess invocation, the same approach as tests/run_tests.sh
# for setup.sh. Uses a local git repo instead of the network.
#
# Run with: pwsh -NoProfile -Command "Invoke-Pester -Path tests/setup.Tests.ps1 -Output Detailed"

BeforeAll {
    $ScriptRoot = Split-Path -Parent $PSScriptRoot
    $Setup = Join-Path $ScriptRoot 'setup.ps1'

    function Invoke-Setup {
        param([string[]]$ScriptArgs = @(), [hashtable]$Env = @{})
        $backup = @{}
        foreach ($k in $Env.Keys) {
            $backup[$k] = [Environment]::GetEnvironmentVariable($k)
            [Environment]::SetEnvironmentVariable($k, $Env[$k])
        }
        try {
            $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $Setup @ScriptArgs 2>&1 | Out-String
            $exit = $LASTEXITCODE
        } finally {
            foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $backup[$k]) }
        }
        [pscustomobject]@{ Output = $output; Exit = $exit }
    }

    $TmpRoot = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
    New-Item -ItemType Directory -Path $TmpRoot | Out-Null

    $FixtureSrc = Join-Path $TmpRoot 'fixture-src'
    New-Item -ItemType Directory -Path $FixtureSrc | Out-Null
    Push-Location $FixtureSrc
    git init -q -b main
    @('ANTHROPIC_API_KEY=', 'OTHER_VAR=keep-me') | Set-Content '.env.example'
    git add -A
    git -c user.email=test@example.com -c user.name=test commit -qm init
    Pop-Location
    $BareRepo = Join-Path $TmpRoot 'fixture.git'
    git clone -q --bare $FixtureSrc $BareRepo
}

AfterAll {
    Remove-Item -Recurse -Force $TmpRoot -ErrorAction SilentlyContinue
}

Describe 'setup.ps1 arguments' {
    It 'prints usage and exits 1 with no arguments' {
        $r = Invoke-Setup -ScriptArgs @()
        $r.Exit | Should -Be 1
        $r.Output | Should -Match 'Usage:'
    }
}

Describe 'setup.ps1 main flow' {
    It 'clones, derives the folder name, strips key whitespace, and merges .env' {
        $work = Join-Path $TmpRoot 'work1'
        New-Item -ItemType Directory -Path $work | Out-Null
        Push-Location $work
        try {
            $r = Invoke-Setup -ScriptArgs @($BareRepo) -Env @{ ANTHROPIC_API_KEY = '  test-key-123  ' }
            $stripped = '  test-key-123  ' -replace '\s', ''
            $r.Output | Should -Match "Key received \($($stripped.Length) characters\)"
            $envFile = Join-Path $work 'fixture' '.env'
            Test-Path $envFile | Should -BeTrue
            $content = Get-Content $envFile -Raw
            $content | Should -Match "ANTHROPIC_API_KEY=$stripped"
            $content | Should -Match 'OTHER_VAR=keep-me'
        } finally {
            Pop-Location
        }
    }

    It 'derives the folder name from a repo URL with a trailing slash' {
        $work = Join-Path $TmpRoot 'work2'
        New-Item -ItemType Directory -Path $work | Out-Null
        Push-Location $work
        try {
            $null = Invoke-Setup -ScriptArgs @("$BareRepo/") -Env @{ ANTHROPIC_API_KEY = 'k' }
            Test-Path (Join-Path $work 'fixture') | Should -BeTrue
        } finally {
            Pop-Location
        }
    }

    It 'honors KEY_NAME to use a different env var name' {
        $work = Join-Path $TmpRoot 'work3'
        New-Item -ItemType Directory -Path $work | Out-Null
        Push-Location $work
        try {
            $null = Invoke-Setup -ScriptArgs @($BareRepo) -Env @{ KEY_NAME = 'MY_KEY'; MY_KEY = 'xyz' }
            $content = Get-Content (Join-Path $work 'fixture' '.env') -Raw
            $content | Should -Match 'MY_KEY=xyz'
        } finally {
            Pop-Location
        }
    }
}

Describe 'setup.ps1 claim flow' {
    BeforeAll {
        # Same stub contract as tests/run_tests.sh: the code is the whole URL
        # query, the key is the whole body, refusals carry a human message.
        $script:ClaimPort = 8791
        $stub = Join-Path $TmpRoot 'claim_stub.py'
        @'
import http.server, urllib.parse, sys
CASES = {
    "GOODCODE": (200, "sk-ant-api03-fetched-by-claim-code"),
    "USEDCODE": (410, "That claim code has already been used. If you need the key again, ask your interviewer.\n"),
}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        code = (q.get("code") or [""])[0].upper().replace("-", "").replace(" ", "")
        status, body = CASES.get(code, (404, "That claim code isn't recognised.\n"))
        payload = body.encode()
        self.send_response(status)
        self.send_header("content-type", "text/plain; charset=utf-8")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
'@ | Set-Content -LiteralPath $stub
        $py = (Get-Command python3 -ErrorAction SilentlyContinue) ?? (Get-Command python -ErrorAction SilentlyContinue)
        $script:StubProc = $null
        if ($py) {
            $script:StubProc = Start-Process -FilePath $py.Source -ArgumentList @($stub, "$script:ClaimPort") -PassThru
            # Wait for it to accept connections rather than sleeping a guess.
            foreach ($i in 1..50) {
                try {
                    Invoke-WebRequest -Uri "http://127.0.0.1:$script:ClaimPort/?code=GOODCODE" -UseBasicParsing -TimeoutSec 1 | Out-Null
                    break
                } catch { Start-Sleep -Milliseconds 100 }
            }
        }
        $script:ClaimUrl = "http://127.0.0.1:$script:ClaimPort/"
    }

    AfterAll {
        if ($script:StubProc) { Stop-Process -Id $script:StubProc.Id -Force -ErrorAction SilentlyContinue }
    }

    It 'fetches the key with a claim code and writes it to .env' {
        $work = Join-Path $TmpRoot 'claim1'
        New-Item -ItemType Directory -Path $work | Out-Null
        Push-Location $work
        try {
            $r = Invoke-Setup -ScriptArgs @('-Claim', 'GOODCODE', $BareRepo) -Env @{ CLAIM_URL = $script:ClaimUrl }
            $r.Output | Should -Match 'Key received automatically'
            (Get-Content (Join-Path $work 'fixture' '.env') -Raw) | Should -Match 'ANTHROPIC_API_KEY=sk-ant-api03-fetched-by-claim-code'
        } finally { Pop-Location }
    }

    It 're-running with an already-spent code reuses the saved key instead of dying' {
        # The failure this was built for: setup failed after a successful
        # claim, so re-running the whole command spent the single-use code a
        # second time and got a 410 - while a working key sat in .env.
        $work = Join-Path $TmpRoot 'claim2'
        New-Item -ItemType Directory -Path $work | Out-Null
        Push-Location $work
        try {
            $null = Invoke-Setup -ScriptArgs @('-Claim', 'GOODCODE', $BareRepo) -Env @{ CLAIM_URL = $script:ClaimUrl }
            $r = Invoke-Setup -ScriptArgs @('-Claim', 'USEDCODE', $BareRepo) -Env @{ CLAIM_URL = $script:ClaimUrl }
            $r.Exit | Should -Be 0
            $r.Output | Should -Match 'reusing it instead of claiming again'
            $r.Output | Should -Not -Match 'already been used'
            (Get-Content (Join-Path $work 'fixture' '.env') -Raw) | Should -Match 'ANTHROPIC_API_KEY=sk-ant-api03-fetched-by-claim-code'
        } finally { Pop-Location }
    }

    It 'clones and installs before claiming, so a refused code spends nothing' {
        $work = Join-Path $TmpRoot 'claim3'
        New-Item -ItemType Directory -Path $work | Out-Null
        Push-Location $work
        try {
            $r = Invoke-Setup -ScriptArgs @('-Claim', 'USEDCODE', $BareRepo) -Env @{ CLAIM_URL = $script:ClaimUrl }
            $r.Exit | Should -Be 1
            # The checkout is left ready, so the retry only has to fetch a key.
            Test-Path (Join-Path $work 'fixture' '.git') | Should -BeTrue
            # And nothing was written, so no stale key can be reused later.
            Test-Path (Join-Path $work 'fixture' '.env') | Should -BeFalse
        } finally { Pop-Location }
    }
}
