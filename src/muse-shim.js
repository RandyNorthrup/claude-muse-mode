// muse-shim: localhost forward proxy that makes Claude Code's built-in tool
// schemas pass Meta's strict JSON-Schema validator.
//
// Problem: Claude Code ships tools (notably the built-in Artifact tool) whose
// input schemas use keywords outside the strict subset (pattern, minLength,
// maxLength, ...). Anthropic's API accepts them; Meta's endpoint answers
// 400 Invalid JSON schema, failing every interactive turn. Print mode works
// only because it sends no such tools.
//
// Fix: point ANTHROPIC_BASE_URL at this shim. It removes the forbidden
// keywords from tools[].input_schema, forwards everything else byte-identical
// to the upstream, and streams responses back untouched. The CLI still
// validates tool inputs locally against its original schemas, so no
// constraint is actually lost - the upstream just isn't asked to.
//
// What this shim NEVER does: it never logs bodies, headers, or keys (one
// summary line per request: path, tool count, stripped keywords). The API key
// passes through as an opaque header; the shim stores nothing.
//
// stdlib only. `node muse-shim.js [--self-test] [--port N] [--upstream URL]`
'use strict';
const http = require('http');
const https = require('https');

const DEFAULT_PORT = 15555;
const DEFAULT_UPSTREAM = 'https://api.meta.ai';
// Keywords outside the strict subset (Anthropic strict tool-use documents
// these as unsupported: length/size bounds, numeric bounds, pattern, format).
// Stripped recursively from tools[].input_schema only - never from messages.
const STRIP_KEYS = new Set([
  'pattern', 'minLength', 'maxLength',
  'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'multipleOf',
  'minItems', 'maxItems', 'uniqueItems', 'format',
]);
const MAX_BODY_BYTES = 1024 * 1024 * 1024; // 1 GiB; larger -> clear 413.

function parseArgs(argv) {
  const out = { port: DEFAULT_PORT, upstream: DEFAULT_UPSTREAM, selfTest: false, noStrip: false, ensure: false, stop: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--self-test') out.selfTest = true;
    else if (argv[i] === '--ensure') out.ensure = true;
    else if (argv[i] === '--stop') out.stop = true;
    else if (argv[i] === '--no-strip') out.noStrip = true;
    else if (argv[i] === '--port' && argv[i + 1]) out.port = Number(argv[++i]);
    else if (argv[i] === '--upstream' && argv[i + 1]) out.upstream = argv[++i];
  }
  if (process.env.MUSE_SHIM_PORT) out.port = Number(process.env.MUSE_SHIM_PORT);
  if (process.env.MUSE_SHIM_UPSTREAM) out.upstream = process.env.MUSE_SHIM_UPSTREAM;
  if (process.env.MUSE_SHIM_NO_STRIP) out.noStrip = true;
  return out;
}

// Returns {stripped: {key: count}}; mutates node in place.
function stripSchema(node, counts) {
  if (Array.isArray(node)) {
    for (const item of node) stripSchema(item, counts);
    return counts;
  }
  if (node !== null && typeof node === 'object') {
    for (const key of Object.keys(node)) {
      if (STRIP_KEYS.has(key)) {
        counts[key] = (counts[key] || 0) + 1;
        delete node[key];
      } else {
        stripSchema(node[key], counts);
      }
    }
  }
  return counts;
}

function sanitizeTools(body, noStrip) {
  const total = {};
  if (!body || !Array.isArray(body.tools)) return { body, stripped: total, tools: 0 };
  for (const tool of body.tools) {
    if (tool && tool.input_schema) {
      // noStrip: count what WOULD be removed, forward untouched.
      const target = noStrip ? JSON.parse(JSON.stringify(tool.input_schema)) : tool.input_schema;
      const counts = stripSchema(target, {});
      for (const [k, n] of Object.entries(counts)) total[k] = (total[k] || 0) + n;
    }
  }
  return { body, stripped: total, tools: body.tools.length };
}

function hopHeaders(headers) {
  const out = { ...headers };
  for (const h of ['connection', 'keep-alive', 'transfer-encoding', 'upgrade', 'proxy-authenticate', 'trailer']) {
    delete out[h];
  }
  return out;
}

function startServer(port, upstream, noStrip) {
  const target = new URL(upstream);
  const secure = target.protocol === 'https:';
  const requestFn = secure ? https.request : http.request;

  const server = http.createServer((clientReq, clientRes) => {
    if (clientReq.method === 'GET' && clientReq.url === '/health') {
      clientRes.writeHead(200, { 'content-type': 'application/json' });
      clientRes.end(JSON.stringify({ status: 'ok', upstream }));
      return;
    }

    const chunks = [];
    let size = 0;
    let tooLarge = false;
    clientReq.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY_BYTES) tooLarge = true;
      else chunks.push(c);
    });
    clientReq.on('end', () => {
      if (tooLarge) {
        clientRes.writeHead(413, { 'content-type': 'application/json' });
        clientRes.end(JSON.stringify({ error: 'request body exceeds 1 GiB cap' }));
        return;
      }
      let raw = Buffer.concat(chunks);
      const ctype = String(clientReq.headers['content-type'] || '');
      let logExtra = '';
      const fwdHeaders = hopHeaders({ ...clientReq.headers, host: target.host });
      if (raw.length > 0 && ctype.includes('application/json')) {
        try {
          const parsed = JSON.parse(raw.toString('utf8'));
          const { body, stripped, tools } = sanitizeTools(parsed, noStrip);
          raw = Buffer.from(JSON.stringify(body));
          // Stripping (and re-serializing) changes the body length: the
          // client's original Content-Length would leave the upstream
          // waiting for bytes that never come (hang until timeout), so
          // re-declare the length we actually forward.
          fwdHeaders['content-length'] = String(raw.length);
          logExtra = ` tools=${tools} stripped=${JSON.stringify(stripped)}${noStrip ? ' (count-only)' : ''}`;
        } catch (e) {
          // Not parseable JSON: forward untouched.
          logExtra = ' unparsed-passthrough';
        }
      }
      const stamp = new Date().toISOString();
      process.stdout.write(`${stamp} ${clientReq.method} ${clientReq.url}${logExtra}\n`);

      const upstreamReq = requestFn({
        hostname: target.hostname,
        port: target.port || (secure ? 443 : 80),
        path: clientReq.url,
        method: clientReq.method,
        headers: fwdHeaders,
      });
      upstreamReq.on('response', (upstreamRes) => {
        clientRes.writeHead(upstreamRes.statusCode, hopHeaders(upstreamRes.headers));
        upstreamRes.pipe(clientRes);
      });
      upstreamReq.on('error', (e) => {
        if (!clientRes.headersSent) {
          clientRes.writeHead(502, { 'content-type': 'application/json' });
        }
        clientRes.end(JSON.stringify({ error: `upstream unreachable: ${e.message}` }));
      });
      upstreamReq.end(raw);
    });
  });

  server.listen(port, '127.0.0.1', () => {
    process.stdout.write(`muse-shim listening on 127.0.0.1:${port} -> ${upstream}${noStrip ? ' [no-strip]' : ''}\n`);
  });
  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => server.close(() => process.exit(0)));
  }
  return server;
}

// Relay self-test: a strip-triggering POST with an explicit Content-Length
// (what Claude Code sends) through the real server path into a dummy
// upstream that waits for the full declared body. Catches the hang where
// the shim forwarded the stripped body under the original (longer)
// Content-Length: the upstream then waits for bytes that never come.
// Localhost only, stdlib only, bounded (~2s red on regression).
async function relaySelfTest() {
  const assert = require('assert');
  const upstream = http.createServer((req, res) => {
    const declared = Number(req.headers['content-length'] || 0);
    const chunks = [];
    const timer = setTimeout(() => {
      res.writeHead(408, { 'content-type': 'application/json', connection: 'close' });
      res.end(JSON.stringify({ error: 'body incomplete', got: Buffer.concat(chunks).length, declared }));
    }, 2000);
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      clearTimeout(timer);
      const body = Buffer.concat(chunks);
      res.writeHead(200, { 'content-type': 'application/json', connection: 'close' });
      res.end(JSON.stringify({
        got: body.length,
        declared,
        stripped: !body.toString('utf8').includes('pattern'),
      }));
    });
  });
  await new Promise((r) => upstream.listen(0, '127.0.0.1', r));
  const upPort = upstream.address().port;

  const shim = startServer(0, `http://127.0.0.1:${upPort}`, false);
  await new Promise((r) => shim.on('listening', r));
  const shimPort = shim.address().port;

  const payload = JSON.stringify({
    model: 'x', max_tokens: 5,
    messages: [{ role: 'user', content: 'hi' }],
    tools: [{ name: 't', input_schema: { type: 'object', properties: { p: { type: 'string', pattern: '^a+$' } } } }],
  });
  const result = await new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1', port: shimPort, path: '/v1/messages?beta=true', method: 'POST',
      headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) },
      timeout: 5000,
    }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(data) }));
    });
    req.on('timeout', () => { req.destroy(); reject(new Error('shim relay timed out')); });
    req.on('error', reject);
    req.end(payload);
  });
  assert.strictEqual(result.status, 200, 'upstream answered 200 (body completed)');
  assert.strictEqual(result.body.got, result.body.declared, 'declared length matches received bytes');
  assert.strictEqual(result.body.stripped, true, 'pattern was stripped in flight');
  await new Promise((r) => {
    let n = 0;
    const done = () => { if (++n === 2) r(); };
    shim.close(done);
    upstream.close(done);
  });
  process.stdout.write(`RELAY-TEST PASS got=${result.body.got}\n`);
}

// Self-test: the exact schema Meta rejected, plus nesting. No network.
async function selfTest() {
  const assert = require('assert');
  const rejected = {
    maxLength: 1024, minLength: 1, pattern: '^[^\0]*$', type: 'string',
  };
  const body = {
    model: 'x',
    messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
    tools: [{
      name: 'Artifact',
      input_schema: {
        type: 'object',
        properties: {
          root: { ...rejected, description: 'Base directory' },
          files: {
            anyOf: [
              { type: 'array', items: { type: 'string', minLength: 1, maxLength: 512 } },
              { type: 'object', additionalProperties: { type: 'string', pattern: '^a+$' } },
            ],
          },
          keep: { type: 'integer', minimum: 0, default: 3 },
        },
        required: ['root'],
      },
    }],
  };
  const before = JSON.stringify(body);
  const { body: out, stripped, tools } = sanitizeTools(JSON.parse(before));
  assert.strictEqual(tools, 1);
  const schema = out.tools[0].input_schema;
  assert.deepStrictEqual(
    schema.properties.root,
    { type: 'string', description: 'Base directory' },
    'root keeps type+description, loses min/maxLength+pattern',
  );
  assert.strictEqual(schema.properties.files.anyOf[0].items.maxLength, undefined);
  assert.strictEqual(schema.properties.files.anyOf[1].additionalProperties.pattern, undefined);
  assert.strictEqual(schema.properties.keep.minimum, undefined);
  assert.strictEqual(schema.properties.keep.default, 3, 'default is preserved');
  assert.strictEqual(schema.required[0], 'root');
  assert.deepStrictEqual(out.messages[0].content[0], { type: 'text', text: 'hi' }, 'messages untouched');
  assert.ok(stripped.pattern >= 2 && stripped.minLength >= 2 && stripped.maxLength >= 2, 'counts reported');
  const frozen = JSON.parse(before);
  const counted = sanitizeTools(frozen, true);
  assert.ok(counted.stripped.pattern >= 2, 'no-strip counts without mutating');
  assert.deepStrictEqual(
    frozen.tools[0].input_schema.properties.root,
    { ...rejected, description: 'Base directory' },
    'no-strip leaves the schema untouched',
  );
  process.stdout.write(`SELF-TEST PASS tools=1 stripped=${JSON.stringify(stripped)}\n`);
  await relaySelfTest();
}

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

function scriptDir() { return __dirname; }
function pidFile() {
  return process.env.MUSE_SHIM_PIDFILE || path.join(scriptDir(), 'muse-shim.pid');
}
function logFile() {
  return process.env.MUSE_SHIM_LOG || path.join(scriptDir(), 'muse-shim.log');
}
function baseUrl(port) { return `http://127.0.0.1:${port}`; }

function healthCheck(port) {
  return new Promise((resolve) => {
    const req = http.get(`${baseUrl(port)}/health`, { timeout: 3000 }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        try {
          resolve(res.statusCode === 200 && JSON.parse(data).status === 'ok');
        } catch (e) { resolve(false); }
      });
    });
    req.on('error', () => resolve(false));
    req.on('timeout', () => { req.destroy(); resolve(false); });
  });
}

function pidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return false; }
}

async function ensure(port, upstream, noStrip) {
  let pid = 0;
  try { pid = Number(fs.readFileSync(pidFile(), 'utf8').trim()); } catch (e) { pid = 0; }
  if (pid > 0 && pidAlive(pid) && await healthCheck(port)) {
    process.stdout.write(`${baseUrl(port)}\n`);
    return;
  }
  if (await healthCheck(port)) {
    // Adopt a shim started outside --ensure (no pid to manage).
    process.stdout.write(`${baseUrl(port)}\n`);
    return;
  }
  const logFd = fs.openSync(logFile(), 'a');
  const args = [__filename, '--port', String(port)];
  if (upstream !== DEFAULT_UPSTREAM) args.push('--upstream', upstream);
  if (noStrip) args.push('--no-strip');
  const child = spawn(process.execPath, args, { detached: true, stdio: ['ignore', logFd, logFd] });
  child.unref();
  fs.writeFileSync(pidFile(), String(child.pid));
  for (let i = 0; i < 50; i++) {
    if (await healthCheck(port)) {
      process.stdout.write(`${baseUrl(port)}\n`);
      return;
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`shim did not answer on ${baseUrl(port)} (see ${logFile()})`);
}

async function stopShim() {
  let pid = 0;
  try { pid = Number(fs.readFileSync(pidFile(), 'utf8').trim()); } catch (e) { pid = 0; }
  if (pid > 0 && pidAlive(pid)) {
    try { process.kill(pid); } catch (e) { /* already gone */ }
    process.stdout.write('shim stopped\n');
  } else {
    process.stdout.write('shim not running\n');
  }
  try { fs.unlinkSync(pidFile()); } catch (e) { /* no pid file */ }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.selfTest) {
    await selfTest();
  } else if (args.stop) {
    await stopShim();
  } else if (args.ensure) {
    await ensure(args.port, args.upstream, args.noStrip);
  } else {
    startServer(args.port, args.upstream, args.noStrip);
  }
}

main().catch((e) => { process.stderr.write(`muse-shim: ${e.message}\n`); process.exit(1); });

// Self-test: the exact schema Meta rejected, plus nesting. No network.
