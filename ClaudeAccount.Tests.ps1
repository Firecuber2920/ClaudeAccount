BeforeAll {
    . (Join-Path $PSScriptRoot 'ClaudeAccount.Core.ps1')
    # Needed so Get-StoredCredential exists in this scope for Mock to
    # intercept -- Get-ClassAuthToken imports it lazily itself at runtime,
    # but Pester's Mock needs the real command resolvable up front.
    Import-Module CredentialManager -ErrorAction SilentlyContinue
}

Describe 'Resolve-AccountConfigDir' {
    It 'returns the path unchanged if it already exists' {
        Resolve-AccountConfigDir -Account 'Personal' -Path $TestDrive | Should -Be $TestDrive
    }

    It 'auto-creates the Class dir if missing' {
        $missing = Join-Path $TestDrive 'class-new'
        Test-Path $missing | Should -BeFalse
        Resolve-AccountConfigDir -Account 'Class' -Path $missing | Should -Be $missing
        Test-Path $missing | Should -BeTrue
    }

    It 'fails loudly if the Personal dir is missing (does not auto-create)' {
        $missing = Join-Path $TestDrive 'personal-missing'
        { Resolve-AccountConfigDir -Account 'Personal' -Path $missing } | Should -Throw
        Test-Path $missing | Should -BeFalse
    }
}

Describe 'Get-ClassAuthToken' {
    It 'throws a clear error if the CredentialManager module is not installed' {
        Mock Get-Module { $null } -ParameterFilter { $Name -eq 'CredentialManager' }
        { Get-ClassAuthToken -Target 'unit-test-target' } | Should -Throw -ExpectedMessage '*CredentialManager*'
    }

    It 'throws a clear error if the credential is missing from Credential Manager' {
        Mock Get-Module { [pscustomobject]@{ Name = 'CredentialManager' } } -ParameterFilter { $Name -eq 'CredentialManager' }
        Mock Import-Module {}
        Mock Get-StoredCredential { $null }
        { Get-ClassAuthToken -Target 'unit-test-target' } | Should -Throw -ExpectedMessage '*No class auth token found*'
    }
}

Describe 'Get-AccountChoice' {
    It 'returns Class for input 1' {
        Mock Read-Host { '1' }
        Get-AccountChoice | Should -Be 'Class'
    }

    It 'returns Personal for input 2' {
        Mock Read-Host { '2' }
        Get-AccountChoice | Should -Be 'Personal'
    }

    It 're-prompts on invalid input instead of crashing' {
        $script:callCount = 0
        Mock Read-Host {
            $script:callCount++
            if ($script:callCount -eq 1) { return 'garbage' }
            return '2'
        }
        Get-AccountChoice | Should -Be 'Personal'
        $script:callCount | Should -Be 2
    }
}

Describe 'Get-ClassEnvBlock' {
    It 'produces the exact Cornell gateway shape with the given token' {
        $block = Get-ClassEnvBlock -AuthToken 'sk-real-token-123'
        $block['ANTHROPIC_BASE_URL'] | Should -Be 'https://api.ai.it.cornell.edu/'
        $block['ANTHROPIC_AUTH_TOKEN'] | Should -Be 'sk-real-token-123'
        $block['CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS'] | Should -Be '1'
        $block['DISABLE_TELEMETRY'] | Should -Be '1'
    }
}

Describe 'Update-ClassSettingsFile' {
    It 'creates settings.json with the env block when no file exists yet' {
        $path = Join-Path $TestDrive 'settings-new.json'
        Test-Path $path | Should -BeFalse

        Update-ClassSettingsFile -SettingsPath $path -EnvBlock (Get-ClassEnvBlock -AuthToken 'token-A')

        Test-Path $path | Should -BeTrue
        $written = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $written['env']['ANTHROPIC_AUTH_TOKEN'] | Should -Be 'token-A'
        $written['env']['ANTHROPIC_BASE_URL'] | Should -Be 'https://api.ai.it.cornell.edu/'
    }

    It 'updates the token on an existing settings.json without wiping unrelated keys' {
        $path = Join-Path $TestDrive 'settings-existing.json'
        @{
            env               = @{ ANTHROPIC_AUTH_TOKEN = 'old-token'; ANTHROPIC_BASE_URL = 'https://api.ai.it.cornell.edu/' }
            somethingElseSaved = 'do-not-delete-me'
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding utf8

        Update-ClassSettingsFile -SettingsPath $path -EnvBlock (Get-ClassEnvBlock -AuthToken 'new-token')

        $written = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $written['env']['ANTHROPIC_AUTH_TOKEN'] | Should -Be 'new-token'
        $written['somethingElseSaved'] | Should -Be 'do-not-delete-me'
    }

    It 'throws a clear error on malformed existing JSON rather than silently overwriting it' {
        $path = Join-Path $TestDrive 'settings-broken.json'
        Set-Content -Path $path -Value '{ not valid json' -Encoding utf8
        { Update-ClassSettingsFile -SettingsPath $path -EnvBlock (Get-ClassEnvBlock -AuthToken 'x') } | Should -Throw -ExpectedMessage '*Could not parse*'
    }
}

Describe 'Invoke-ClaudeSession' {
    BeforeEach {
        Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    }

    AfterEach {
        Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    }

    It 'restores a pre-existing CLAUDE_CONFIG_DIR after a normal (exit-0-equivalent) claude call, Personal branch' {
        $env:CLAUDE_CONFIG_DIR = 'C:\original'
        Invoke-ClaudeSession -Account 'Personal' -PersonalConfigDir $TestDrive -ClaudeCommand { param($a) }
        $env:CLAUDE_CONFIG_DIR | Should -Be 'C:\original'
    }

    It 'unsets CLAUDE_CONFIG_DIR (rather than leaving it) if it was not set beforehand' {
        Invoke-ClaudeSession -Account 'Personal' -PersonalConfigDir $TestDrive -ClaudeCommand { param($a) }
        Test-Path Env:\CLAUDE_CONFIG_DIR | Should -BeFalse
    }

    It 'restores CLAUDE_CONFIG_DIR even after claude throws (non-zero-equivalent), Class branch' {
        $env:CLAUDE_CONFIG_DIR = 'C:\original'
        $classDir = Join-Path $TestDrive 'class'
        Mock Get-ClassAuthToken { 'fake-token' }

        {
            Invoke-ClaudeSession -Account 'Class' -ClassConfigDir $classDir -ClaudeCommand {
                param($a) throw 'simulated claude failure'
            }
        } | Should -Throw

        $env:CLAUDE_CONFIG_DIR | Should -Be 'C:\original'
    }

    It 'writes the Class settings.json (with the real token) before launching claude' {
        Mock Get-ClassAuthToken { 'fake-token-xyz' }
        $classDir = Join-Path $TestDrive 'class3'
        Invoke-ClaudeSession -Account 'Class' -ClassConfigDir $classDir -ClaudeCommand { param($a) }

        $settingsPath = Join-Path $classDir 'settings.json'
        Test-Path $settingsPath | Should -BeTrue
        $written = Get-Content $settingsPath -Raw | ConvertFrom-Json -AsHashtable
        $written['env']['ANTHROPIC_AUTH_TOKEN'] | Should -Be 'fake-token-xyz'
        $written['env']['ANTHROPIC_BASE_URL'] | Should -Be 'https://api.ai.it.cornell.edu/'
    }
}
