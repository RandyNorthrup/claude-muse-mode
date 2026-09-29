<#
.SYNOPSIS
  Installs claude-muse-mode: Claude Code on Meta's Muse Model API.
.DESCRIPTION
  Copies the launcher scripts to an install directory (default
  %LOCALAPPDATA%\claude-muse-mode), writes a machine-local settings.json
  whose apiKeyHelper points at the installed key.ps1, DPAPI-encrypts the
  Meta Model API key you paste into modelapi-key.dpapi (this Windows user
  only), and adds the install directory to your user PATH so plain
  `muse-mode on | off | status` works in any terminal.

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

function Select-InstallTarget([string]$Choice) {
  $valid = @('cli', 'vscode', 'other')
  if (-not [string]::IsNullOrWhiteSpace($Choice)) {
    if ($valid -contains $Choice.Trim().ToLower()) { return $Choice.Trim().ToLower() }
    throw "Unknown -Target '$Choice'. Use cli, vscode, or other."
  }
  if (-not [Environment]::UserInteractive) {
    throw 'Non-interactive install must pass -Target (cli, vscode, or other).'
  }
  Write-Output 'Where should the Muse tools point?'
  Write-Output '  [1] Vanilla CLI - user PATH, works in any terminal'
  Write-Output '  [2] VS Code - PATH plus a "Muse" terminal profile'
  Write-Output '  [3] Other IDE or editor - PATH plus manual setup notes'
  for ($i = 0; $i -lt 3; $i++) {
    $answer = Read-Host 'Choose [1/2/3]'
    if ($answer -eq '1') { return 'cli' }
    if ($answer -eq '2') { return 'vscode' }
    if ($answer -eq '3') { return 'other' }
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

$srcDir = Join-Path $PSScriptRoot 'src'
foreach ($required in @('muse-mode.ps1', 'muse-mode.cmd', 'muse-claude.cmd', 'key.ps1', 'muse-shim.js')) {
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

$keyPath = Join-Path $InstallDir 'modelapi-key.dpapi'
if ((Test-Path -LiteralPath $keyPath) -and (-not $Force) -and ($null -eq $ApiKey)) {
  $answer = Read-Host 'A stored key already exists. Replace it? [y/N]'
  if ($answer -ne 'y') {
    Write-Output 'Keeping the existing stored key.'
  }
  else {
    $ApiKey = Read-Host 'Paste your Meta Model API key' -AsSecureString
  }
}
elseif ($null -eq $ApiKey) {
  $ApiKey = Read-Host 'Paste your Meta Model API key' -AsSecureString
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
$settingsJson = "{`r`n  `"apiKeyHelper`": `"powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helperPath`"`r`n}`r`n"
[System.IO.File]::WriteAllText(
  (Join-Path $InstallDir 'settings.json'), $settingsJson, (New-Object System.Text.UTF8Encoding $false))
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
if ($target -eq 'vscode') {
  Install-VSCodeProfile (Join-Path $InstallDir 'muse-claude.cmd')
}
elseif ($target -eq 'other') {
  Write-Output 'Other IDE or editor: launch it from a terminal where `muse-mode status` works,'
  Write-Output "so it inherits your user PATH ($InstallDir). Its Claude Code extension, if any,"
  Write-Output 'reads the same ~/.claude/settings.json that `muse-mode on` manages.'
}
Write-Output 'Done. Open a new terminal, then switch with: muse-mode on  (back with: muse-mode off)'
