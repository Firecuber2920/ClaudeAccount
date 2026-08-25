# ClaudeAccount

A small Windows CLI tool for switching between two Claude Code identities on
one laptop: a personal claude.ai login, and a class-issued auth token routed
through Cornell's Claude Code gateway (`api.ai.it.cornell.edu`).

Run `ClaudeAccount` instead of `claude`. It asks which account you want for
that session, then launches Claude Code as that identity — no manual env var
juggling, no re-login.

```
> ClaudeAccount

Which Claude account?
  1) Class
  2) Personal
Enter 1 or 2:
```

## How it works

- **Personal** points `CLAUDE_CONFIG_DIR` at your normal `%USERPROFILE%\.claude`
  folder, where `claude login`'s OAuth session already lives. Nothing else
  changes — this is just your regular Claude Code.
- **Class** points `CLAUDE_CONFIG_DIR` at an isolated `%USERPROFILE%\.claude-class`
  folder and writes the Cornell gateway config into that folder's
  `settings.json`:
  ```json
  {
    "env": {
      "ANTHROPIC_BASE_URL": "https://api.ai.it.cornell.edu/",
      "ANTHROPIC_AUTH_TOKEN": "<your token, from Windows Credential Manager>",
      "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1",
      "DISABLE_TELEMETRY": "1"
    }
  }
  ```
  The token is read from Windows Credential Manager on every launch, so it's
  never hardcoded in the repo, and updating it is a one-line command, not a
  code change. The two folders are fully isolated from each other, so
  switching never touches your personal login.

## Setup

**Prerequisites:** Windows, [PowerShell 7 (`pwsh`)](https://aka.ms/powershell)
(not Windows PowerShell 5.1 — `settings.json` merging needs a PS7+ feature),
and [Claude Code](https://claude.com/claude-code) already installed and
logged in (`claude login`) for your personal account.

1. **Clone this repo** somewhere permanent, e.g. `%USERPROFILE%\Documents\ClaudeAccount`.

2. **Add the folder to your PATH** (PowerShell, one-time):
   ```powershell
   $dir = "$HOME\Documents\ClaudeAccount"  # wherever you cloned it
   $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
   [Environment]::SetEnvironmentVariable('PATH', "$userPath;$dir", 'User')
   ```
   Open a new terminal afterward — PATH changes don't apply to already-open ones.

3. **Install the `CredentialManager` PowerShell module** (used to read your
   stored class token):
   ```powershell
   Install-Module CredentialManager -Scope CurrentUser
   ```

4. **Store your class auth token** in Windows Credential Manager. Use native
   `cmdkey`, not the module's own `New-StoredCredential` — that one throws
   under `pwsh` (it depends on a .NET Framework-only API). `Get-StoredCredential`
   (used to *read* it back) works fine under `pwsh`; only the module's write
   path is broken.
   ```
   cmdkey /generic:ClaudeAccount-Class-AuthToken /user:class /pass:<your-real-token>
   ```

5. Run `ClaudeAccount`, pick an account, done.

## Running the tests

```powershell
Install-Module Pester -MinimumVersion 5.0.0 -Force -SkipPublisherCheck -Scope CurrentUser
Invoke-Pester -Path .\ClaudeAccount.Tests.ps1
```

Windows ships an old Pester 3.4.0 by default, which isn't compatible with
this test file's syntax — if both are installed, make sure the newer one is
loaded (`Import-Module Pester -MinimumVersion 5.0.0 -Force`) before running.

## Adapting this for a different gateway or school

The Cornell-specific values (`ANTHROPIC_BASE_URL`, the two feature flags) are
set in `ClaudeAccount.Core.ps1` near the top (`$script:ClassBaseUrl`,
`Get-ClassEnvBlock`). If your class uses a different gateway, that's the only
place to change.

## Files

- `ClaudeAccount.ps1` — entry point (the prompt + launch, nothing else)
- `ClaudeAccount.Core.ps1` — the actual logic; dot-sourced by both the entry
  point and the tests, so it's testable without needing to actually launch
  Claude Code
- `ClaudeAccount.cmd` — a thin `cmd.exe` compatibility shim (PowerShell runs
  `ClaudeAccount.ps1` directly by bare name on its own; this just covers
  `cmd.exe`, which doesn't)
- `ClaudeAccount.Tests.ps1` — Pester test suite
