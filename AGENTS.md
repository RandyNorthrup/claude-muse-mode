# Agent instructions — claude-muse-mode

Small public repo of Windows install scripts. Keep it boring and safe.

## Hard rules

1. **Windows PowerShell 5.1 compatibility is required.** Bare `muse-mode` in
   5.1 runs `muse-mode.ps1` directly (not via the `.cmd` pwsh launcher). No
   `ConvertFrom-Json -AsHashtable`, no `Set-Content -Encoding utf8NoBOM`, no
   ternary `? :`, no `??`. JSON goes through the helpers in `muse-mode.ps1`;
   file writes use `[IO.File]::WriteAllText` with explicit encodings.
2. **Secrets never enter the repo.** No API keys, no `.dpapi` files, no
   `settings.json` (template only), no `saved-*.json`, no `*.bak-muse-mode`.
   The installer holds the key as SecureString, never prints it, and zeroes
   the BSTR after encryption.
3. **Every command in README.md must have been run successfully.** If a
   command changes, re-run it before committing.
4. **Gates green before release:** PSScriptAnalyzer (`-EnableExit`), Pester,
   `node --check` + `--self-test`, gitleaks, actionlint for workflow changes.
   Run them via `pwsh -NoProfile -File ./gates.ps1` — the same script CI
   runs, with Pester 5.7.1 / PSScriptAnalyzer 1.25.0 pinned, so a local
   green means CI green.
   Tests need node (round-trip starts a shim on a temp port).
5. **Shim discipline:** stdlib only; summary log lines never carry bodies,
   headers, or keys; fixed port 15555 (`MUSE_SHIM_PORT` override); PID and
   log live in the install dir (`MUSE_SHIM_PIDFILE`/`MUSE_SHIM_LOG`
   overrides exist for tests).
6. **Red drills:** a gate counts only after it has been seen to fail. Evidence
   lives in PLAN.md.

## Layout

```
src/        shareable scripts (no machine-local paths, no secrets)
install.ps1 the installer (prompt, encrypt, settings, PATH)
test/       Pester tests; temp settings copy via MUSE_MODE_TEST_SETTINGS
```

## Test conventions

- Never touch the real `~/.claude/settings.json` or the real install dir:
  point `MUSE_MODE_TEST_SETTINGS` at a temp copy and install with
  `-InstallDir <temp> -NoPathUpdate -ApiKey <canary SecureString>`.
- The canary key must be random-shaped and deleted with the temp dir.
