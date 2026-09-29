# Switches Claude Code (CLI and the VS Code panel) between Anthropic and
# Meta's Muse Model API by editing ~/.claude/settings.json. New sessions pick
# the change up; running ones keep what they started with.
#   muse-mode on [-Model <id>]  Muse (Meta's Anthropic-compatible endpoint).
#                               No -Model: per-tier defaults (opus
#                               muse-spark-1.3-contributor, sonnet
#                               muse-spark-1.2-contributor, haiku
#                               muse-spark-1.1). -Model <id>: pin every
#                               tier to that id. Re-run to switch without
#                               leaving Muse mode.
#   muse-mode off     back to Anthropic (your claude.ai login)
#   muse-mode status  which one new sessions will use
#   muse-mode shim    whether the schema shim is running
# Muse traffic goes through the localhost schema shim (muse-shim.js): Meta's
# strict validator rejects tool schemas Claude Code ships (the Artifact
# tool's pattern/min/maxLength), failing every interactive turn with 400.
# The shim strips those keywords and forwards the rest untouched.
# The key never enters settings.json: apiKeyHelper runs key.ps1, which
# decrypts modelapi-key.dpapi (DPAPI, this Windows user only) per request.
param(
  [Parameter(Mandatory)][ValidateSet('on', 'off', 'status', 'shim')][string]$Mode,
  [string]$Model = ''
)
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 has no `ConvertFrom-Json -AsHashtable` and no
# `Set-Content -Encoding utf8NoBOM`, so JSON goes through these helpers and
# works on 5.1 and 7+. Bare `muse-mode` in Windows PowerShell resolves to
# this .ps1 (not the .cmd that launches pwsh), so it must run on both.
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

$settingsPath = Join-Path $HOME '.claude\settings.json'
$savedPath = Join-Path $PSScriptRoot 'saved-anthropic.json'
if ($env:MUSE_MODE_TEST_SETTINGS) {
  # Tests only: work on a copy instead of the real settings.
  $settingsPath = $env:MUSE_MODE_TEST_SETTINGS
  $savedPath = "$env:MUSE_MODE_TEST_SETTINGS.saved"
}
# Per-tier Muse defaults (all five chat-probed 2026-09-29): opus newest,
# sonnet previous-gen contributor, haiku smallest. Distinct ids per tier so
# the model picker shows three different rows instead of one id thrice.
$defaultOpusModel = 'muse-spark-1.3-contributor'
$defaultSonnetModel = 'muse-spark-1.2-contributor'
$defaultHaikuModel = 'muse-spark-1.1'
# Legacy single-model default (the opus tier); status fallback only.
$defaultMuseModel = $defaultOpusModel
$helper = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
  ((Join-Path $PSScriptRoot 'key.ps1') -replace '\\', '/')
# Env keys that carry the model id (everything model-valued; BASE_URL and
# ENABLE_TOOL_SEARCH are set independently).
$modelKeys = @(
  'ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL',
  'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
  'CLAUDE_CODE_SUBAGENT_MODEL'
)
# The model-valued env map. A pinned <id> puts one id on every tier
# (legacy -Model behavior); empty picks per-tier defaults.
function Get-WantedMuseEnv([string]$Pinned) {
  $opus = $defaultOpusModel
  $sonnet = $defaultSonnetModel
  $haiku = $defaultHaikuModel
  if (-not [string]::IsNullOrWhiteSpace($Pinned)) {
    $opus = $Pinned.Trim()
    $sonnet = $opus
    $haiku = $opus
  }
  return [ordered]@{
    ANTHROPIC_MODEL                = $opus
    ANTHROPIC_DEFAULT_OPUS_MODEL   = $opus
    ANTHROPIC_DEFAULT_SONNET_MODEL = $sonnet
    ANTHROPIC_DEFAULT_HAIKU_MODEL  = $haiku
    CLAUDE_CODE_SUBAGENT_MODEL     = $haiku
  }
}
$museEnv = [ordered]@{
  ANTHROPIC_BASE_URL = 'https://api.meta.ai'
  ENABLE_TOOL_SEARCH = 'true'
}
$wantedDefault = Get-WantedMuseEnv ''
foreach ($keyName in $wantedDefault.Keys) { $museEnv[$keyName] = $wantedDefault[$keyName] }

$settings = Read-JsonAsHashtable $settingsPath
$isOn = $settings.apiKeyHelper -eq $helper

function Save-SettingFile {
  $backup = "$settingsPath.bak-muse-mode"
  Copy-Item -LiteralPath $settingsPath -Destination $backup -Force
  Write-Utf8NoBom $settingsPath ($settings | ConvertTo-Json -Depth 32)
}

# Schema shim lifecycle. Port 15555 unless MUSE_SHIM_PORT is set.
function Get-ShimPort {
  if ([string]::IsNullOrWhiteSpace($env:MUSE_SHIM_PORT)) { return '15555' }
  return $env:MUSE_SHIM_PORT
}

function Start-Shim {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param()
  if (-not $PSCmdlet.ShouldProcess('schema shim', 'start')) { return $null }
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { throw 'Node.js was not found on PATH. Muse mode needs node for the schema shim.' }
  $script = Join-Path $PSScriptRoot 'muse-shim.js'
  if (-not (Test-Path -LiteralPath $script)) { throw "Schema shim missing: $script" }
  $out = & $node.Source $script --ensure --port (Get-ShimPort) 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Could not start the schema shim: $out" }
  return ($out | Select-Object -Last 1).ToString().Trim()
}

function Stop-Shim {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param()
  if (-not $PSCmdlet.ShouldProcess('schema shim', 'stop')) { return }
  $node = Get-Command node -ErrorAction SilentlyContinue
  $script = Join-Path $PSScriptRoot 'muse-shim.js'
  if ($node -and (Test-Path -LiteralPath $script)) {
    & $node.Source $script --stop 2>&1 | Out-Null
  }
}

function Get-ShimState {
  $state = 'shim stopped'
  try {
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$(Get-ShimPort)/health" -TimeoutSec 5
    if ($r.status -eq 'ok') { $state = "shim running at http://127.0.0.1:$(Get-ShimPort)/ -> $($r.upstream)" }
  }
  catch { $state = 'shim stopped' }
  return $state
}

function Get-LiveMuseModel {
  if ($isOn -and -not [string]::IsNullOrWhiteSpace($settings.model)) { return $settings.model }
  return $defaultMuseModel
}

switch ($Mode) {
  'status' {
    if ($isOn) {
      $tierOpus = $null
      $tierSonnet = $null
      $tierHaiku = $null
      if ($settings.Contains('env')) {
        $tierOpus = $settings.env['ANTHROPIC_DEFAULT_OPUS_MODEL']
        $tierSonnet = $settings.env['ANTHROPIC_DEFAULT_SONNET_MODEL']
        $tierHaiku = $settings.env['ANTHROPIC_DEFAULT_HAIKU_MODEL']
      }
      if ($tierOpus -and ($tierOpus -eq $tierSonnet) -and ($tierSonnet -eq $tierHaiku)) {
        "Muse ($tierOpus) for new Claude Code sessions"
      }
      elseif ($tierOpus -or $tierSonnet -or $tierHaiku) {
        "Muse (opus $tierOpus, sonnet $tierSonnet, haiku $tierHaiku) for new Claude Code sessions"
      }
      else { "Muse ($(Get-LiveMuseModel)) for new Claude Code sessions" }
    }
    else { 'Anthropic for new Claude Code sessions' }
  }
  'on' {
    $pinned = ''
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $pinned = $Model.Trim() }
    $wantedEnv = Get-WantedMuseEnv $pinned
    $wantedMain = $wantedEnv['ANTHROPIC_MODEL']
    if ($isOn) {
      $same = ($settings.model -eq $wantedMain)
      if ($same) {
        if ($settings.Contains('env')) {
          foreach ($name in $modelKeys) {
            if ($settings.env[$name] -ne $wantedEnv[$name]) { $same = $false; break }
          }
        }
        else { $same = $false }
      }
      if ($same) { 'Already on Muse.'; break }
      # Already on Muse: switch the model-valued keys and settings.model
      # only. The pre-Muse backup stays untouched for `off`.
      if (-not $settings.Contains('env')) { $settings.env = [ordered]@{} }
      foreach ($name in $modelKeys) { $settings.env[$name] = $wantedEnv[$name] }
      $settings.model = $wantedMain
      Save-SettingFile
      if ($pinned -ne '') {
        "Muse model switched to $pinned. Open a new Claude Code session (VS Code: a new Claude tab) to use it."
      }
      else {
        "Muse models switched to per-tier defaults (opus $defaultOpusModel, sonnet $defaultSonnetModel, haiku $defaultHaikuModel). Open a new Claude Code session (VS Code: a new Claude tab) to use them."
      }
      break
    }
    if ($settings.Contains('apiKeyHelper')) {
      throw 'settings.json already has another apiKeyHelper; not changing it.'
    }
    # The shim must be up before anything points at it: fail with settings
    # untouched when node or the shim cannot start.
    $shimUrl = Start-Shim
    if ([string]::IsNullOrWhiteSpace($shimUrl)) { throw 'Schema shim did not return a URL.' }
    $museEnv['ANTHROPIC_BASE_URL'] = $shimUrl
    foreach ($name in $modelKeys) { $museEnv[$name] = $wantedEnv[$name] }
    # What "off" puts back: the model choice and any env values Muse replaces.
    $saved = [ordered]@{ model = $settings.model; env = [ordered]@{} }
    if (-not $settings.Contains('env')) { $settings.env = [ordered]@{} }
    foreach ($name in $museEnv.Keys) {
      if ($settings.env.Contains($name)) { $saved.env[$name] = $settings.env[$name] }
      $settings.env[$name] = $museEnv[$name]
    }
    Write-Utf8NoBom $savedPath ($saved | ConvertTo-Json -Depth 8)
    $settings.model = $wantedMain
    $settings.apiKeyHelper = $helper
    Save-SettingFile
    if ($pinned -ne '') {
      "Muse on. Open a new Claude Code session (VS Code: a new Claude tab) to use $pinned."
    }
    else {
      "Muse on (opus $defaultOpusModel, sonnet $defaultSonnetModel, haiku $defaultHaikuModel). Open a new Claude Code session (VS Code: a new Claude tab)."
    }
  }
  'off' {
    if (-not $isOn) { 'Already on Anthropic.'; break }
    $saved = if (Test-Path $savedPath) { Read-JsonAsHashtable $savedPath } else { @{ env = @{} } }
    foreach ($name in $museEnv.Keys) {
      if ($saved.env -and $saved.env.Contains($name)) { $settings.env[$name] = $saved.env[$name] }
      else { $settings.env.Remove($name) }
    }
    if ($settings.env.Count -eq 0) { $settings.Remove('env') }
    $settings.Remove('apiKeyHelper')
    if ($null -ne $saved.model) { $settings.model = $saved.model } else { $settings.Remove('model') }
    Save-SettingFile
    Remove-Item -LiteralPath $savedPath -ErrorAction SilentlyContinue
    Stop-Shim
    'Anthropic on. Open a new Claude Code session to use it.'
  }
  'shim' {
    Get-ShimState
  }
}
