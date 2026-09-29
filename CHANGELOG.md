# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added

- `muse-mode on | off | status` switcher (Windows PowerShell 5.1 and PowerShell 7+).
- `key.ps1` apiKeyHelper with DPAPI-encrypted local key storage.
- `muse-claude.cmd` one-shot launcher for `claude` on Muse.
- `install.ps1`: key prompt, DPAPI encryption, machine-local settings, user PATH update.
- Pester round-trip tests, PSScriptAnalyzer / gitleaks / actionlint CI.
- `muse-shim.js`: localhost proxy stripping strict-forbidden schema keywords
  (`pattern`, `minLength`, …) so Claude Code 2.1.265+ works on Meta's
  endpoint; wired into `muse-mode on` (start + route), `muse-mode off`
  (stop), `muse-mode shim` (state), and `muse-claude.cmd` (start on demand).
- `muse-mode on -Model <id>`: switch Muse models without leaving Muse
  mode (default `muse-spark-1.3-contributor`); `MUSE_MODEL` overrides one
  `muse-claude.cmd` run.
- Installer target menu (`-Target cli|vscode|other`): VS Code target adds
  a `"Muse"` terminal profile; other IDEs get PATH plus setup notes.
- Installer TUI: ASCII banner with a step overview, a labeled target menu
  (per-choice descriptions, auto-recommended target, words accepted),
  friendly invalid-input reprompts, an instructed API-key prompt with a
  labeled keep/replace choice, and a next-steps summary.
