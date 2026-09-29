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
- Per-tier Muse defaults: bare `muse-mode on` maps opus
  `muse-spark-1.3-contributor`, sonnet `muse-spark-1.2-contributor`, haiku
  `muse-spark-1.1`, fable `muse-spark-1.3` (four distinct live `/v1/models`
  chat ids; all chat-probed live 2026-09-29), with picker
  `NAME`/`DESCRIPTION` labels per tier (honored since CLI 2.1.118) so rows
  show Muse names instead of "Custom <Tier> model", plus the fifth spark
  id (`muse-spark-1.2`) on the picker's custom row
  (`ANTHROPIC_CUSTOM_MODEL_OPTION` + labels). Subagents follow the main
  (opus) model, never the haiku tier. `-Model <id>` still pins every tier
  to one id; `status` reports the tier set including fable;
  `muse-claude.cmd` uses the same mapping unless `MUSE_MODEL` pins it.
- Installer target menu (`-Target cli|vscode|other`): VS Code target adds
  a `"Muse"` terminal profile; other IDEs get PATH plus setup notes.
- Installer TUI: ASCII banner with a step overview, a labeled target menu
  (per-choice descriptions, auto-recommended target, words accepted),
  friendly invalid-input reprompts, an instructed API-key prompt with a
  labeled keep/replace choice, and a next-steps summary.
- Installer writes Muse usage pricing: Meta per-Mtok rates as
  `modelPricing` overrides to
  `C:\Program Files\ClaudeCode\managed-settings.json` (one UAC prompt;
  non-fatal when declined or non-interactive — `/cost` keeps fallback
  pricing). Panel then prices Muse sessions at Meta rates instead of
  "unknown models"; self-toggling (muse-* ids only).
- CI parity: `gates.ps1` runs the full gate set with Pester 5.7.1 /
  PSScriptAnalyzer 1.25.0 pinned, and CI runs that same script — a local
  green means CI green. Suite migrated to Pester 5 (`BeforeAll` setup,
  `Should -Be` assertions, per-Describe loader) after runner images moved
  off Pester 3.4-era scoping and every CI run went red while local stayed
  green.
- Turn-chain reminder (`muse-gate.js`, `Install-MuseGate`): the installer
  points the `UserPromptSubmit` hook at a dispatcher that runs the previous
  tracker, then appends "finish the turn chain" context only while Muse
  mode is on (key helper + `saved-anthropic.json` check); Claude-mode
  prompts pass through untouched. Unknown hook shapes are left alone
  loudly; `node muse-gate.js --self-test` covers the merge table.

### Fixed

- `muse-shim.js`: re-declare Content-Length after stripping/re-serializing
  the request body. The old code forwarded the client's original (longer)
  length with the shortened body, so the upstream waited for bytes that
  never came and every tool-carrying request hung until the client timed
  out (~6 min) and retried. `--self-test` now includes a localhost relay
  test pinning declared-vs-received lengths.
- `muse-shim.js`: drop `max_uses` from tool definitions as defense (Meta
  named the field in a web-search 400; the log shows it never arrives on
  definitions, so live search failures are executor-side). The shim now
  also logs the upstream status and round-trip time per request, so
  endpoint errors are visible without touching bodies.
- `muse-shim.js`: drop the web-search tool from definitions (Meta's
  executor 400s then returns empty results; the model falls through to
  WebFetch). Restorable with `MUSE_SHIM_KEEP_WEB_SEARCH=1`. Request log
  lines now include top-level param names (never values) for diagnosis.
- `muse-shim.js`: drop the `thinking` request param (Meta answers with
  redacted blocks the client renders as `Unsupported content type`
  noise). Restorable with `MUSE_SHIM_KEEP_THINKING=1`.
- `muse-shim.js`: filter thinking/redacted_thinking blocks out of
  responses (Meta emits them even unprompted). SSE stays streaming;
  JSON bodies are re-packed with corrected lengths. Fail-open: anything
  unrecognized passes through untouched.
