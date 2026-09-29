#!/usr/bin/env node
// muse-gate — UserPromptSubmit dispatcher shipped with claude-muse-mode.
// Runs the previous tracker hook (default: caveman-mode-tracker.js beside
// this file, override with MUSE_GATE_TRACKER_CMD), then appends the
// anti-stall reminder ONLY while Muse mode is on. Claude mode gets the
// tracker's output untouched, so no Muse accommodation leaks across modes.
// Silent-fail: never blocks a prompt. `node muse-gate.js --self-test`
// exercises the merge table with temp fixtures (no network, no settings).
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

const REMINDER = 'MUSE MODE: finish the turn chain. When task steps remain, ' +
  'keep calling tools — never end a turn on a status line promising the ' +
  'next step. Batch independent tool calls in one block; prose only when ' +
  'done or blocked.';

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
    console.log('GATE-SELF-TEST PASS cases=13');
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  process.exit(0);
}

let input = '';
process.stdin.on('data', c => { input += c; });
process.stdin.on('end', () => {
  try {
    process.stdout.write(buildOutput(runTracker(input), museModeOn(settingsPath())));
  } catch (e) { /* silent */ }
});
