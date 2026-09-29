# Switches Claude Code (CLI and the VS Code panel) between Anthropic and
# Meta's Muse Model API by editing ~/.claude/settings.json. New sessions pick
# the change up; running ones keep what they started with.
#   muse-mode on [-Model <id>]  Muse (Meta's Anthropic-compatible endpoint).
#                               No -Model: per-tier defaults (opus
#                               muse-spark-1.3-contributor, sonnet
#                               muse-spark-1.2-contributor, haiku
#                               muse-spark-1.1, fable muse-spark-1.3 -
#                               four distinct live ids) plus picker
#                               NAME/DESCRIPTION labels so rows show Muse
#                               names instead of "Custom <Tier> model",
#                               plus a labeled custom row for the fifth
#                               spark id (muse-spark-1.2).
#                               -Model <id>: pin every tier to that id.
#                               Re-run to switch without leaving Muse mode.
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
# Per-tier Muse defaults (live /v1/models 2026-09-29 lists 8 ids; the 5
# spark chat-probed, the other 3 are image/voice/sam). Four tiers take four
# distinct chat ids so no two picker rows share one: opus newest
# contributor, sonnet previous-gen contributor, haiku smallest, fable
# newest standard (most-capable tier). The fifth spark id rides the
# picker's single custom row (ANTHROPIC_CUSTOM_MODEL_OPTION), so every
# live chat model is one picker pick away.
$defaultOpusModel = 'muse-spark-1.3-contributor'
$defaultSonnetModel = 'muse-spark-1.2-contributor'
$defaultHaikuModel = 'muse-spark-1.1'
$defaultFableModel = 'muse-spark-1.3'
$defaultSpareModel = 'muse-spark-1.2'
# Picker labels: without NAME/DESCRIPTION the /model picker falls back to
# the raw id plus "Custom <Tier> model", and the unpinned Fable tier leaks
# the built-in Anthropic Fable row into Muse sessions. Honored since CLI
# 2.1.118; ignored by older CLIs. SUPPORTED_CAPABILITIES skipped on
# purpose: it has no effect behind ANTHROPIC_BASE_URL gateways (only on
# Bedrock/Vertex/Foundry).
$defaultOpusName = 'Muse Spark 1.3 Contributor'
$defaultOpusDescription = 'Newest Muse model, contributor tier'
$defaultSonnetName = 'Muse Spark 1.2 Contributor'
$defaultSonnetDescription = 'Balanced Muse model, contributor tier'
$defaultHaikuName = 'Muse Spark 1.1'
$defaultHaikuDescription = 'Fast Muse model for quick tasks'
$defaultFableName = 'Muse Spark 1.3'
$defaultFableDescription = 'Most-capable Muse tier for hardest, longest-running tasks'
$defaultSpareName = 'Muse Spark 1.2'
$defaultSpareDescription = 'Standard Muse model, previous generation'
# Legacy single-model default (the opus tier); status fallback only.
$defaultMuseModel = $defaultOpusModel
$helper = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
  ((Join-Path $PSScriptRoot 'key.ps1') -replace '\\', '/')
# Env keys that carry the model id (everything model-valued; BASE_URL and
# ENABLE_TOOL_SEARCH are set independently).
$modelKeys = @(
  'ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL',
  'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
  'ANTHROPIC_DEFAULT_FABLE_MODEL',
  'ANTHROPIC_DEFAULT_OPUS_MODEL_NAME', 'ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION',
  'ANTHROPIC_DEFAULT_SONNET_MODEL_NAME', 'ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION',
  'ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME', 'ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION',
  'ANTHROPIC_DEFAULT_FABLE_MODEL_NAME', 'ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION',
  'ANTHROPIC_CUSTOM_MODEL_OPTION', 'ANTHROPIC_CUSTOM_MODEL_OPTION_NAME',
  'ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION',
  'CLAUDE_CODE_SUBAGENT_MODEL'
)
# The model-valued env map. A pinned <id> puts one id on every tier
# (legacy -Model behavior, picker titles fall back to the id itself);
# empty picks per-tier defaults with Muse picker labels.
function Get-WantedMuseEnv([string]$Pinned) {
  $opus = $defaultOpusModel
  $sonnet = $defaultSonnetModel
  $haiku = $defaultHaikuModel
  $fable = $defaultFableModel
  $spare = $defaultSpareModel
  $opusName = $defaultOpusName
  $opusDescription = $defaultOpusDescription
  $sonnetName = $defaultSonnetName
  $sonnetDescription = $defaultSonnetDescription
  $haikuName = $defaultHaikuName
  $haikuDescription = $defaultHaikuDescription
  $fableName = $defaultFableName
  $fableDescription = $defaultFableDescription
  $spareName = $defaultSpareName
  $spareDescription = $defaultSpareDescription
  if (-not [string]::IsNullOrWhiteSpace($Pinned)) {
    $opus = $Pinned.Trim()
    $sonnet = $opus
    $haiku = $opus
    $fable = $opus
    $spare = $opus
    $opusName = $opus
    $sonnetName = $opus
    $haikuName = $opus
    $fableName = $opus
    $spareName = $opus
    $opusDescription = 'Pinned Muse model (muse-mode -Model)'
    $sonnetDescription = $opusDescription
    $haikuDescription = $opusDescription
    $fableDescription = $opusDescription
    $spareDescription = $opusDescription
  }
  return [ordered]@{
    ANTHROPIC_MODEL = $opus
    ANTHROPIC_DEFAULT_OPUS_MODEL = $opus
    ANTHROPIC_DEFAULT_SONNET_MODEL = $sonnet
    ANTHROPIC_DEFAULT_HAIKU_MODEL = $haiku
    ANTHROPIC_DEFAULT_FABLE_MODEL = $fable
    ANTHROPIC_DEFAULT_OPUS_MODEL_NAME = $opusName
    ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION = $opusDescription
    ANTHROPIC_DEFAULT_SONNET_MODEL_NAME = $sonnetName
    ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION = $sonnetDescription
    ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME = $haikuName
    ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION = $haikuDescription
    ANTHROPIC_DEFAULT_FABLE_MODEL_NAME = $fableName
    ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION = $fableDescription
    ANTHROPIC_CUSTOM_MODEL_OPTION = $spare
    ANTHROPIC_CUSTOM_MODEL_OPTION_NAME = $spareName
    ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION = $spareDescription
    # Subagents follow the main (opus) model, never the haiku tier: picking
    # Default (currently <opus>) must not leak 1.1 traffic underneath.
    CLAUDE_CODE_SUBAGENT_MODEL = $opus
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
      $tierFable = $null
      if ($settings.Contains('env')) {
        $tierOpus = $settings.env['ANTHROPIC_DEFAULT_OPUS_MODEL']
        $tierSonnet = $settings.env['ANTHROPIC_DEFAULT_SONNET_MODEL']
        $tierHaiku = $settings.env['ANTHROPIC_DEFAULT_HAIKU_MODEL']
        $tierFable = $settings.env['ANTHROPIC_DEFAULT_FABLE_MODEL']
      }
      if ($tierOpus -and ($tierOpus -eq $tierSonnet) -and ($tierSonnet -eq $tierHaiku) -and ($tierHaiku -eq $tierFable)) {
        "Muse ($tierOpus) for new Claude Code sessions"
      }
      elseif ($tierOpus -or $tierSonnet -or $tierHaiku -or $tierFable) {
        "Muse (opus $tierOpus, sonnet $tierSonnet, haiku $tierHaiku, fable $tierFable) for new Claude Code sessions"
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
        "Muse models switched to per-tier defaults (opus $defaultOpusModel, sonnet $defaultSonnetModel, haiku $defaultHaikuModel, fable $defaultFableModel). Open a new Claude Code session (VS Code: a new Claude tab) to use them."
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
      "Muse on (opus $defaultOpusModel, sonnet $defaultSonnetModel, haiku $defaultHaikuModel, fable $defaultFableModel). Open a new Claude Code session (VS Code: a new Claude tab)."
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
