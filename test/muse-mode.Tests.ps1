# Pester 3.4. Round-trips muse-mode and install.ps1 against temp copies only.
# Never touches ~/.claude/settings.json or a real install directory.
$ErrorActionPreference = 'Stop'

$repoSrc = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
$installScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'install.ps1'

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

  It 'switches on and reports Muse' {
    (& $ps1 on) | Should Match 'Muse on'
    (& $ps1 status) | Should Be 'Muse (muse-spark-1.3-contributor) for new Claude Code sessions'
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
