# gates.ps1 - the full verification gate set. CI (.github/workflows/ci.yml)
# runs this exact script, so a local green means CI green.
#   pwsh -NoProfile -File ./gates.ps1           # missing optional tools warn and skip
#   pwsh -NoProfile -File ./gates.ps1 -Strict   # CI mode: missing tools fail instead
param([switch]$Strict)

$ErrorActionPreference = 'Stop'
$pesterPinned = '5.7.1'
$pssaPinned = '1.25.0'

function Install-PinnedModule([string]$Name, [string]$Version) {
  $found = Get-Module -ListAvailable -Name $Name | Where-Object { [string]$_.Version -eq $Version }
  if ($null -eq $found) {
    Write-Output "$Name $Version not installed; installing for the current user."
    Install-Module -Name $Name -RequiredVersion $Version -Force -Scope CurrentUser -SkipPublisherCheck
  }
  Import-Module -Name $Name -RequiredVersion $Version -Force
  Write-Output "$Name $((Get-Module -Name $Name).Version) ready."
}

function Invoke-Native([string]$File, [string]$Arguments, [string]$Label) {
  $proc = Start-Process -FilePath $File -ArgumentList $Arguments -NoNewWindow -Wait -PassThru
  if ($proc.ExitCode -ne 0) { throw "$Label failed with exit $($proc.ExitCode)." }
}

function Test-ToolPresent([string]$Name) {
  if (Get-Command $Name -ErrorAction SilentlyContinue) { return $true }
  if ($Strict) { throw "Required tool missing under -Strict: $Name." }
  Write-Warning "Skipping: $Name not found on PATH."
  return $false
}

if ($Strict) { Write-Output 'Strict mode: missing optional tools fail the run.' }
Install-PinnedModule 'PSScriptAnalyzer' $pssaPinned
Install-PinnedModule 'Pester' $pesterPinned

Invoke-ScriptAnalyzer -Path . -Recurse -EnableExit -Settings ./PSScriptAnalyzerSettings.psd1 -ErrorAction Stop
Write-Output 'LINT-CLEAN'

Invoke-Pester ./test -EnableExit

Invoke-Native -File 'node' -Arguments '--check src/muse-shim.js' -Label 'node --check (shim)'
Invoke-Native -File 'node' -Arguments '--check src/muse-gate.js' -Label 'node --check (gate)'
Invoke-Native -File 'node' -Arguments 'src/muse-shim.js --self-test' -Label 'shim self-test'
Invoke-Native -File 'node' -Arguments 'src/muse-gate.js --self-test' -Label 'gate self-test'

if (Test-ToolPresent 'gitleaks') {
  Invoke-Native -File 'gitleaks' -Arguments 'detect --source . --no-git' -Label 'gitleaks'
}
if (Test-ToolPresent 'actionlint') {
  Invoke-Native -File 'actionlint' -Arguments '.github/workflows/ci.yml' -Label 'actionlint'
}

Write-Output 'GATES-GREEN'
