@echo off
rem Claude Code on Meta's Muse Model API (Anthropic-compatible endpoint).
rem Only this process and its children see these settings; normal
rem `claude` sessions are unchanged. The key comes from key.ps1
rem (apiKeyHelper), never from an environment variable.
setlocal
set "ANTHROPIC_API_KEY="
set "ANTHROPIC_AUTH_TOKEN="
rem Route through the localhost schema shim (started on demand): Meta's
rem strict validator rejects tool schemas Claude Code ships, failing every
rem interactive turn with 400. Port 15555 unless MUSE_SHIM_PORT is set.
if not defined MUSE_SHIM_PORT set "MUSE_SHIM_PORT=15555"
for /f "delims=" %%u in ('node "%~dp0muse-shim.js" --ensure --port %MUSE_SHIM_PORT% 2^>^&1') do set "MUSE_SHIM_URL=%%u"
echo %MUSE_SHIM_URL% | findstr /r "^http://127\.0\.0\.1:" >nul || (echo muse-shim failed to start: %MUSE_SHIM_URL% 1>&2 & exit /b 1)
set "ANTHROPIC_BASE_URL=%MUSE_SHIM_URL%"
rem Model tiers: MUSE_MODEL pins every tier to one id; otherwise per-tier
rem defaults (all chat-probed 2026-09-29): opus 1.3-contributor, sonnet
rem 1.2-contributor, haiku 1.1. Distinct ids so the picker shows three rows.
if defined MUSE_MODEL goto :pinned
set "MUSE_OPUS_MODEL=muse-spark-1.3-contributor"
set "MUSE_SONNET_MODEL=muse-spark-1.2-contributor"
set "MUSE_HAIKU_MODEL=muse-spark-1.1"
goto :apply
:pinned
set "MUSE_OPUS_MODEL=%MUSE_MODEL%"
set "MUSE_SONNET_MODEL=%MUSE_MODEL%"
set "MUSE_HAIKU_MODEL=%MUSE_MODEL%"
:apply
set "ANTHROPIC_MODEL=%MUSE_OPUS_MODEL%"
set "ANTHROPIC_DEFAULT_OPUS_MODEL=%MUSE_OPUS_MODEL%"
set "ANTHROPIC_DEFAULT_SONNET_MODEL=%MUSE_SONNET_MODEL%"
set "ANTHROPIC_DEFAULT_HAIKU_MODEL=%MUSE_HAIKU_MODEL%"
set "CLAUDE_CODE_SUBAGENT_MODEL=%MUSE_HAIKU_MODEL%"
set "ENABLE_TOOL_SEARCH=true"
claude --settings "%~dp0settings.json" %*
