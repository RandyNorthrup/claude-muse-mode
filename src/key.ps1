# apiKeyHelper for muse-mode: prints the Meta Model API key for Claude
# Code's model requests. The key is stored DPAPI-encrypted for this Windows
# user only (modelapi-key.dpapi, a ProtectedData hex export written by
# install.ps1) and is never written anywhere in clear. Decrypted with .NET
# directly: Windows PowerShell started from PowerShell 7 inherits a module
# path that cannot load ConvertTo-SecureString.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$hex = (Get-Content -Raw (Join-Path $PSScriptRoot 'modelapi-key.dpapi')).Trim()
$protected = [byte[]]::new($hex.Length / 2)
for ($i = 0; $i -lt $protected.Length; $i++) {
  $protected[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16)
}
$plain = [Security.Cryptography.ProtectedData]::Unprotect(
  $protected, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
[Console]::Out.Write([Text.Encoding]::Unicode.GetString($plain))
