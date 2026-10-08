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

Describe 'setup.ps1 -Check' {
    It 'exits 0 and reports PASS for git/uv when both are present' {
        # -Needs git,uv rather than the default (which also checks python):
        # this test host only has `python3` on PATH, not the `py`/`python`
        # launcher names Windows machines normally expose, so a default-needs
        # run would show a misleading python FAIL that has nothing to do with
        # the script's logic. The default-needs case still needs a real
        # Windows machine - see the test plan in the project summary.
        $r = Invoke-Setup -ScriptArgs @('-Check', '-Needs', 'git,uv')
        $r.Output | Should -Match 'Result: ready for the interview\.'
        $r.Exit | Should -Be 0
    }

    It 'rejects an unknown -Needs item without running any checks' {
        $r = Invoke-Setup -ScriptArgs @('-Check', '-Needs', 'bogus')
        $r.Exit | Should -Be 1
        $r.Output | Should -Match "Unknown -Needs item 'bogus'"
    }

    It 'only checks the items in -Needs' {
        $r = Invoke-Setup -ScriptArgs @('-Check', '-Needs', 'git,node')
        $r.Output | Should -Match '\[PASS\] git'
        $r.Output | Should -Match '\[PASS\] node'
        $r.Output | Should -Not -Match 'python'
        $r.Output | Should -Not -Match 'uv \('
    }

    It 'reports tkinter as not applicable on Windows-targeted logic (this host is not Windows, but the check itself is OS-gated, not host-gated)' {
        $r = Invoke-Setup -ScriptArgs @('-Check', '-Needs', 'tkinter')
        $r.Output | Should -Match 'tkinter check does not apply on Windows'
    }

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
