# Shared loader for the Pester suite. Each Describe dot-sources this file
# from its own BeforeAll, passing install.ps1's path as the argument:
#   . (Join-Path $PSScriptRoot 'Import-InstallerTui.ps1') (Join-Path (Split-Path $PSScriptRoot -Parent) 'install.ps1')
# The loader has no function wrapper on purpose: its top-level code runs in
# the dot-sourcing (BeforeAll) scope, so the definitions land in the
# Describe scope where the It blocks can see them. (A wrapper function
# would trap them in its own scope under Pester 5.) Bodies never execute,
# so nothing here can prompt.
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $args[0], [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "install.ps1 has syntax errors: $($errors.Count)" }
$wanted = @('Get-InstallerBanner', 'Get-TargetMenu', 'Convert-TargetChoice',
  'Get-RecommendedTarget', 'Get-InstallSummary', 'Write-UiLine',
  'Write-Utf8NoBom',
  'Get-MusePricingJson', 'Get-ManagedSettingsPath', 'Install-MusePricing',
  'Get-ClaudeHooksDir', 'Get-ClaudeSettingsPath', 'Install-MuseGate')
$found = $ast.FindAll(
  { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] },
  $true) | Where-Object { $wanted -contains $_.Name }
foreach ($def in $found) {
  # Dot-sourced (not &) so the definitions land in this scope.
  . ([ScriptBlock]::Create($def.Extent.Text)) | Out-Null
}
if ((@($found).Count) -ne $wanted.Count) {
  throw 'A TUI helper is missing from install.ps1.'
}
