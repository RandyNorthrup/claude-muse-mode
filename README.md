# claude-muse-mode (unofficial)

Run Claude Code on Meta's Muse Model API, and switch back to Anthropic with
one command. No affiliation with or endorsement by Meta.

## What this is

- `muse-mode on` — new Claude Code sessions use Muse via Meta's Anthropic-compatible endpoint, with per-tier defaults (opus `muse-spark-1.3-contributor`, sonnet `muse-spark-1.2-contributor`, haiku `muse-spark-1.1`, fable `muse-spark-1.3` — four distinct live chat ids), plus picker `NAME`/`DESCRIPTION` labels so rows show Muse names instead of "Custom <Tier> model", plus the fifth spark id (`muse-spark-1.2`) on the picker's custom row. Subagents follow the main (opus) model.
- `muse-mode off` — back to Anthropic (your claude.ai login). Whatever model/env settings you had are restored, and the shim is stopped.
- Turn-chain reminder — every prompt runs the previous tracker, then appends "finish the turn chain" context only while Muse mode is on, so turns keep chaining tools instead of ending on status promises; Claude-mode prompts pass through untouched.
- `muse-mode status` — which one new sessions will use.
- `muse-mode shim` — whether the schema shim is running.
- `muse-claude.cmd` — one-shot launcher: runs `claude` on Muse for that process only, without touching your settings.
- Works in Windows PowerShell 5.1 and PowerShell 7+.

## The schema shim

Claude Code 2.1.265+ ships tool schemas (notably the built-in Artifact
tool's `pattern`/`minLength`/`maxLength`) that Meta's strict validator
rejects with `400 Invalid JSON schema`, failing every interactive turn.
`muse-mode on` starts a localhost proxy (`muse-shim.js`, port 15555 unless
`MUSE_SHIM_PORT` is set) and points Muse traffic at it; the shim strips
those keywords from `tools[].input_schema`, drops tool fields Meta rejects
(`max_uses`), re-declares the shortened body's length, and streams
responses back. Meta's web-search execution is broken (it 400s, then
returns empty results), so the shim also drops the web-search tool and
lets the model fall through to working tools; set
`MUSE_SHIM_KEEP_WEB_SEARCH=1` and restart the shim to keep it. It also
drops the `thinking` request param (Meta answers with redacted blocks
the client can only render as noise); set `MUSE_SHIM_KEEP_THINKING=1`
and restart the shim to keep it. Since Meta also emits redacted blocks
unprompted, the shim filters thinking blocks out of responses too (SSE
streams stay streaming; single-shot JSON bodies are re-packed). The CLI
still validates tool inputs locally, so no constraint is lost. The shim
logs a summary line per request (path, tool count, stripped
keywords/fields, request param names) plus the upstream status line —
never bodies, headers, or keys. `muse-mode off` stops it; its log lives
next to it as `muse-shim.log`.

## Install

Requires: Windows 10/11, Claude Code CLI (`claude`), Node.js (for the
shim), a Meta Model API key.

```powershell
git clone https://github.com/RandyNorthrup/claude-muse-mode.git
cd claude-muse-mode
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The installer walks you through three guided steps. First, pick where you
use Claude Code — `[1]` vanilla CLI (tools on your user PATH, any
terminal), `[2]` VS Code (plus a `"Muse"` terminal profile), `[3]` another
IDE or editor (plus setup notes); each choice is labeled, one is
recommended for your machine, and words work too (`cli`, `vscode`,
`other`). Then paste your API key (never displayed, DPAPI-encrypted for
your Windows user only). Finally, one UAC prompt writes Muse usage pricing
(Meta per-token rates) to `C:\Program Files\ClaudeCode\managed-settings.json`,
so `/cost` prices Muse models instead of reporting "unknown models" —
declining just keeps fallback pricing. It writes machine-local
`settings.json` and adds the install directory to your user PATH. Open a **new** terminal
afterwards, then:

```powershell
muse-mode on                    # per-tier defaults (opus 1.3-contributor, sonnet 1.2-contributor, haiku 1.1, fable 1.3; spare 1.2 on custom row)
muse-mode on -Model <other-id>  # pin every tier to one id, without leaving Muse mode
```

Then open a new Claude Code session (a new Claude tab in VS Code) to use Muse.

Usage cost in Muse mode: Claude Code has no price table for `muse-*`
ids, so without pricing data `/cost` reports "unknown models" with
fallback math. The installer writes Meta's rates (contributor: in $0.10 /
out $0.20 / cached $0.002; standard: in $1.25 / out $4.25 / cached $0.15
per 1M tokens) as `modelPricing` overrides; the panel then prices Muse
sessions at Meta rates ("at your organization's configured rates") while
Anthropic sessions keep list pricing. Takes effect in new sessions;
figures are estimates, not an invoice.

Options: `-Target <cli|vscode|other>` to skip the menu (required for
non-interactive runs), `-InstallDir <path>` to choose the target
directory, `-NoPathUpdate` to skip the PATH change, `-Force` to replace a
stored key without confirming. `MUSE_MODEL` pins every tier to one id for a
single `muse-claude.cmd` run.

## Uninstall

1. `muse-mode off` (restores your Anthropic settings and stops the shim).
2. Delete the install directory (default `%LOCALAPPDATA%\claude-muse-mode`).
3. Remove that directory from your user PATH (System Properties →
   Environment Variables).
4. If you installed with the VS Code target, remove the `"Muse"` profile
   from `terminal.integrated.profiles.windows` in your VS Code settings
   (a `.bak-muse-mode` backup sits next to it).
5. Deleting the directory also deletes your encrypted stored key, the shim
   PID file, and the shim log.

## Security

- The API key is held as a SecureString, DPAPI-encrypted to
  `modelapi-key.dpapi` (your Windows user only can decrypt it), and never
  written to settings, logs, or the console.
- `modelapi-key.dpapi`, `settings.json`, settings backups, and
  `saved-*.json` are gitignored and must never be committed.
- The `muse-claude.cmd` launcher scrubs `ANTHROPIC_API_KEY` /
  `ANTHROPIC_AUTH_TOKEN` from its environment so a stray login token cannot
  override the key helper.

## Layout

```
src/                  the launcher scripts (portable copies, no local paths)
  muse-mode.ps1       the on/off/status/shim switcher
  muse-mode.cmd       pwsh launcher for cmd.exe
  muse-claude.cmd     one-shot `claude` on Muse (starts the shim on demand)
  muse-shim.js        localhost schema-sanitizing proxy (node, stdlib only)
  muse-gate.js        UserPromptSubmit dispatcher: previous tracker, plus the
                      anti-stall reminder only while Muse mode is on
  key.ps1             apiKeyHelper: decrypts the stored key per request
  settings.template.json  shape of the machine-local settings.json
install.ps1           installer: copy, prompt, encrypt, settings, PATH
test/                 Pester round-trip tests (temp settings copy, canary key)
.github/workflows/   CI: PSScriptAnalyzer, Pester, shim self-test, gitleaks, actionlint
```

## Development

Requires Node.js (the round-trip tests start a shim on a temp port).

```powershell
# lint (installs PSScriptAnalyzer for the current user if missing)
Invoke-ScriptAnalyzer -Path . -Recurse -EnableExit
# tests (PowerShell 7)
pwsh -NoProfile -Command "Invoke-Pester ./test -EnableExit"
# shim self-test (no network)
node src/muse-shim.js --self-test
# turn-chain gate self-test (no network)
node src/muse-gate.js --self-test
# secrets (--no-git: also scans the uncommitted tree)
gitleaks detect --source . --no-git --verbose
```

## License

MIT — see LICENSE.
