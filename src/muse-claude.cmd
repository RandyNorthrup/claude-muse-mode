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
rem defaults (live /v1/models 2026-09-29): opus 1.3-contributor, sonnet
rem 1.2-contributor, haiku 1.1, fable 1.3 (four distinct chat ids, no
rem duplicated rows). NAME/DESCRIPTION labels keep rows from falling back
rem to "Custom <Tier> model" (honored since CLI 2.1.118); the Fable pin
rem keeps the built-in Anthropic Fable row out of Muse sessions.
if defined MUSE_MODEL goto :pinned
set "MUSE_OPUS_MODEL=muse-spark-1.3-contributor"
set "MUSE_SONNET_MODEL=muse-spark-1.2-contributor"
set "MUSE_HAIKU_MODEL=muse-spark-1.1"
set "MUSE_FABLE_MODEL=muse-spark-1.3"
set "MUSE_OPUS_NAME=Muse Spark 1.3 Contributor"
set "MUSE_OPUS_DESCRIPTION=Newest Muse model, contributor tier"
set "MUSE_SONNET_NAME=Muse Spark 1.2 Contributor"
set "MUSE_SONNET_DESCRIPTION=Balanced Muse model, contributor tier"
set "MUSE_HAIKU_NAME=Muse Spark 1.1"
set "MUSE_HAIKU_DESCRIPTION=Fast Muse model for quick tasks"
set "MUSE_FABLE_NAME=Muse Spark 1.3"
set "MUSE_FABLE_DESCRIPTION=Most-capable Muse tier for hardest, longest-running tasks"
set "MUSE_SPARE_MODEL=muse-spark-1.2"
set "MUSE_SPARE_NAME=Muse Spark 1.2"
set "MUSE_SPARE_DESCRIPTION=Standard Muse model, previous generation"
goto :apply
:pinned
set "MUSE_OPUS_MODEL=%MUSE_MODEL%"
set "MUSE_SONNET_MODEL=%MUSE_MODEL%"
set "MUSE_HAIKU_MODEL=%MUSE_MODEL%"
set "MUSE_FABLE_MODEL=%MUSE_MODEL%"
set "MUSE_SPARE_MODEL=%MUSE_MODEL%"
set "MUSE_OPUS_NAME=%MUSE_MODEL%"
set "MUSE_SONNET_NAME=%MUSE_MODEL%"
set "MUSE_HAIKU_NAME=%MUSE_MODEL%"
set "MUSE_FABLE_NAME=%MUSE_MODEL%"
set "MUSE_SPARE_NAME=%MUSE_MODEL%"
set "MUSE_OPUS_DESCRIPTION=Pinned Muse model (MUSE_MODEL)"
set "MUSE_SONNET_DESCRIPTION=Pinned Muse model (MUSE_MODEL)"
set "MUSE_HAIKU_DESCRIPTION=Pinned Muse model (MUSE_MODEL)"
set "MUSE_FABLE_DESCRIPTION=Pinned Muse model (MUSE_MODEL)"
set "MUSE_SPARE_DESCRIPTION=Pinned Muse model (MUSE_MODEL)"
:apply
set "ANTHROPIC_MODEL=%MUSE_OPUS_MODEL%"
set "ANTHROPIC_DEFAULT_OPUS_MODEL=%MUSE_OPUS_MODEL%"
set "ANTHROPIC_DEFAULT_SONNET_MODEL=%MUSE_SONNET_MODEL%"
set "ANTHROPIC_DEFAULT_HAIKU_MODEL=%MUSE_HAIKU_MODEL%"
set "ANTHROPIC_DEFAULT_FABLE_MODEL=%MUSE_FABLE_MODEL%"
set "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME=%MUSE_OPUS_NAME%"
set "ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION=%MUSE_OPUS_DESCRIPTION%"
set "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME=%MUSE_SONNET_NAME%"
set "ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION=%MUSE_SONNET_DESCRIPTION%"
set "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME=%MUSE_HAIKU_NAME%"
set "ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION=%MUSE_HAIKU_DESCRIPTION%"
set "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME=%MUSE_FABLE_NAME%"
set "ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION=%MUSE_FABLE_DESCRIPTION%"
set "ANTHROPIC_CUSTOM_MODEL_OPTION=%MUSE_SPARE_MODEL%"
set "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME=%MUSE_SPARE_NAME%"
set "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION=%MUSE_SPARE_DESCRIPTION%"
rem Subagents follow the main (opus) model: Default on opus must not leak
rem haiku-tier traffic underneath.
set "CLAUDE_CODE_SUBAGENT_MODEL=%MUSE_OPUS_MODEL%"
set "ENABLE_TOOL_SEARCH=true"
claude --settings "%~dp0settings.json" %*
