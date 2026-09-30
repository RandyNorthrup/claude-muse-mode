#!/usr/bin/env node
// muse-gate — hook dispatcher shipped with claude-muse-mode. Handles two events:
// UserPromptSubmit: runs the previous tracker hook (default:
// caveman-mode-tracker.js beside this file, override with
// MUSE_GATE_TRACKER_CMD), then appends the anti-stall reminder ONLY while
// Muse mode is on. Claude mode gets the tracker's output untouched.
// Stop: while Muse mode is on, blocks the FIRST natural stop per response
// chain (and at most STOP_BLOCK_CAP per session transcript) with a
// turn-chain check, so a stalled turn keeps going instead of ending on a
// status promise. Never blocks when off, when already continuing
// (stop_hook_active), or when MUSE_GATE_NO_STOP=1. Silent-fail everywhere:
// never blocks a prompt, never loops a stop.
// `node muse-gate.js --self-test` exercises both tables with temp fixtures
// (no network, no settings).
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const REMINDER = 'MUSE MODE: finish the turn chain. When task steps remain, ' +
  'keep calling tools — never end a turn on a status line promising the ' +
  'next step. Batch independent tool calls in one block; prose only when ' +
  'done or blocked.';

// Stop-hook continuer: short + concrete. The model already saw REMINDER at
// prompt time; this only fires when it stopped anyway, so it names the
// exact check instead of repeating the whole rule.
const STOP_REASON = 'MUSE MODE turn-chain check: if any task step remains ' +
  '(edits, tests, gates, commits not yet done), keep calling tools — do not ' +
  'end the turn with prose. If done or blocked, reply briefly and end.';
// Max forced continuations per session transcript. The stop_hook_active
// protocol flag is the primary loop guard (one block per chain); the cap
// bounds total extra turns per session even if flags misbehave.
const STOP_BLOCK_CAP = 2;

function trackerPath() {
  return process.env.MUSE_GATE_TRACKER_CMD ||
    path.join(__dirname, 'caveman-mode-tracker.js');
}

function settingsPath() {
  if (process.env.MUSE_GATE_TEST_SETTINGS) return process.env.MUSE_GATE_TEST_SETTINGS;
  const dir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
  return path.join(dir, 'settings.json');
}

// Muse mode is on iff the active key helper points at a key.ps1 whose
// directory holds the Anthropic backup (muse-mode writes
// saved-anthropic.json on `on`, deletes on `off`). The install directory
// name is never consulted so renamed installs keep working; quoted and
// legacy unquoted -File paths both parse. Never prints settings
// contents — boolean only.
function museModeOn(settingsFile) {
  try {
    const settings = JSON.parse(fs.readFileSync(settingsFile, 'utf8'));
    const helper = String(settings.apiKeyHelper || '');
    const hm = helper.match(/-File\s+(?:"([^"]+)"|(\S+))/i);
    if (!hm) return false;
    const keyPath = (hm[1] || hm[2]).replace(/\//g, path.sep);
    if (path.basename(keyPath).toLowerCase() !== 'key.ps1') return false;
    const instDir = path.dirname(keyPath);
    return fs.existsSync(path.join(instDir, 'saved-anthropic.json'));
  } catch (e) {
    return false;
  }
}

// Pure merge: tracker raw stdout + mode boolean -> stdout string ('' = silent).
function buildOutput(trackerRaw, museOn) {
  let tracker = null;
  try { tracker = trackerRaw ? JSON.parse(trackerRaw) : null; } catch (e) { tracker = null; }
  if (tracker && tracker.decision === 'block') return trackerRaw;
  const parts = [];
  const ctx = tracker && tracker.hookSpecificOutput &&
    tracker.hookSpecificOutput.additionalContext;
  if (ctx) parts.push(ctx);
  if (museOn) parts.push(REMINDER);
  if (!parts.length) return '';
  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'UserPromptSubmit',
      additionalContext: parts.join('\n')
    }
  });
}

function runTracker(input) {
  try {
    return execFileSync(process.execPath, [trackerPath()], {
      input, encoding: 'utf8', timeout: 4000, stdio: ['pipe', 'pipe', 'ignore']
    }).trim();
  } catch (e) {
    return '';
  }
}

// --- Stop-hook continuer (Muse mode only) ---
// Per-turn reminder text is advisory; the harness still ends the turn when
// the model stops emitting tool calls. The Stop hook is the enforcement
// point: block the first natural stop(s) per response chain so a stalled
// turn continues instead of ending on a status promise.
// Guards (fail-open, silent when any trips):
// - off: Muse mode not detected -> '{}' (Claude mode provably untouched)
// - stop_hook_active: already continuing from a previous block -> '{}'
// - MUSE_GATE_NO_STOP=1: operator kill-switch -> '{}'
// - STOP_BLOCK_CAP per session transcript: bounds extra turns per session.
function stopStateDir() {
  return process.env.MUSE_GATE_TEST_STATEDIR || path.join(os.tmpdir(), 'muse-gate-stop');
}

function stopCountFile(transcriptPath) {
  const h = crypto.createHash('sha256').update(String(transcriptPath || 'no-transcript')).digest('hex').slice(0, 16);
  return path.join(stopStateDir(), h + '.count');
}

function readStopCount(transcriptPath) {
  try {
    const n = Number(fs.readFileSync(stopCountFile(transcriptPath), 'utf8').trim());
    return Number.isFinite(n) && n >= 0 ? n : 0;
  } catch (e) {
    return 0;
  }
}

function bumpStopCount(transcriptPath) {
  try {
    fs.mkdirSync(stopStateDir(), { recursive: true });
    fs.writeFileSync(stopCountFile(transcriptPath), String(readStopCount(transcriptPath) + 1));
  } catch (e) { /* fail open: count lost, cap still bounds via next read */ }
}

// Pure decision: stop-hook input object + mode boolean -> output string.
// '{}' = let the stop stand (silent). Block JSON = force one more turn.
function buildStopOutput(stopInput, museOn) {
  if (!museOn) return '{}';
  if (process.env.MUSE_GATE_NO_STOP === '1') return '{}';
  const inp = stopInput && typeof stopInput === 'object' ? stopInput : {};
  if (inp.stop_hook_active) return '{}';
  if (readStopCount(inp.transcript_path) >= STOP_BLOCK_CAP) return '{}';
  bumpStopCount(inp.transcript_path);
  return JSON.stringify({ decision: 'block', reason: STOP_REASON });
}

if (process.argv[2] === '--self-test') {
  const assert = require('assert');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-gate-test-'));
  try {
    const inst = path.join(tmp, 'claude-muse-mode-test');
    fs.mkdirSync(inst);
    fs.writeFileSync(path.join(inst, 'saved-anthropic.json'), '{}');
    const onFile = path.join(tmp, 'on.json');
    const offFile = path.join(tmp, 'off.json');
    fs.writeFileSync(onFile, JSON.stringify({ apiKeyHelper: 'powershell -File ' + inst + '/key.ps1' }));
    fs.writeFileSync(offFile, JSON.stringify({ apiKeyHelper: 'other-helper' }));
    assert.strictEqual(museModeOn(onFile), true, 'on-state detected');
    assert.strictEqual(museModeOn(offFile), false, 'off-state silent');
    assert.strictEqual(museModeOn(path.join(tmp, 'missing.json')), false, 'missing settings silent');
    // Quoted -File paths (install dirs with spaces) and renamed install
    // dirs both count: only key.ps1 + the Anthropic backup matter.
    const quoted = path.join(tmp, 'quoted.json');
    fs.writeFileSync(quoted, JSON.stringify({ apiKeyHelper: 'powershell -File "' + inst + '/key with space.ps1"' }));
    fs.writeFileSync(path.join(inst, 'key with space.ps1'), 'x');
    fs.writeFileSync(path.join(inst, 'saved-anthropic.json'), '{}');
    assert.strictEqual(museModeOn(quoted), false, 'wrong filename stays off');
    const renamed = path.join(tmp, 'renamed tools');
    fs.mkdirSync(renamed);
    fs.writeFileSync(path.join(renamed, 'saved-anthropic.json'), '{}');
    const renamedFile = path.join(tmp, 'renamed.json');
    fs.writeFileSync(renamedFile, JSON.stringify({ apiKeyHelper: 'powershell -File "' + renamed + '/key.ps1"' }));
    assert.strictEqual(museModeOn(renamedFile), true, 'renamed dir stays on');
    const ctx = JSON.stringify({ hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: 'CTX' } });
    const merged = JSON.parse(buildOutput(ctx, true));
    assert.ok(merged.hookSpecificOutput.additionalContext.indexOf('CTX') !== -1, 'tracker kept');
    assert.ok(merged.hookSpecificOutput.additionalContext.indexOf('MUSE MODE') !== -1, 'reminder merged');
    assert.strictEqual(buildOutput(ctx, false), ctx, 'off passes tracker through');
    assert.ok(buildOutput('', true).indexOf('MUSE MODE') !== -1, 'on without tracker');
    assert.strictEqual(buildOutput('', false), '', 'off without tracker silent');
    const block = JSON.stringify({ decision: 'block', reason: 'stats' });
    assert.strictEqual(buildOutput(block, true), block, 'block passes through');
    assert.ok(buildOutput('not-json{{{', true).indexOf('MUSE MODE') !== -1, 'bad tracker JSON + on');
    assert.strictEqual(buildOutput('not-json{{{', false), '', 'bad tracker JSON + off');
    // --- Stop-hook continuer ---
    const stopDir = path.join(tmp, 'stop-state');
    fs.mkdirSync(stopDir);
    process.env.MUSE_GATE_TEST_STATEDIR = stopDir;
    try {
      const stopIn = { hook_event_name: 'Stop', transcript_path: path.join(tmp, 't1.jsonl') };
      // Off: silent '{}' even for a fresh stop.
      assert.strictEqual(buildStopOutput(stopIn, false), '{}', 'stop off silent');
      // On: first stop blocked with the turn-chain check.
      const b1 = JSON.parse(buildStopOutput(stopIn, true));
      assert.strictEqual(b1.decision, 'block', 'stop on blocks once');
      assert.ok(String(b1.reason).indexOf('turn-chain') !== -1, 'stop reason names check');
      // Second stop: still under cap -> blocked.
      const b2 = JSON.parse(buildStopOutput(stopIn, true));
      assert.strictEqual(b2.decision, 'block', 'stop on blocks twice');
      // Third stop: cap reached -> silent.
      assert.strictEqual(buildStopOutput(stopIn, true), '{}', 'stop cap holds');
      // stop_hook_active: already continuing -> silent, no count burned.
      const active = { hook_event_name: 'Stop', stop_hook_active: true, transcript_path: path.join(tmp, 't2.jsonl') };
      assert.strictEqual(buildStopOutput(active, true), '{}', 'stop active silent');
      assert.strictEqual(readStopCount(path.join(tmp, 't2.jsonl')), 0, 'stop active burns no count');
      // Kill-switch: silent.
      process.env.MUSE_GATE_NO_STOP = '1';
      try {
        assert.strictEqual(buildStopOutput(stopIn, true), '{}', 'stop kill-switch silent');
      } finally {
        delete process.env.MUSE_GATE_NO_STOP;
      }
      // Garbage input: null folds to the no-transcript bucket (bounded by
      // the cap like any other transcript), never a crash.
      assert.strictEqual(buildStopOutput(null, false), '{}', 'stop null off silent');
      const bn = JSON.parse(buildStopOutput(null, true));
      assert.strictEqual(bn.decision, 'block', 'stop null on blocks via shared bucket');
    } finally {
      delete process.env.MUSE_GATE_TEST_STATEDIR;
    }
    console.log('GATE-SELF-TEST PASS cases=21');
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  process.exit(0);
}

let input = '';
process.stdin.on('data', c => { input += c; });
process.stdin.on('end', () => {
  try {
    let hookEvent = '';
    try { hookEvent = String(JSON.parse(input).hook_event_name || ''); } catch (e) { hookEvent = ''; }
    if (hookEvent === 'Stop') {
      let parsed = null;
      try { parsed = JSON.parse(input); } catch (e) { parsed = null; }
      process.stdout.write(buildStopOutput(parsed, museModeOn(settingsPath())));
      return;
    }
    process.stdout.write(buildOutput(runTracker(input), museModeOn(settingsPath())));
  } catch (e) { /* silent */ }
});
