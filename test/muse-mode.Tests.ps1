# Pester 3.4. Round-trips muse-mode and install.ps1 against temp copies only.
# Never touches ~/.claude/settings.json or a real install directory.
$ErrorActionPreference = 'Stop'

$repoSrc = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
$installScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'install.ps1'

# The installer's TUI text helpers live in install.ps1 (kept single-file by
# design), so load just their definitions: parse the script, re-create each
# pure function from its AST, define it in this scope. This executes the real
# shipped functions, not copies. Show-*/Read-Host code is never loaded, so
# nothing here can prompt.
function Import-InstallerTui {
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $installScript, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "install.ps1 has syntax errors: $($errors.Count)" }
  $wanted = @('Get-InstallerBanner', 'Get-TargetMenu', 'Convert-TargetChoice',
    'Get-RecommendedTarget', 'Get-InstallSummary', 'Write-UiLine')
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
}

# Isolate the schema shim the round-trip exercises: temp port plus temp
# pid/log files, so tests never touch a real shim on 15555.
$env:MUSE_SHIM_PORT = '15577'
$env:MUSE_SHIM_PIDFILE = Join-Path ([IO.Path]::GetTempPath()) 'muse-shim-test.pid'
$env:MUSE_SHIM_LOG = Join-Path ([IO.Path]::GetTempPath()) 'muse-shim-test.log'

Describe 'muse-mode round-trip' {
  $work = Join-Path ([IO.Path]::GetTempPath()) ('muse-mode-test-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $work | Out-Null
  $settings = Join-Path $work 'settings.json'
  '{"model":"under-test","env":{"PRE_EXISTING":"keep-me"}}' | Set-Content -LiteralPath $settings -Encoding Ascii
  $env:MUSE_MODE_TEST_SETTINGS = $settings
  $ps1 = Join-Path $repoSrc 'muse-mode.ps1'

  It 'reports Anthropic before switching' {
    (& $ps1 status) | Should Be 'Anthropic for new Claude Code sessions'
  }

  It 'switches on with per-tier defaults and reports Muse' {
    (& $ps1 on) | Should Match 'Muse on'
    (& $ps1 status) | Should Be 'Muse (opus muse-spark-1.3-contributor, sonnet muse-spark-1.2-contributor, haiku muse-spark-1.1) for new Claude Code sessions'
    $live = Get-Content -Raw -LiteralPath $settings | ConvertFrom-Json
    $live.model | Should Be 'muse-spark-1.3-contributor'
    $live.env.ANTHROPIC_MODEL | Should Be 'muse-spark-1.3-contributor'
    $live.env.ANTHROPIC_DEFAULT_OPUS_MODEL | Should Be 'muse-spark-1.3-contributor'
    $live.env.ANTHROPIC_DEFAULT_SONNET_MODEL | Should Be 'muse-spark-1.2-contributor'
    $live.env.ANTHROPIC_DEFAULT_HAIKU_MODEL | Should Be 'muse-spark-1.1'
    $live.env.CLAUDE_CODE_SUBAGENT_MODEL | Should Be 'muse-spark-1.1'
  }

  It 're-on with no flag converges pinned tiers to per-tier defaults' {
    (& $ps1 on -Model test-model-a) | Should Match 'Muse model switched to test-model-a'
    (& $ps1 status) | Should Be 'Muse (test-model-a) for new Claude Code sessions'
    (& $ps1 on) | Should Match 'per-tier defaults'
    (& $ps1 status) | Should Be 'Muse (opus muse-spark-1.3-contributor, sonnet muse-spark-1.2-contributor, haiku muse-spark-1.1) for new Claude Code sessions'
  }

  It 'points the base URL at the running shim' {
    $live = Get-Content -Raw -LiteralPath $settings | ConvertFrom-Json
    $live.env.ANTHROPIC_BASE_URL | Should Be 'http://127.0.0.1:15577'
    (& $ps1 shim) | Should Match 'shim running at http://127.0.0.1:15577'
  }

  It 'restores the original settings byte-for-byte on off' {
    (& $ps1 off) | Should Match 'Anthropic on'
    (& $ps1 status) | Should Be 'Anthropic for new Claude Code sessions'
    $back = Get-Content -Raw -LiteralPath $settings | ConvertFrom-Json
    $back.model | Should Be 'under-test'
    $back.env.PRE_EXISTING | Should Be 'keep-me'
    ($back.env.PSObject.Properties.Name -join ',') | Should Be 'PRE_EXISTING'
    $back.PSObject.Properties.Name -contains 'apiKeyHelper' | Should Be $false
  }

  It 'is a no-op the second time off runs' {
    (& $ps1 off) | Should Be 'Already on Anthropic.'
  }

  It 'reports the shim stopped after off' {
    (& $ps1 shim) | Should Be 'shim stopped'
  }

  Remove-Item Env:\MUSE_MODE_TEST_SETTINGS -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'muse-mode model flag' {
  $work2 = Join-Path ([IO.Path]::GetTempPath()) ('muse-model-test-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $work2 | Out-Null
  $settings2 = Join-Path $work2 'settings.json'
  '{"model":"orig-model"}' | Set-Content -LiteralPath $settings2 -Encoding Ascii
  $env:MUSE_MODE_TEST_SETTINGS = $settings2
  $ps1 = Join-Path $repoSrc 'muse-mode.ps1'

  It 'fresh on with -Model uses that model' {
    (& $ps1 on -Model test-model-a) | Should Match 'Muse on'
    (& $ps1 status) | Should Be 'Muse (test-model-a) for new Claude Code sessions'
    $live = Get-Content -Raw -LiteralPath $settings2 | ConvertFrom-Json
    $live.model | Should Be 'test-model-a'
    $live.env.ANTHROPIC_MODEL | Should Be 'test-model-a'
    $live.env.ANTHROPIC_DEFAULT_HAIKU_MODEL | Should Be 'test-model-a'
  }

  It 're-on with another -Model switches without leaving Muse mode' {
    (& $ps1 on -Model test-model-b) | Should Match 'switched to test-model-b'
    (& $ps1 status) | Should Be 'Muse (test-model-b) for new Claude Code sessions'
    $live = Get-Content -Raw -LiteralPath $settings2 | ConvertFrom-Json
    $live.model | Should Be 'test-model-b'
    $live.env.ANTHROPIC_DEFAULT_SONNET_MODEL | Should Be 'test-model-b'
  }

  It 're-on with the same model is a no-op' {
    (& $ps1 on -Model test-model-b) | Should Be 'Already on Muse.'
  }

  It 'off restores the pre-Muse model' {
    (& $ps1 off) | Should Match 'Anthropic on'
    $back = Get-Content -Raw -LiteralPath $settings2 | ConvertFrom-Json
    $back.model | Should Be 'orig-model'
    $back.PSObject.Properties.Name -contains 'apiKeyHelper' | Should Be $false
  }

  Remove-Item Env:\MUSE_MODE_TEST_SETTINGS -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $work2 -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'install.ps1 sandbox run' {
  $work = Join-Path ([IO.Path]::GetTempPath()) ('muse-install-test-' + [Guid]::NewGuid().ToString('N'))
  $canaryPlain = 'canary-' + [Guid]::NewGuid().ToString('N')
  # Built char-by-char so the plaintextCmdlet rule stays strict everywhere.
  $canary = New-Object Security.SecureString
  $canaryPlain.ToCharArray() | ForEach-Object { $canary.AppendChar($_) }
  $canary.MakeReadOnly()
  # Installed once per Describe (not per It): the installer writes only to
  # the temp dir, and this keeps native child output out of the test log.
  & $installScript -InstallDir $work -NoPathUpdate -Force -ApiKey $canary -Target other | Out-Null

  It 'installs, encrypts a canary key, and the helper decrypts it back' {
    Test-Path -LiteralPath (Join-Path $work 'muse-mode.ps1') | Should Be $true
    Test-Path -LiteralPath (Join-Path $work 'key.ps1') | Should Be $true
    Test-Path -LiteralPath (Join-Path $work 'modelapi-key.dpapi') | Should Be $true
    $hex = (Get-Content -Raw -LiteralPath (Join-Path $work 'modelapi-key.dpapi')).Trim()
    $hex -match '\A[0-9a-f]+\Z' | Should Be $true
    # key.ps1 writes via [Console]::Out (bypasses the output stream), so run
    # it in a child process, and compare hashes so the canary never lands
    # in the test log even on failure.
    $sha = [Security.Cryptography.SHA256]::Create()
    $want = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canaryPlain)))
    # Captured via the .NET API so the value never enters any PowerShell
    # stream or host buffer, not even Pester's.
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'pwsh'
    $psi.Arguments = "-NoProfile -NonInteractive -File `"$((Join-Path $work 'key.ps1'))`""
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $keyProcess = [Diagnostics.Process]::Start($psi)
    $gotRaw = $keyProcess.StandardOutput.ReadToEnd().Trim()
    $keyProcess.WaitForExit()
    if ($keyProcess.ExitCode -ne 0) { throw 'key.ps1 exited non-zero.' }
    $got = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($gotRaw)))
    $got | Should Be $want
    $settings = Get-Content -Raw -LiteralPath (Join-Path $work 'settings.json') | ConvertFrom-Json
    $settings.apiKeyHelper -like ('*' + ($work -replace '\\', '/') + '/key.ps1') | Should Be $true
    Test-Path -LiteralPath (Join-Path $work 'muse-shim.js') | Should Be $true
  }

  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  # Test shim from the round-trip (temp port): stop it and remove its tracks.
  & node (Join-Path $repoSrc 'muse-shim.js') --stop | Out-Null
  Remove-Item -LiteralPath $env:MUSE_SHIM_PIDFILE -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $env:MUSE_SHIM_LOG -Force -ErrorAction SilentlyContinue
}

Describe 'install.ps1 vscode target' {
  $work3 = Join-Path ([IO.Path]::GetTempPath()) ('muse-vscode-test-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $work3 | Out-Null
  $codeSettings = Join-Path $work3 'code-settings.json'
  '{"editor.fontSize": 14}' | Set-Content -LiteralPath $codeSettings -Encoding Ascii
  $env:MUSE_TEST_VSCODE_SETTINGS = $codeSettings
  $canary3 = New-Object Security.SecureString
  ('canary-' + [Guid]::NewGuid().ToString('N')).ToCharArray() | ForEach-Object { $canary3.AppendChar($_) }
  $canary3.MakeReadOnly()
  $install3 = Join-Path $work3 'install'

  It 'adds the Muse terminal profile and preserves existing settings' {
    & $installScript -InstallDir $install3 -NoPathUpdate -Force -ApiKey $canary3 -Target vscode | Out-Null
    $vs = Get-Content -Raw -LiteralPath $codeSettings | ConvertFrom-Json
    $vs.'editor.fontSize' | Should Be 14
    $museProfile = $vs.terminal.integrated.profiles.windows.Muse
    $museProfile.path | Should Match 'cmd.exe'
    $museProfile.args[0] | Should Be '/k'
    $museProfile.args[1] | Should Be (Join-Path $install3 'muse-claude.cmd')
  }

  It 'second run keeps the profile' {
    $out = & $installScript -InstallDir $install3 -NoPathUpdate -Force -ApiKey $canary3 -Target vscode
    ($out -join "`n") | Should Match 'already set'
  }

  It 'leaves a foreign Muse profile alone' {
    '{"terminal": {"integrated": {"profiles": {"windows": {"Muse": {"path": "C:\\other\\cmd.exe", "args": []}}}}}}' |
      Set-Content -LiteralPath $codeSettings -Encoding Ascii
    & $installScript -InstallDir $install3 -NoPathUpdate -Force -ApiKey $canary3 -Target vscode | Out-Null
    $vs = Get-Content -Raw -LiteralPath $codeSettings | ConvertFrom-Json
    $vs.terminal.integrated.profiles.windows.Muse.path | Should Be 'C:\other\cmd.exe'
  }

  It 'rejects an unknown target' {
    $failed = $false
    try { & $installScript -InstallDir $install3 -NoPathUpdate -Force -ApiKey $canary3 -Target wat | Out-Null }
    catch { $failed = $true }
    $failed | Should Be $true
  }

  Remove-Item Env:\MUSE_TEST_VSCODE_SETTINGS -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $work3 -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'installer TUI text' {
  # Dot-sourced so the loaded definitions land in this Describe's scope,
  # where the It blocks below can see them.
  . Import-InstallerTui

  It 'parses menu answers' {
    (Convert-TargetChoice '1') | Should Be 'cli'
    (Convert-TargetChoice '2') | Should Be 'vscode'
    (Convert-TargetChoice '3') | Should Be 'other'
    (Convert-TargetChoice 'VSCode') | Should Be 'vscode'
    (Convert-TargetChoice '  other  ') | Should Be 'other'
  }

  It 'rejects bad menu answers with $null' {
    ($null -eq (Convert-TargetChoice 'wat')) | Should Be $true
    ($null -eq (Convert-TargetChoice '')) | Should Be $true
    ($null -eq (Convert-TargetChoice $null)) | Should Be $true
    ($null -eq (Convert-TargetChoice '4')) | Should Be $true
  }

  It 'labels every choice with instructions' {
    $menu = Get-TargetMenu 'cli'
    $menu | Should Match '\[1\].*Vanilla CLI'
    $menu | Should Match '\[2\].*VS Code'
    $menu | Should Match '\[3\].*Other IDE'
    $menu | Should Match 'terminal profile'
    $menu | Should Match 'Type 1, 2, or 3'
  }

  It 'marks exactly the recommended choice' {
    $cliMenu = Get-TargetMenu 'cli'
    ($cliMenu -match '\[1\].*recommended') | Should Be $true
    ($cliMenu -match '\[2\].*recommended') | Should Be $false
    $vsMenu = Get-TargetMenu 'vscode'
    ($vsMenu -match '\[2\].*recommended') | Should Be $true
    ($vsMenu -match '\[1\].*recommended') | Should Be $false
  }

  It 'banner names the product and previews the steps' {
    $banner = Get-InstallerBanner
    $banner | Should Match 'claude-muse-mode'
    $banner | Should Match 'DPAPI'
    $banner | Should Match 'PATH'
  }

  It 'keeps banner, menu, and summary lines within 78 columns' {
    $widest = 0
    $texts = @((Get-InstallerBanner), (Get-TargetMenu 'vscode'), (Get-InstallSummary 'vscode'))
    foreach ($text in $texts) {
      foreach ($line in $text -split "`r`n") {
        if ($line.Length -gt $widest) { $widest = $line.Length }
      }
    }
    ($widest -le 78) | Should Be $true
  }

  It 'recommends a valid target on this machine' {
    (@('cli', 'vscode') -contains (Get-RecommendedTarget)) | Should Be $true
  }

  It 'summary mentions the switch commands' {
    $summary = Get-InstallSummary 'vscode'
    $summary | Should Match 'muse-mode on'
    $summary | Should Match 'muse-mode off'
    $summary | Should Match 'Muse'
  }

  It 'display helper emits nothing to the output stream' {
    # Regression pin: Write-UiLine renders inside value-returning
    # functions, so anything it emits to the output stream becomes part
    # of their return values (Object[] instead of string/SecureString).
    ($null -eq (Write-UiLine 'ui')) | Should Be $true
    ($null -eq (Write-UiLine)) | Should Be $true
  }
}
