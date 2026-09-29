# Plan — claude-muse-mode

Brief: PROJECT_BRIEF.md (Confirmed 2026-09-29).

## Decisions

- D1: Windows-only first release; scripts must run on PowerShell 5.1 and 7+.
  Source: Grill 2026-09-29 (Windows now, portable later).
- D2: Installer prompts for the key and DPAPI-encrypts locally (CurrentUser);
  plaintext only ever in a zeroed BSTR. Source: Grill (installer prompts).
- D3: No dependencies — no modules, no packages, no build. Gates run with
  stock Windows tooling plus PSGallery PSScriptAnalyzer.
- D4: `~/.claude/settings.json` is never touched by the installer; only
  `muse-mode on/off` edits it, with `.bak-muse-mode` backup and saved-value
  restore. `off` restores byte-equivalent settings (Pester asserts).
- D5: Pester 3.4 syntax (`Should Be`) — the version bundled with both
  Windows PowerShell and this machine's PowerShell 7.
- D6: CI pins `actions/checkout@v4` and `gitleaks/gitleaks-action@v2` tags;
  PSScriptAnalyzer/actionlint float on latest with green CI as the evidence.
  (SHA pinning deferred — owner-only repo, no release artifacts.)

## Compatibility notes

- `muse-mode.ps1` runs under 5.1 when typed bare (PowerShell prefers `.ps1`
  over `.cmd`), so 5.1-incompatible cmdlets are banned (see AGENTS.md).
- `install.ps1` verifies its own outputs instead of calling
  `muse-mode status`, so it works on machines without Claude Code settings.

## Milestones

### M1 — Scaffold + install script (this change)

- Goal: shareable repo with installer, docs, tests, CI.
- Files: src/*, install.ps1, test/*, .github/workflows/ci.yml, docs.
- Acceptance: Pester green on pwsh; installer sandbox run with canary key
  round-trips through key.ps1; gitleaks clean; actionlint clean;
  PSScriptAnalyzer clean (after install); README commands all run.
- Certification: red drills below.

### M2 — Schema shim (D7)

- `src/muse-shim.js` (node stdlib only): strip strict-forbidden keywords
  from `tools[].input_schema`, forward the rest, stream responses; summary
  log line per request, never bodies/headers/keys. `--self-test` (no
  network), `--ensure`/`--stop` lifecycle with PID file, `--no-strip`
  count-only diagnostic mode.
- Piggyback wiring, no new surfaces: `muse-mode on` ensures the shim and
  routes through it (fails before touching settings otherwise); `off`
  restores settings and stops it; new `muse-mode shim` verb reports state;
  `muse-claude.cmd` ensures on demand; `install.ps1` ships the file and
  warns when node is missing; uninstall stays off + delete + PATH removal.
- Acceptance: self-test green; Pester asserts shim URL in settings,
  running state, and stopped-after-off; live relay proven against Meta
  (15-tool piped request relayed with per-keyword strip counts).

### M3 — Publish

- `gh repo create claude-muse-mode --public --source . --push`. Owner
  already authenticated (`gh auth status` green 2026-09-29).
- Done 2026-09-29 (resume): fresh `git init` (no prior .git found),
  all gates green, pushed to public GitHub.

## Decisions (continued)

- D7: shim rides the existing mode/install surfaces (user direction
  2026-09-29): no standalone manager, no new install dir layout. Fixed
  port 15555 (`MUSE_SHIM_PORT` override); PID + log live in the install
  dir; tests isolate to port 15577 with temp pid/log files.
- D8: `muse-mode on -Model <id>` (default 1.3-contributor, free-form id —
  no catalog to validate against; user supplies ids); in-mode switching
  without touching the pre-Muse backup; `MUSE_MODEL` for one-shot
  `muse-claude.cmd` runs. Installer target menu (`-Target`, TUI fallback):
  vscode target merges a terminal profile (never clobbers a foreign
  `Muse` profile); tests redirect VS Code settings via
  `MUSE_TEST_VSCODE_SETTINGS`. JSON helpers duplicated in install.ps1
  (single-file robustness) with cross-reference; shared-file refactor
  rejected (would touch tested shipped code).
- D9: guided installer TUI (banner, labeled menu + recommendation,
  instructed key prompt, summary). Single-file rule kept: tests load the
  pure `Get-*` text helpers from install.ps1 via AST instead of a shared
  module. Display goes through Write-Host confined to `Write-UiLine`
  (one `SuppressMessageAttribute`, justification inline): Write-Output
  there pollutes the return values of the prompting functions (proven by
  interactive PTY probe — Object[] where SecureString belongs). The old
  menu's silent re-prompt on invalid input was the reported "hang"; the
  new menu names the problem and re-shows itself.
- D10: shim re-declares Content-Length on every re-serialized body (the
  2026-09-29 VS Code hang: stripped bodies went out under the original
  length, Meta waited, Claude Code retried every ~6 min). Regression
  cover is a localhost relay inside `--self-test` (dummy upstream waits
  for the full body; ~2s red without the fix), not Pester — the
  round-trip suite only exercises shim health/settings, never relay.
- D11: shim strips `max_uses` from tool definitions and logs upstream
  status + ms per request (second log line; request line stays first so
  hangs keep their evidence). `redacted_thinking` noise is left alone
  deliberately: stripping response/history blocks would break the
  signature chain for zero functional gain — the session round-trips
  fine with it. Evidence 2026-09-29: `toolfields` fired 0 times and
  every measured upstream answered 200 — the web-search 400/empty and
  the classifier outage both live above the shim (Meta executor /
  client flow). Strip kept as tested defense for the named field;
  classifier workaround is leaving auto mode for manual approval.
- D12: shim drops web-search tools (Meta executor proven useless:
  max_uses 400, then empty; model demonstrably prefers WebFetch).
  Restorable via `MUSE_SHIM_KEEP_WEB_SEARCH=1`. Request lines now carry
  top-level param names (never values) to answer the thinking question
  with data: if `thinking` is requested, strip the request param; if
  Meta injects it unprompted, silencing needs response surgery (owner
  call — risky).
- D13: shim drops the `thinking` request param (log proved it requested;
  Meta's redacted answers rendered as client noise). Restorable via
  `MUSE_SHIM_KEEP_THINKING=1`. Cost/benefit: possible reasoning-quality
  loss for a quiet client — owner judges live, revert is one deploy.
  Open: whether the Bash classifier outage clears with it (if the
  classifier choked on redacted blocks) or needs its own probe
  (timestamp-correlated Bash attempt vs log).
- D14: shim filters thinking/redacted_thinking blocks out of responses
  (SSE event filter + JSON re-pack; Meta emits them even with no
  `thinking` param, proven by fresh-session turn 1 with
  `dropped_params=[thinking]`). Fail-open everywhere; streaming
  preserved; same `MUSE_SHIM_KEEP_THINKING=1` flag gates request and
  response handling together. Gate result: the live 3-turn gate
  (fresh session: chat, tools, Bash) passed clean with zero noise
  lines — Meta has no echo requirement, filter stands.
- D15: per-tier Muse model defaults (picker showed one id thrice because
  muse-mode set every tier slot to `muse-spark-1.3-contributor`).
  `muse-mode on` with no flag now maps opus `muse-spark-1.3-contributor`,
  sonnet `muse-spark-1.2-contributor`, haiku `muse-spark-1.1` (the /v1/models
  catalog 2026-09-29 lists 8 ids; the 3 non-spark are image/voice/sam, the
  5 spark all answered a live chat probe; sonnet takes previous-gen
  contributor, haiku the smallest, subagent follows haiku). `-Model <id>`
  still pins every tier to one id. Same mapping in `muse-claude.cmd` via
  MUSE_MODEL default branches. `status` prints the per-tier triple when
  tiers differ. Open: `modelPricing` managed-settings overrides for Muse
  ids so /cost stops saying "unknown models" — needs Meta per-Mtok rates
  and a managed-settings.json write (user-level settings.json is ignored
  by design; warned: needs pricing page + elevation decision).

## Red-drill evidence

| Gate | Break it | Seen to fail | Restored green |
|---|---|---|---|
| Pester | status expectation to `WRONG-ON-PURPOSE` | yes, 6/7 exit 1 | yes, 7/7 |
| PSScriptAnalyzer | planted `ConvertTo-SecureString -AsPlainText` (Error) in install.ps1 | yes, exit 1 | yes, zero findings |
| gitleaks | randomized `ghp_`-shaped canary file, uncommitted, deleted after | yes, leaks found: 1 | yes, no leaks, canary deleted |
| shim self-test | `pattern >= 99` assert | yes, exit 1 | yes, SELF-TEST PASS |
| vscode profile test | profile-path expectation to `does-not-exist-zzz` | yes, 14/15 exit 1 | yes, 15/15 (2026-09-29 resume) |
| TUI text test | choice expectation to `WRONG-ON-PURPOSE` | yes, 8/9 exit 1 | yes, 9/9 |
| shim relay test | fix line commented out | yes, 408 exit 1 (~2s) | yes, RELAY-TEST PASS |
| max_uses assert | delete disabled | yes, true!==false exit 1 | yes, SELF-TEST PASS |
| web_search drop | drop disabled | yes, 1!==0 exit 1 | yes, SELF-TEST PASS |
| thinking drop | delete disabled | yes, true!==false exit 1 | yes, SELF-TEST PASS |
| SSE thinking filter | branch disabled | yes, true!==false exit 1 | yes, SELF-TEST PASS |

## Notes

- Test-log cosmetic (open): the sandbox test's `canary-<guid>` value appears
  in Pester's console output despite hash-only assertions and .NET-API
  capture (bisected: halves clean alone; installer/shim/key paths proven
  silent standalone). Zero secret impact: single-use random canary,
  destroyed with its temp dir; real keys never enter tests by construction.
  Owner may pursue or accept.

## Open questions

- LICENSE holder "Randy Northrup" — confirmed by owner 2026-09-29.
