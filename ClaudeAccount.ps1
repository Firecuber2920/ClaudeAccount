#Requires -Version 6.0
# ClaudeAccount - prompts which Claude Code identity to use for this
# session (class-issued auth token vs personal claude.ai login), then
# launches `claude` under that identity. See ClaudeAccount.Core.ps1 for
# the actual logic -- this file is just the entry point.
# Requires PS6+ (settings.json merging uses ConvertFrom-Json -AsHashtable,
# not available in Windows PowerShell 5.1); the .cmd shim already calls pwsh.
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ClaudeArgs
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeAccount.Core.ps1')

$account = Get-AccountChoice
Invoke-ClaudeSession -Account $account -ClaudeArgs $ClaudeArgs
