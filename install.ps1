<#
.SYNOPSIS
  Installs claude-muse-mode: Claude Code on Meta's Muse Model API.
.DESCRIPTION
  Copies the launcher scripts to an install directory (default
  %LOCALAPPDATA%\claude-muse-mode), writes a machine-local settings.json
  whose apiKeyHelper points at the installed key.ps1, DPAPI-encrypts the
  Meta Model API key you paste into modelapi-key.dpapi (this Windows user
  only), and adds the install directory to your user PATH so plain
  `muse-mode on | off | status` works in any terminal. It also writes Muse
  usage pricing (Meta per-Mtok rates) to
  %ProgramFiles%\ClaudeCode\managed-settings.json (one UAC prompt),
  so /cost prices Muse models instead of reporting "unknown models".

  The key is held as a SecureString, never printed, never logged, and the
  plaintext buffer is zeroed after encryption. Re-running replaces the
  installed files; the stored key is replaced only with -Force or on
  confirmation.
.PARAMETER InstallDir
  Target directory. Defaults to %LOCALAPPDATA%\claude-muse-mode.
.PARAMETER ApiKey
  Optional SecureString for non-interactive use (tests). When omitted the
  script prompts with Read-Host -AsSecureString.
.PARAMETER NoPathUpdate
  Skip the user-PATH update.
.PARAMETER Force
  Overwrite an existing stored key without confirming.
.PARAMETER Target
  Where the tools point: cli (vanilla terminal via user PATH), vscode
  (plus a "Muse" terminal profile in VS Code settings), or other (PATH
  plus manual setup notes for another IDE or editor). When omitted the
  installer asks with a small text menu; non-interactive runs must pass it.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1
.EXAMPLE
  pwsh ./install.ps1 -InstallDir "$env:TEMP\claude-muse-mode-test" -NoPathUpdate -ApiKey $canary -Target other
#>
[CmdletBinding()]
param(
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'claude-muse-mode'),
  [System.Security.SecureString]$ApiKey,
  [switch]$NoPathUpdate,
  [switch]$Force,
  [string]$Target = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

# JSON helpers, duplicated from src/muse-mode.ps1 (kept inline so the
# installer stays a single self-contained file).
function Convert-JsonValueToHashtable($Value) {
  if ($Value -is [System.Management.Automation.PSCustomObject]) {
    $ht = [ordered]@{}
    foreach ($prop in $Value.PSObject.Properties) {
      $ht[$prop.Name] = Convert-JsonValueToHashtable $prop.Value
    }
    return $ht
  }
  if ($Value -is [Array]) {
    return @($Value | ForEach-Object { Convert-JsonValueToHashtable $_ })
  }
  return $Value
}

function Read-JsonAsHashtable([string]$Path) {
  $parsed = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  $ht = Convert-JsonValueToHashtable $parsed
  if ($ht -isnot [System.Collections.IDictionary]) { throw "Expected a JSON object at top level: $Path" }
  return $ht
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

# Installer TUI. Display output goes through Write-UiLine (Write-Host), NOT
# Write-Output: these screens render inside functions whose return values
# the installer consumes (Select-InstallTarget, Request-ApiKey,
# Confirm-ReplaceKey), and Write-Output there becomes part of the return
# value - Object[] where a string/SecureString/bool belongs. Write-Host is
# host-only, so returns stay clean. Every screen stays fully readable with
# no color at all. The Get-* helpers are pure text so the test suite can
# pin the labels without ever prompting.
function Write-UiLine {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Installer TUI: host-only display inside value-returning functions; Write-Output would pollute returns.')]
  param(
    [string]$Text = '',
    [System.ConsoleColor]$Color = [System.ConsoleColor]::Gray
  )
  Write-Host $Text -ForegroundColor $Color
}

function Get-InstallerBanner {
  # Normalized to CRLF: the art is a here-string, so its newlines follow
  # the file's own line endings, while callers split on CRLF.
  $text = @'
  __  __ _   _ ____  _____
 |  \/  | | | / ___|| ____|
 | |\/| | | | \___ \|  _|
 | |  | | |_| |___) | |___
 |_|  |_|\___/|____/|_____|
 claude-muse-mode installer  (unofficial)
 Run Claude Code on Meta's Muse Model API - switch back anytime.

 This installer will:
   1. Copy the switcher scripts to your install folder
   2. Encrypt your Meta Model API key (DPAPI, this Windows user only)
   3. Write a machine-local settings.json (your own files untouched)
   4. Add the install folder to your user PATH
   5. Write Muse usage pricing (one admin prompt, Meta rates)
'@
  return ($text -replace "`r?`n", "`r`n")
}

function Get-TargetMenu([string]$Recommended) {
  $lines = @(
    ' Where will you use Claude Code?  (Step 1 of 3)',
    ' Pick the line that matches you - each choice builds on the last.',
    '',
    '   [1] Vanilla CLI',
    '       The tools on your user PATH; works in any terminal.',
    '',
    '   [2] VS Code',
    '       Everything in [1], plus a "Muse" terminal profile that',
    '       opens a Muse-ready terminal in one click.',
    '',
    '   [3] Other IDE or editor',
    '       Everything in [1], plus printed setup notes for pointing',
    '       your editor at the same settings.',
    '',
    ' Type 1, 2, or 3 (words work too: cli, vscode, other).'
  )
  if (-not [string]::IsNullOrWhiteSpace($Recommended)) {
    $key = $Recommended.Trim().ToLower()
    $names = @{ '1' = 'cli'; '2' = 'vscode'; '3' = 'other' }
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match '^\s+\[(\d)\]') {
        if ($names[$Matches[1]] -eq $key) { $lines[$i] += '   <-- recommended' }
      }
    }
  }
  return ($lines -join "`r`n")
}

function Convert-TargetChoice($Answer) {
  if ($null -eq $Answer) { return $null }
  $clean = $Answer.ToString().Trim().ToLower()
  if ($clean -eq '1' -or $clean -eq 'cli') { return 'cli' }
  if ($clean -eq '2' -or $clean -eq 'vscode') { return 'vscode' }
  if ($clean -eq '3' -or $clean -eq 'other') { return 'other' }
  return $null
}

function Get-RecommendedTarget {
  # A machine with VS Code gets the VS Code target recommended (either the
  # `code` command or a settings folder counts as "has VS Code").
  if (Get-Command code -ErrorAction SilentlyContinue) { return 'vscode' }
  if (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Code')) { return 'vscode' }
  return 'cli'
}

function Show-InstallerBanner {
  # The art is the first five lines; the rest gets section coloring.
  $lines = (Get-InstallerBanner) -split "`r`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($i -lt 5) { Write-UiLine $lines[$i] Cyan }
    elseif ($lines[$i] -match 'This installer will') { Write-UiLine $lines[$i] Yellow }
    else { Write-UiLine $lines[$i] }
  }
}

function Show-TargetMenu([string]$Recommended) {
  foreach ($line in (Get-TargetMenu $Recommended) -split "`r`n") {
    if ($line -match '^\s+\[\d\]') { Write-UiLine $line Yellow }
    elseif ($line -match 'Step 1 of 3') { Write-UiLine $line Yellow }
    else { Write-UiLine $line }
  }
}

function Request-ApiKey {
  Write-UiLine
  Write-UiLine ' Your Meta Model API key  (Step 2 of 3)' Yellow
  Write-UiLine ' Paste the key below. It is never displayed, never logged,'
  Write-UiLine ' and is encrypted immediately (DPAPI: only your Windows'
  Write-UiLine ' user can ever read it back).'
  Write-UiLine
  return (Read-Host ' Paste key (input stays hidden)' -AsSecureString)
}

function Confirm-ReplaceKey {
  Write-UiLine
  Write-UiLine ' A stored key already exists.' Yellow
  Write-UiLine '   [y] Replace it with a new key'
  Write-UiLine '   [N] Keep the existing key (default - just press Enter)'
  Write-UiLine
  return ((Read-Host ' Replace the stored key? [y/N]') -eq 'y')
}

function Get-InstallSummary([string]$Target) {
  $lines = @(
    '',
    ' Done! Next steps:',
    '   1. Open a NEW terminal (so it picks up your updated PATH).',
    '   2. Run:  muse-mode on',
    '   3. Open a new Claude Code session to use Muse.'
  )
  if ($Target -eq 'vscode') {
    $lines += '   Tip: in VS Code, open a new terminal with the "Muse" profile.'
  }
  $lines += '   Back out any time with:  muse-mode off'
  return ($lines -join "`r`n")
}

function Show-InstallSummary([string]$Target) {
  foreach ($line in (Get-InstallSummary $Target) -split "`r`n") {
    if ($line -match 'Done!') { Write-UiLine $line Green }
    else { Write-UiLine $line }
  }
}

function Select-InstallTarget([string]$Choice) {
  $valid = @('cli', 'vscode', 'other')
  if (-not [string]::IsNullOrWhiteSpace($Choice)) {
    if ($valid -contains $Choice.Trim().ToLower()) { return $Choice.Trim().ToLower() }
    throw "Unknown -Target '$Choice'. Use cli, vscode, or other."
  }
  if (-not [Environment]::UserInteractive) {
    throw 'Non-interactive install must pass -Target (cli, vscode, or other).'
  }
  Show-InstallerBanner
  $recommended = Get-RecommendedTarget
  for ($i = 0; $i -lt 3; $i++) {
    Write-UiLine
    Show-TargetMenu $recommended
    Write-UiLine
    $picked = Convert-TargetChoice (Read-Host ' Your choice [1/2/3]')
    if ($null -ne $picked) { return $picked }
    Write-UiLine ' Not a choice - type 1, 2, or 3 (or: cli, vscode, other).' Yellow
  }
  throw 'No valid target chosen.'
}

function Get-VSCodeSettingsPath {
  # Tests only: redirect at a temp file instead of the real settings.
  if (-not [string]::IsNullOrWhiteSpace($env:MUSE_TEST_VSCODE_SETTINGS)) {
    return $env:MUSE_TEST_VSCODE_SETTINGS
  }
  return Join-Path $env:APPDATA 'Code\User\settings.json'
}

function Install-VSCodeProfile([string]$LauncherPath) {
  $path = Get-VSCodeSettingsPath
  $dir = Split-Path $path -Parent
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if (Test-Path -LiteralPath $path) { $vs = Read-JsonAsHashtable $path }
  else { $vs = [ordered]@{} }
  foreach ($key in @('terminal', 'terminal.integrated', 'terminal.integrated.profiles', 'terminal.integrated.profiles.windows')) {
    $parts = $key -split '\.'
    $node = $vs
    foreach ($part in $parts) {
      if (-not $node.Contains($part)) { $node[$part] = [ordered]@{} }
      $node = $node[$part]
    }
  }
  $profiles = $vs['terminal']['integrated']['profiles']['windows']
  $wanted = [ordered]@{
    path = "$env:SystemRoot\System32\cmd.exe"
    args = @('/k', $LauncherPath)
  }
  if ($profiles.Contains('Muse')) {
    $existing = $profiles['Muse']
    $same = ($existing -is [System.Collections.IDictionary]) -and
      ($existing['path'] -eq $wanted['path']) -and
      (($existing['args'] -join "`0") -eq ($wanted['args'] -join "`0"))
    if ($same) { Write-Output 'VS Code "Muse" terminal profile already set.'; return }
    Write-Warning 'VS Code already has a "Muse" terminal profile pointing elsewhere; leaving it alone.'
    return
  }
  Copy-Item -LiteralPath $path -Destination "$path.bak-muse-mode" -Force -ErrorAction SilentlyContinue
  $profiles['Muse'] = $wanted
  Write-Utf8NoBom $path ($vs | ConvertTo-Json -Depth 32)
  Write-Output 'Added the VS Code "Muse" terminal profile.'
}

# Muse usage pricing. Claude Code prices unknown model ids at Anthropic
# fallback rates ("unknown models" warning), so the installer writes Meta
# per-Mtok rates as modelPricing overrides. Honored only from the
# admin-controlled managed-settings.json (user settings.json is ignored
# by design), hence one UAC prompt. Self-toggling: rows match muse-* ids
# only, so Anthropic sessions keep built-in list pricing.
# Meta rate card 2026-09-29 (dev.meta.ai/docs/pricing-rate-limits):
# contributor (1.3/1.2-contributor) in $0.10 / out $0.20 / cached $0.002;
# standard (1.3, 1.2, 1.1) in $1.25 / out $4.25 / cached $0.15 per 1M.
# cacheWrite = input: the page lists no separate write rate, and cache
# creation bills at the input rate.
function Get-MusePricingJson {
  $rows = @(
    @('muse-spark-1.3-contributor', 0.1, 0.2, 0.002, 0.1),
    @('muse-spark-1.2-contributor', 0.1, 0.2, 0.002, 0.1),
    @('muse-spark-1.3', 1.25, 4.25, 0.15, 1.25),
    @('muse-spark-1.2', 1.25, 4.25, 0.15, 1.25),
    @('muse-spark-1.1', 1.25, 4.25, 0.15, 1.25)
  )
  $overrides = [ordered]@{}
  foreach ($row in $rows) {
    $overrides[$row[0]] = [ordered]@{
      input = $row[1]; output = $row[2]; cacheRead = $row[3]; cacheWrite = $row[4]
    }
  }
  $doc = [ordered]@{ modelPricing = [ordered]@{ overrides = $overrides } }
  return ($doc | ConvertTo-Json -Depth 8)
}

function Get-ManagedSettingsPath {
  # Tests only: redirect at a temp file instead of Program Files.
  if (-not [string]::IsNullOrWhiteSpace($env:MUSE_TEST_MANAGED_SETTINGS)) {
    return $env:MUSE_TEST_MANAGED_SETTINGS
  }
  # No hardcoded drive: resolve the real Program Files on this machine
  # (%ProgramFiles%, honoring 32/64-bit redirection via the env var).
  $programFiles = $env:ProgramFiles
  if ([string]::IsNullOrWhiteSpace($programFiles)) { $programFiles = 'C:\Program Files' }
  return (Join-Path $programFiles 'ClaudeCode\managed-settings.json')
}

function Install-MusePricing {
  # Returns $true when the file was written (or already current), $false
  # when elevation was declined or unavailable (non-fatal: /cost keeps
  # fallback pricing, everything else works).
  $path = Get-ManagedSettingsPath
  $wanted = Get-MusePricingJson
  if ((Test-Path -LiteralPath $path) -and
      ((Get-Content -Raw -LiteralPath $path) -eq $wanted)) {
    Write-Output 'Muse usage pricing already set.'
    return $true
  }
  if (-not [string]::IsNullOrWhiteSpace($env:MUSE_TEST_MANAGED_SETTINGS)) {
    # Test sandbox: plain write, no elevation.
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Utf8NoBom $path $wanted
    return $true
  }
  if (-not [Environment]::UserInteractive) {
    # Non-interactive runs (CI) cannot answer a UAC prompt: skip loudly.
    Write-Warning 'Skipping Muse usage pricing (non-interactive session cannot show the admin prompt). /cost keeps fallback pricing; re-run the installer interactively to add it.'
    return $false
  }
  try {
    $principal = New-Object Security.Principal.WindowsPrincipal(
      [Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  }
  catch { $isAdmin = $false }
  if ($isAdmin) {
    # Already elevated: write directly, no second prompt.
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Utf8NoBom $path $wanted
    if ((Get-Content -Raw -LiteralPath $path) -ne $wanted) {
      Write-Warning 'Muse usage pricing verification failed. /cost keeps fallback pricing; re-run the installer to retry.'
      return $false
    }
    Write-Output 'Wrote Muse usage pricing (Meta rates; new sessions price Muse at Meta rates).'
    return $true
  }
  Write-UiLine ' Muse usage pricing needs one admin step (Step 3 of 3).' Yellow
  Write-UiLine ' A UAC prompt will ask for permission to write'
  Write-UiLine " $path"
  Write-UiLine ' (Meta per-token rates, so /cost stops saying "unknown models").'
  try {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'muse-managed-settings.json'
    Write-Utf8NoBom $tmp $wanted
    $managedDir = Split-Path $path -Parent
    $cmd = "New-Item -ItemType Directory -Path '$managedDir' -Force | Out-Null; " +
      "Copy-Item -LiteralPath '$tmp' -Destination '$path' -Force; " +
      "Remove-Item -LiteralPath '$tmp' -Force -ErrorAction SilentlyContinue"
    $proc = Start-Process powershell -Verb RunAs -ArgumentList @(
      '-NoProfile', '-NonInteractive', '-Command', $cmd) -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
      Write-Warning 'Muse usage pricing was not installed (elevation declined or failed). /cost keeps fallback pricing; re-run the installer to retry.'
      return $false
    }
  }
  catch {
    Write-Warning 'Muse usage pricing was not installed (elevation declined or failed). /cost keeps fallback pricing; re-run the installer to retry.'
    return $false
  }
  # Verify the elevated copy landed byte-identical.
  try {
    if ((Get-Content -Raw -LiteralPath $path) -ne $wanted) {
      Write-Warning 'Muse usage pricing verification failed. /cost keeps fallback pricing; re-run the installer to retry.'
      return $false
    }
  }
  catch {
    Write-Warning 'Muse usage pricing verification failed. /cost keeps fallback pricing; re-run the installer to retry.'
    return $false
  }
  Write-Output 'Wrote Muse usage pricing (Meta rates; new sessions price Muse at Meta rates).'
  return $true
}

function Get-ClaudeHooksDir {
  # Tests only: redirect at a temp dir instead of the real hooks dir.
  if (-not [string]::IsNullOrWhiteSpace($env:MUSE_TEST_HOOKS_DIR)) {
    return $env:MUSE_TEST_HOOKS_DIR
  }
  return (Join-Path $env:USERPROFILE '.claude\hooks')
}

function Get-ClaudeSettingsPath {
  # Tests only: redirect at a temp file instead of the real settings.
  if (-not [string]::IsNullOrWhiteSpace($env:MUSE_TEST_CLAUDE_SETTINGS)) {
    return $env:MUSE_TEST_CLAUDE_SETTINGS
  }
  return (Join-Path $env:USERPROFILE '.claude\settings.json')
}

function Install-MuseGate([string]$SourcePath) {
  # Copies muse-gate.js to the Claude hooks dir and points the
  # UserPromptSubmit hook at it, plus registers a Stop hook on the same
  # dispatcher (the Stop continuer forces one more turn while Muse mode is
  # on, capped at 2 per transcript; Claude mode gets '{}' so stops stand).
  # The dispatcher runs the previous tracker itself for UserPromptSubmit,
  # then appends the anti-stall reminder only while Muse mode is on;
  # Claude-mode output is untouched. Unknown hook shapes are left
  # alone loudly. Returns $true when registered (or already current, or
  # nothing to register yet), $false when skipped.
  if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Join-Path $PSScriptRoot 'src\muse-gate.js'
  }
  if (-not (Test-Path -LiteralPath $SourcePath)) {
    Write-Warning 'muse-gate.js not found next to install.ps1; turn-chain reminder not installed.'
    return $false
  }
  $hooksDir = Get-ClaudeHooksDir
  if (-not (Test-Path -LiteralPath $hooksDir)) { New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null }
  Copy-Item -LiteralPath $SourcePath -Destination (Join-Path $hooksDir 'muse-gate.js') -Force
  $settingsPath = Get-ClaudeSettingsPath
  if (-not (Test-Path -LiteralPath $settingsPath)) {
    Write-Output 'No Claude settings.json yet; turn-chain reminder registers on first run.'
    return $true
  }
  $text = Get-Content -Raw -LiteralPath $settingsPath
  $promptDone = $text -match 'muse-gate\.js'
  if ($promptDone) {
    Write-Output 'Turn-chain reminder already set.'
  }
  elseif (([regex]::Matches($text, 'caveman-mode-tracker\.js')).Count -ne 1) {
    Write-Output 'UserPromptSubmit hook is not the known tracker; leaving it alone (turn-chain reminder not installed).'
    return $false
  }
  else {
    # JSON edit (not line surgery): swap the tracker command for the
    # dispatcher and bump only that entry's timeout. Line surgery could
    # hit an unrelated hook's timeout in single-line files.
    Copy-Item -LiteralPath $settingsPath -Destination "$settingsPath.bak-muse-gate" -Force -ErrorAction SilentlyContinue
    try {
      $doc = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
      $upsHooks = $doc.hooks.UserPromptSubmit.hooks
      if ($upsHooks.command -notmatch 'caveman-mode-tracker\.js') { throw 'tracker command moved' }
      $upsHooks.command = $upsHooks.command -replace 'caveman-mode-tracker\.js', 'muse-gate.js'
      if ($upsHooks.timeout -eq 5) { $upsHooks.timeout = 10 }
      Write-Utf8NoBom $settingsPath ($doc | ConvertTo-Json -Depth 32)
      $check = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
      if ($check.hooks.UserPromptSubmit.hooks.command -notmatch 'muse-gate\.js') { throw 'verification failed' }
    }
    catch {
      Copy-Item -LiteralPath "$settingsPath.bak-muse-gate" -Destination $settingsPath -Force -ErrorAction SilentlyContinue
      Write-Warning 'Turn-chain reminder verification failed; settings restored.'
      return $false
    }
    Write-Output 'Turn-chain reminder installed (Muse mode only; Claude mode untouched).'
    $text = Get-Content -Raw -LiteralPath $settingsPath
  }
  # Stop hook: same dispatcher, fail-closed registration - the dispatcher
  # itself decides (off/continuing/capped -> '{}', silent). Only add when
  # the hook table parses as JSON; anything else is left alone loudly.
  try {
    $doc = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
  }
  catch {
    Write-Warning 'Claude settings.json does not parse; Stop hook not installed.'
    return $false
  }
  if (-not $doc.hooks) { return $true }
  $stopCmd = $null
  try { $stopCmd = $doc.hooks.Stop.hooks.command } catch { $stopCmd = $null }
  if ($stopCmd -match 'muse-gate\.js') {
    Write-Output 'Turn-chain Stop hook already set.'
    return $true
  }
  if ($null -ne $stopCmd) {
    Write-Output 'A foreign Stop hook exists; leaving it alone (turn-chain Stop hook not installed).'
    return $true
  }
  Copy-Item -LiteralPath $settingsPath -Destination "$settingsPath.bak-muse-gate" -Force -ErrorAction SilentlyContinue
  try {
    if ($doc.hooks.Stop) { $doc.hooks.Stop | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([ordered]@{}) -Force }
    else { $doc.hooks | Add-Member -NotePropertyName 'Stop' -NotePropertyValue ([ordered]@{ hooks = ([ordered]@{}) }) -Force }
    $nodeCmd = 'node'
    try {
      $ups = $doc.hooks.UserPromptSubmit.hooks.command
      if ($ups -match '^"([^"]+)"') { $nodeCmd = '"' + $Matches[1] + '"' }
    } catch { $nodeCmd = 'node' }
    $hookFile = Join-Path (Get-ClaudeHooksDir) 'muse-gate.js'
    $doc.hooks.Stop.hooks = [ordered]@{
      type = 'command'
      command = "$nodeCmd `"$hookFile`""
      timeout = 10
      statusMessage = 'Checking turn chain...'
    }
    Write-Utf8NoBom $settingsPath ($doc | ConvertTo-Json -Depth 32)
    $verify = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
    if ($verify.hooks.Stop.hooks.command -notmatch 'muse-gate\.js') { throw 'verification failed' }
  }
  catch {
    Copy-Item -LiteralPath "$settingsPath.bak-muse-gate" -Destination $settingsPath -Force -ErrorAction SilentlyContinue
    Write-Warning 'Turn-chain Stop hook verification failed; settings restored.'
    return $false
  }
  Write-Output 'Turn-chain Stop hook installed (Muse mode only; Claude mode untouched).'
  return $true
}

$srcDir = Join-Path $PSScriptRoot 'src'
foreach ($required in @('muse-mode.ps1', 'muse-mode.cmd', 'muse-claude.cmd', 'key.ps1', 'muse-shim.js', 'muse-gate.js')) {
  if (-not (Test-Path -LiteralPath (Join-Path $srcDir $required))) {
    throw "Repo file missing: $required. Run install.ps1 from the repository root."
  }
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Warning 'Node.js was not found on PATH. Install it before running `muse-mode on`: the schema shim needs node.'
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
  throw 'InstallDir resolved empty. Pass -InstallDir explicitly.'
}
$target = Select-InstallTarget $Target
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $srcDir 'muse-mode.ps1') -Destination (Join-Path $InstallDir 'muse-mode.ps1') -Force
Copy-Item -LiteralPath (Join-Path $srcDir 'muse-mode.cmd') -Destination (Join-Path $InstallDir 'muse-mode.cmd') -Force
Copy-Item -LiteralPath (Join-Path $srcDir 'muse-claude.cmd') -Destination (Join-Path $InstallDir 'muse-claude.cmd') -Force
Copy-Item -LiteralPath (Join-Path $srcDir 'key.ps1') -Destination (Join-Path $InstallDir 'key.ps1') -Force
Copy-Item -LiteralPath (Join-Path $srcDir 'muse-shim.js') -Destination (Join-Path $InstallDir 'muse-shim.js') -Force
Copy-Item -LiteralPath (Join-Path $srcDir 'muse-gate.js') -Destination (Join-Path $InstallDir 'muse-gate.js') -Force

$keyPath = Join-Path $InstallDir 'modelapi-key.dpapi'
if ((Test-Path -LiteralPath $keyPath) -and (-not $Force) -and ($null -eq $ApiKey)) {
  if (Confirm-ReplaceKey) { $ApiKey = Request-ApiKey }
  else { Write-Output 'Keeping the existing stored key.' }
}
elseif ($null -eq $ApiKey) {
  $ApiKey = Request-ApiKey
}

if ($null -ne $ApiKey) {
  if ($ApiKey.Length -eq 0) { throw 'Empty key: nothing was stored.' }
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ApiKey)
  try {
    $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $plainBytes = [Text.Encoding]::Unicode.GetBytes($plainText)
    $protected = [Security.Cryptography.ProtectedData]::Protect(
      $plainBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $hex = -join ($protected | ForEach-Object { $_.ToString('x2') })
    [System.IO.File]::WriteAllText($keyPath, $hex, [Text.Encoding]::ASCII)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $plainText = $null
    $plainBytes = $null
    [GC]::Collect()
  }
  Write-Output "Stored an encrypted key at $keyPath (this Windows user only)."
}

$helperPath = ((Join-Path $InstallDir 'key.ps1') -replace '\\', '/')
# Quote the helper path: install dirs under usernames with spaces break an
# unquoted -File path. Built via ConvertTo-Json so the inner quotes stay valid JSON.
$installSettings = [ordered]@{ apiKeyHelper = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $helperPath + '"' }
Write-Utf8NoBom (Join-Path $InstallDir 'settings.json') ($installSettings | ConvertTo-Json -Depth 8)
Write-Output 'Wrote settings.json with a machine-local apiKeyHelper path.'

if (-not $NoPathUpdate) {
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $entries = @()
  if (-not [string]::IsNullOrWhiteSpace($userPath)) { $entries = $userPath -split ';' | ForEach-Object { $_.Trim() } }
  if ($entries -notcontains $InstallDir) {
    $newPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $InstallDir } else { "$userPath;$InstallDir" }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Output "Added $InstallDir to your user PATH. Open a new terminal to use it."
  }
  else {
    Write-Output 'Install directory is already on your user PATH.'
  }
}

$written = Get-Content -Raw -LiteralPath (Join-Path $InstallDir 'settings.json') | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($written.apiKeyHelper)) { throw 'settings.json verification failed.' }
if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'key.ps1'))) { throw 'key.ps1 missing after install.' }
# Usage pricing (Meta rates): needs one admin write. Non-fatal when declined
# or unavailable (CI/tests set MUSE_TEST_MANAGED_SETTINGS instead): /cost
# keeps fallback pricing, everything else works.
Install-MusePricing | Out-Null
Install-MuseGate | Out-Null
if ($target -eq 'vscode') {
  Install-VSCodeProfile (Join-Path $InstallDir 'muse-claude.cmd')
}
elseif ($target -eq 'other') {
  Write-Output 'Other IDE or editor: launch it from a terminal where `muse-mode status` works,'
  Write-Output "so it inherits your user PATH ($InstallDir). Its Claude Code extension, if any,"
  Write-Output 'reads the same ~/.claude/settings.json that `muse-mode on` manages.'
}
Show-InstallSummary $target
