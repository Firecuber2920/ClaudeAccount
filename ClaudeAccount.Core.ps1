# ClaudeAccount.Core.ps1
# Functions for the ClaudeAccount launcher. Dot-source this file to get the
# functions without running anything (no prompting, no I/O on load) — this
# is what makes the logic testable in isolation with Pester.

$script:PersonalConfigDir = Join-Path $env:USERPROFILE '.claude'
$script:ClassConfigDir    = Join-Path $env:USERPROFILE '.claude-class'
$script:CredentialTarget  = 'ClaudeAccount-Class-AuthToken'
$script:ClassBaseUrl      = 'https://api.ai.it.cornell.edu/'
# Fixed array, not a hashtable key order -- a [hashtable]-typed parameter
# silently converts an [ordered] dictionary into a plain unordered Hashtable
# during PowerShell parameter binding, discarding insertion order (verified
# empirically: this bit the first version of Update-ClassSettingsFile). An
# array's order is never ambiguous, so canonical output order is driven from
# here instead of trusting any dictionary's .Keys enumeration order.
$script:ClassEnvKeyOrder = @(
    'ANTHROPIC_BASE_URL',
    'ANTHROPIC_AUTH_TOKEN',
    'CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS',
    'DISABLE_TELEMETRY'
)

function Get-AccountChoice {
    [CmdletBinding()]
    param()
    while ($true) {
        Write-Host ''
        Write-Host 'Which Claude account?'
        Write-Host '  1) Class'
        Write-Host '  2) Personal'
        $choice = Read-Host 'Enter 1 or 2'
        switch ($choice) {
            '1' { return 'Class' }
            '2' { return 'Personal' }
            default { Write-Host 'Please enter 1 or 2.' -ForegroundColor Yellow }
        }
    }
}

function Get-ClassAuthToken {
    # Stored via Credential Manager, not hardcoded here, so the token can be
    # updated (e.g. once the real Cornell-issued one replaces a placeholder)
    # without touching this script.
    [CmdletBinding()]
    param(
        [string] $Target = $script:CredentialTarget
    )
    if (-not (Get-Module -ListAvailable -Name CredentialManager)) {
        throw "The 'CredentialManager' PowerShell module is not installed. Run: Install-Module CredentialManager -Scope CurrentUser"
    }
    Import-Module CredentialManager -ErrorAction Stop

    $cred = Get-StoredCredential -Target $Target -ErrorAction SilentlyContinue
    if (-not $cred) {
        # Store via cmdkey, not New-StoredCredential -- the latter throws
        # under pwsh (tries to load System.Web.Security.Membership, a .NET
        # Framework-only type absent from .NET Core). Reading back via
        # Get-StoredCredential works fine under pwsh either way; only the
        # module's own write path is broken there. Verified empirically.
        throw "No class auth token found in Windows Credential Manager under target '$Target'.`nStore it first with:`n  cmdkey /generic:$Target /user:class /pass:<your-real-token>"
    }
    return $cred.GetNetworkCredential().Password
}

function Resolve-AccountConfigDir {
    # Class dirs auto-create on first use (the script itself populates them).
    # A missing Personal dir means something is wrong -- it should already
    # exist from a prior `claude login` -- so that case fails loudly instead.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Class', 'Personal')] [string] $Account,
        [Parameter(Mandatory)] [string] $Path
    )
    if (Test-Path $Path) {
        return $Path
    }
    if ($Account -eq 'Class') {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        return $Path
    }
    throw "Personal Claude config dir not found at '$Path'. Run 'claude login' once, outside ClaudeAccount, to set it up."
}

function Get-ClassEnvBlock {
    # The Cornell Claude Code gateway shape: a base URL + bearer token
    # instead of a direct Anthropic API key, plus two fixed flags. Order
    # matches what Cornell IT hands out, purely for readability if a human
    # opens the resulting settings.json.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $AuthToken,
        [string] $BaseUrl = $script:ClassBaseUrl
    )
    [ordered]@{
        ANTHROPIC_BASE_URL                     = $BaseUrl
        ANTHROPIC_AUTH_TOKEN                   = $AuthToken
        CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = '1'
        DISABLE_TELEMETRY                      = '1'
    }
}

function Update-ClassSettingsFile {
    # Merges the Cornell-gateway env block into settings.json's `env` object,
    # preserving any other keys already in the file (Claude Code itself adds
    # permissions/MCP config etc. over time) rather than overwriting it
    # wholesale. Re-run on every Class launch so a token updated in
    # Credential Manager is picked up without any other manual step.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SettingsPath,
        [Parameter(Mandatory)] [hashtable] $EnvBlock
    )
    $settings = [ordered]@{}
    if (Test-Path $SettingsPath) {
        $raw = Get-Content -Path $SettingsPath -Raw
        if ($raw -and $raw.Trim()) {
            try {
                $settings = $raw | ConvertFrom-Json -AsHashtable -Depth 20
            }
            catch {
                throw "Could not parse existing settings.json at '$SettingsPath' (invalid JSON). Fix or delete it manually, then retry. Original error: $($_.Exception.Message)"
            }
        }
    }
    $existingEnv = @{}
    if ($settings.Contains('env') -and $null -ne $settings['env']) {
        $existingEnv = $settings['env']
    }

    # Build the final env object in a fixed, predictable order: the
    # canonical Cornell-gateway keys first (per $script:ClassEnvKeyOrder,
    # updated to the current values in $EnvBlock), then any other keys the
    # file already had (e.g. added by Claude Code itself) preserved as-is.
    $finalEnv = [ordered]@{}
    foreach ($key in $script:ClassEnvKeyOrder) {
        if ($EnvBlock.ContainsKey($key)) {
            $finalEnv[$key] = $EnvBlock[$key]
        }
        elseif ($existingEnv.Contains($key)) {
            $finalEnv[$key] = $existingEnv[$key]
        }
    }
    foreach ($key in $existingEnv.Keys) {
        if (-not $finalEnv.Contains($key)) { $finalEnv[$key] = $existingEnv[$key] }
    }
    foreach ($key in $EnvBlock.Keys) {
        if (-not $finalEnv.Contains($key)) { $finalEnv[$key] = $EnvBlock[$key] }
    }
    $settings['env'] = $finalEnv

    $json = $settings | ConvertTo-Json -Depth 20
    Set-Content -Path $SettingsPath -Value $json -Encoding utf8
}

function Invoke-ClaudeSession {
    # try/finally scopes CLAUDE_CONFIG_DIR to this call. A plain
    # `$env:X = value` in PowerShell persists in the CURRENT shell session
    # after the child process exits -- without explicit save/restore here,
    # a bare `claude` typed later in the same terminal would silently keep
    # using whichever account was last selected. (The class credential
    # itself lives in that account's settings.json, not a process env var,
    # so there's nothing else to scope/restore.)
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Class', 'Personal')] [string] $Account,
        [string[]] $ClaudeArgs = @(),
        [string] $PersonalConfigDir = $script:PersonalConfigDir,
        [string] $ClassConfigDir = $script:ClassConfigDir,
        # Injectable so tests can substitute a fake instead of launching the
        # real `claude` binary.
        [scriptblock] $ClaudeCommand = { param($a) & claude @a }
    )

    $originalConfigDirSet = Test-Path Env:\CLAUDE_CONFIG_DIR
    $originalConfigDir    = $env:CLAUDE_CONFIG_DIR

    try {
        if ($Account -eq 'Class') {
            $dir = Resolve-AccountConfigDir -Account 'Class' -Path $ClassConfigDir
            $token = Get-ClassAuthToken
            $envBlock = Get-ClassEnvBlock -AuthToken $token
            Update-ClassSettingsFile -SettingsPath (Join-Path $dir 'settings.json') -EnvBlock $envBlock
            $env:CLAUDE_CONFIG_DIR = $dir
            Write-Host 'Launching Claude Code as CLASS...' -ForegroundColor Cyan
        }
        else {
            $dir = Resolve-AccountConfigDir -Account 'Personal' -Path $PersonalConfigDir
            $env:CLAUDE_CONFIG_DIR = $dir
            Write-Host 'Launching Claude Code as PERSONAL...' -ForegroundColor Cyan
        }

        & $ClaudeCommand $ClaudeArgs
    }
    finally {
        if ($originalConfigDirSet) { $env:CLAUDE_CONFIG_DIR = $originalConfigDir } else { Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
    }
}
