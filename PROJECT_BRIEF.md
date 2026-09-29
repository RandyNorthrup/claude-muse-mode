# Project brief — claude-muse-mode

| Field | Value |
|---|---|
| Status | Confirmed |
| Product owner | Randy Northrup |
| Technical owner | Randy Northrup |
| Last confirmed | 2026-09-29 |
| Decision authority | Randy Northrup |

## Executive contract

- **Problem:** Running Claude Code against Meta's Muse Model API takes hand-wired env vars, a key helper, and settings edits. Repeating that setup on every machine is error-prone, and there is no one-command switch back to Anthropic.
- **Why now:** The setup is proven on the owner's machine; packaging it lets other users adopt it.
- **First useful release:** Public GitHub repo with the mode switcher, key helper, launcher, and an install script that prompts for the API key, DPAPI-encrypts it locally, writes machine-local settings, and adds itself to the user PATH.
- **Success measures:** A fresh Windows 10/11 machine goes from clone to `muse-mode on` with no manual JSON editing; `muse-mode off` restores prior settings byte-for-byte (verified by round-trip test).
- **Non-goals:** macOS/Linux support (later); managing Claude Code itself; guarding the user's Anthropic login; a GUI.
- **Failure conditions:** An installer that leaks the key (log, error, wrong file) or cannot restore pre-existing settings.

## People

- Primary users: Windows Claude Code users with a Meta Model API key.
- Excluded users: macOS/Linux users (until ported).
- Accessibility/language/device needs: N/A — CLI only, English output.
- Owners (product, engineering, security, release): Randy Northrup.
- Approvers/external stakeholders: none.

## Scope and journeys

- Critical journeys: (1) install → paste key → `muse-mode on` → new Claude session uses Muse; (2) `muse-mode off` → back to Anthropic; (3) `muse-mode status` reports which.
- Must-have: `muse-mode on|off|status` on Windows PowerShell 5.1 and 7+; `key.ps1` apiKeyHelper with DPAPI key; `muse-claude.cmd` one-shot launcher; `install.ps1` (prompt, encrypt, settings, PATH); uninstall documented; schema shim (`muse-shim.js`) piggybacked on those surfaces — `on` ensures/routes, `off` stops, `muse-claude.cmd` ensures on demand, install ships it (D7); `on -Model <id>` pins every tier to one id; bare `on` uses per-tier defaults (opus muse-spark-1.3-contributor, sonnet muse-spark-1.2-contributor, haiku muse-spark-1.1, fable muse-spark-1.3, spare muse-spark-1.2 on the custom row — all five live spark chat ids 2026-09-29) with picker NAME/DESCRIPTION labels and subagents following opus (D15); installer target menu incl. VS Code terminal profile (D8); turn-chain reminder installs mode-gated (D17).
- Later: portable (non-Windows) key storage and switcher.
- Inputs/outputs: Meta Model API key in (SecureString, never persisted in clear); DPAPI hex file and settings.json out (machine-local, gitignored).
- Offline/degraded: N/A — installer needs no network; model calls need the network.
- Migration/compatibility: installer never touches `~/.claude/settings.json`; `muse-mode on` backs up replaced model/env values and `off` restores them.
- Requirement IDs preserved: installer-prompt key flow, 5.1 compatibility, PATH update.

## Experience and brand

- Product name: claude-muse-mode. Voice: terse CLI output.
- Brand assets, colors, typography, responsive, localization: N/A — no UI.
- Accessibility target: N/A with reason (no visual surface; plain-text CLI output).

## Product shape and supported environments

- Product type: local install scripts; no service, no tenant, no telemetry.
- Supported: Windows 10/11, Windows PowerShell 5.1 and PowerShell 7+.
- Hosting/regions/residency: N/A — runs on the user's machine; model traffic goes to Meta's endpoint per the user's own key.
- Environments: dev = owner's machine; CI = GitHub Actions (windows-latest).

## Distribution, signing, and updates

- Channels: public GitHub repo; clone + run `install.ps1`.
- Install/configure/update/repair/uninstall: `install.ps1` (-InstallDir, -NoPathUpdate, -Force); updates = pull + re-run; uninstall = delete install dir, remove PATH entry, `muse-mode off` (documented in README).
- Signatures/notarization/SBOM: N/A — unsigned scripts; ExecutionPolicy Bypass documented per command.
- Telemetry/crash reporting/update checks: none, by design.

## Data, security, privacy, and compliance

- Data classes: one user secret (Meta Model API key). No other personal data.
- Trust boundary: the Windows user profile. DPAPI CurrentUser encryption; the key never enters settings.json, env vars (launcher scrubs them), logs, or the repo.
- Highest-impact abuse: installer echoing the key; committing `modelapi-key.dpapi` or `settings.json`. Mitigations: SecureString end-to-end, BSTR zeroing, `.gitignore`, gitleaks in CI and pre-commit guidance, red-drilled canary test.
- Retention/deletion: key lives in one local file; uninstall deletes it.
- Privacy/legal/licensing: MIT; no Meta endorsement (README says unofficial).
- Vulnerability reporting: GitHub issues to the owner.

## Architecture and dependencies

- Style: dependency-free scripts; no modules, no packages, no build.
- Reuse: authoritative originals live at `%LOCALAPPDATA%\muse-claude` on the owner's machine; `src/` holds adapted copies with machine-specific paths removed. `settings.json` ships as `settings.template.json`.
- New code: `install.ps1` (prompt → DPAPI hex → settings → PATH).
- Public surface: `muse-mode on|off|status`, `muse-claude.cmd` args passthrough, install.ps1 parameters.
- Integrations: Claude Code CLI (external, not managed); Meta Model API via the user's key.
- Scale: single-user machines.
- Stack: Windows batch + PowerShell 5.1-compatible scripting. Versions: no dependencies. Rejected: a PowerShell module (heavier install for the same job).

## Quality and reliability contract

- Acceptance evidence: Pester round-trip on a temp settings copy (`off` restores byte-for-byte); installer sandbox run (temp dir, canary key, DPAPI round-trip through key.ps1).
- Delivery-plan location: PLAN.md in this repo.
- Test levels: Pester unit/round-trip on pwsh; manual 5.1 runs recorded.
- Red drills: gitleaks canary, PSScriptAnalyzer planted violation, Pester planted failure. Evidence in PLAN.md.
- Accessibility/visual: N/A (no UI).
- Budgets: installer completes in seconds; no background processes.
- Availability/durability: N/A — local scripts; settings backup (`.bak-muse-mode`) on every write.
- Certification: every command in README has been run; gates green before release.

## Release pipeline

- Source host: GitHub (public). Branching: main; small PRs.
- CI: GitHub Actions windows-latest: PSScriptAnalyzer, Pester, gitleaks, actionlint.
- Gates block merge; README commands verified by the owner.
- Versioning: Keep a Changelog; tags when the switcher behavior changes.
- Rollback: re-run older `install.ps1`; `muse-mode off` always available.

## Operations

- Observability/support/incidents/backups/retirement: owner-handled via GitHub issues. Settings backups (`.bak-muse-mode`) are the recovery path. Retirement = archive the repo.

## Decision ledger

| Date | Decision | Status |
|---|---|---|
| 2026-09-29 | Repo `claude-muse-mode`, full toolkit + install script, GitHub public | Confirmed |
| 2026-09-29 | Installer prompts for key, DPAPI-encrypts locally | Confirmed |
| 2026-09-29 | Windows now, portable later; 5.1-compatible scripting required | Confirmed |
| 2026-09-29 | MIT license | Confirmed |
| 2026-09-29 | Schema shim rides mode on/off + install/uninstall, no new surfaces | Confirmed |
| 2026-09-29 | Copyright holder name "Randy Northrup" assumed from GitHub handle — owner to correct if wrong | Assumed |
