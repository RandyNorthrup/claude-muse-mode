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
const { StringDecoder } = require('string_decoder');

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

// Top-level tool fields Meta's endpoint rejects (Anthropic accepts them).
// Separate from input_schema keywords: these live on the tool itself.
// Matched by field, not by tool name: whatever carries max_uses would 400
// at Meta anyway, and Anthropic ignores it on tools that don't use it.
function stripToolFields(tool, noStrip, counts) {
  if (tool && Object.prototype.hasOwnProperty.call(tool, 'max_uses')) {
    counts.max_uses = (counts.max_uses || 0) + 1;
    if (!noStrip) delete tool.max_uses;
  }
}

function isWebSearchTool(tool) {
  const t = tool && typeof tool.type === 'string' ? tool.type : '';
  const n = tool && typeof tool.name === 'string' ? tool.name.toLowerCase() : '';
  return t.startsWith('web_search') || n.includes('websearch') || n.includes('web_search');
}

function sanitizeTools(body, noStrip) {
  const total = {};
  const fields = {};
  if (!body || !Array.isArray(body.tools)) return { body, stripped: total, toolfields: fields, tools: 0 };
  for (const tool of body.tools) {
    if (tool && tool.input_schema) {
      // noStrip: count what WOULD be removed, forward untouched.
      const target = noStrip ? JSON.parse(JSON.stringify(tool.input_schema)) : tool.input_schema;
      const counts = stripSchema(target, {});
      for (const [k, n] of Object.entries(counts)) total[k] = (total[k] || 0) + n;
    }
    if (tool) stripToolFields(tool, noStrip, fields);
  }
  // Meta's web-search execution is broken (400s, then empty results), so
  // drop the tool and let the model fall through to working tools
  // (WebFetch). Counted in toolfields; restorable with
  // MUSE_SHIM_KEEP_WEB_SEARCH=1 if Meta ever fixes their side.
  const keep = process.env.MUSE_SHIM_KEEP_WEB_SEARCH && process.env.MUSE_SHIM_KEEP_WEB_SEARCH !== '0';
  if (!keep) {
    const kept = [];
    let dropped = 0;
    for (const tool of body.tools) {
      if (isWebSearchTool(tool)) {
        dropped++;
        if (noStrip) kept.push(tool);
      } else {
        kept.push(tool);
      }
    }
    if (!noStrip) body.tools = kept;
    if (dropped > 0) fields.web_search_dropped = dropped;
  }
  return { body, stripped: total, toolfields: fields, tools: body.tools.length };
}

// Top-level keys of a parsed request body: protocol vocabulary (model,
// messages, tools, ...), never values. Safe for the summary line.
function topKeys(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return [];
  return Object.keys(value);
}

// Claude Code requests extended thinking, which Muse answers with redacted
// (opaque) blocks the client can only render as noise. Drop the request
// param so no thinking is produced. Restorable with
// MUSE_SHIM_KEEP_THINKING=1 (needs a shim restart to take effect).
function thinkingKept() {
  return !!(process.env.MUSE_SHIM_KEEP_THINKING && process.env.MUSE_SHIM_KEEP_THINKING !== '0');
}

function dropThinkingParam(body, noStrip) {
  const dropped = [];
  if (!thinkingKept() && body && Object.prototype.hasOwnProperty.call(body, 'thinking')) {
    dropped.push('thinking');
    if (!noStrip) delete body.thinking;
  }
  return dropped;
}

// Response thinking filter: drops thinking/redacted_thinking content blocks
// from upstream responses (Meta emits them even unprompted) so clients that
// can't render them stay quiet. Best-effort and fail-open: anything
// unrecognized passes through (SSE line endings normalized to \n, which no
// client distinguishes). Streaming is preserved: non-thinking events are
// forwarded immediately as they complete.
const THINKING_BLOCK_TYPES = new Set(['thinking', 'redacted_thinking']);

function sseFields(lines) {
  let eventType = '';
  const data = [];
  for (const line of lines) {
    if (line.startsWith('event:')) {
      eventType = line.slice(6).trim();
    } else if (line.startsWith('data:')) {
      let v = line.slice(5);
      if (v.startsWith(' ')) v = v.slice(1);
      data.push(v);
    }
  }
  return { eventType, dataText: data.join('\n') };
}

function parseJsonObject(text) {
  try {
    const v = JSON.parse(text);
    if (v && typeof v === 'object' && !Array.isArray(v)) return v;
  } catch (e) { /* fail open at call site */ }
  return null;
}

// Decides one complete SSE event (lines without the trailing blank).
// Returns the text to forward, or null to drop the event.
function filterSseEvent(lines, suppressed) {
  const raw = lines.join('\n') + '\n\n';
  const { eventType, dataText } = sseFields(lines);
  if (eventType !== 'message_start' && !eventType.startsWith('content_block_')) {
    return raw;
  }
  const evt = parseJsonObject(dataText);
  if (!evt) return raw; // fail open: unparseable goes through
  if (eventType === 'content_block_start') {
    const bt = evt.content_block && evt.content_block.type;
    if (THINKING_BLOCK_TYPES.has(bt) && typeof evt.index === 'number') {
      suppressed.add(evt.index);
      return null;
    }
    return raw;
  }
  if (eventType === 'content_block_delta' || eventType === 'content_block_stop') {
    if (typeof evt.index === 'number' && suppressed.has(evt.index)) {
      if (eventType === 'content_block_stop') suppressed.delete(evt.index);
      return null;
    }
    return raw;
  }
  if (eventType === 'message_start' && evt.message && Array.isArray(evt.message.content)) {
    // Spec-conformant servers start with empty content, but filter
    // defensively for servers that inline blocks here.
    const before = evt.message.content.length;
    evt.message.content = evt.message.content.filter(
      (b) => !(b && THINKING_BLOCK_TYPES.has(b.type)));
    if (evt.message.content.length !== before) {
      return `event: message_start\ndata: ${JSON.stringify(evt)}\n\n`;
    }
  }
  return raw;
}

// Incremental SSE filter: push() accepts arbitrary chunk boundaries
// (multi-byte characters decoded safely), forwarding complete
// non-thinking events via onForward as they arrive.
function createSseFilter(onForward) {
  const decoder = new StringDecoder('utf8');
  const suppressed = new Set();
  let buf = '';
  let pending = [];
  function handleEvent() {
    if (pending.length === 0) return;
    const out = filterSseEvent(pending, suppressed);
    pending = [];
    if (out !== null) onForward(out);
  }
  return {
    push(chunk) {
      buf += decoder.write(chunk);
      let idx;
      while ((idx = buf.indexOf('\n')) !== -1) {
        let line = buf.slice(0, idx);
        buf = buf.slice(idx + 1);
        if (line.endsWith('\r')) line = line.slice(0, -1);
        if (line === '') handleEvent();
        else pending.push(line);
      }
    },
    flush() {
      buf += decoder.end();
      handleEvent();
      if (buf.length > 0) {
        // Trailing bytes without a newline: forward verbatim (fail open).
        onForward(buf);
        buf = '';
      }
    },
  };
}

// Drops thinking blocks from a parsed non-streaming response body.
// Returns true when anything was removed.
function stripResponseThinking(obj) {
  if (!obj || !Array.isArray(obj.content)) return false;
  const before = obj.content.length;
  obj.content = obj.content.filter((b) => !(b && THINKING_BLOCK_TYPES.has(b.type)));
  return obj.content.length !== before;
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
          const recvKeys = topKeys(parsed);
          const droppedParams = dropThinkingParam(parsed, noStrip);
          const { body, stripped, toolfields, tools } = sanitizeTools(parsed, noStrip);
          raw = Buffer.from(JSON.stringify(body));
          // Stripping (and re-serializing) changes the body length: the
          // client's original Content-Length would leave the upstream
          // waiting for bytes that never come (hang until timeout), so
          // re-declare the length we actually forward.
          fwdHeaders['content-length'] = String(raw.length);
          logExtra = ` tools=${tools} stripped=${JSON.stringify(stripped)}${noStrip ? ' (count-only)' : ''}`;
          if (Object.keys(toolfields).length > 0) {
            logExtra += ` toolfields=${JSON.stringify(toolfields)}`;
          }
          logExtra += ` params=[${recvKeys.join(',')}]`;
          if (droppedParams.length > 0) {
            logExtra += ` dropped_params=[${droppedParams.join(',')}]`;
          }
        } catch (e) {
          // Not parseable JSON: forward untouched.
          logExtra = ' unparsed-passthrough';
        }
      }
      const stamp = new Date().toISOString();
      process.stdout.write(`${stamp} ${clientReq.method} ${clientReq.url}${logExtra}\n`);

      const t0 = Date.now();
      const upstreamReq = requestFn({
        hostname: target.hostname,
        port: target.port || (secure ? 443 : 80),
        path: clientReq.url,
        method: clientReq.method,
        headers: fwdHeaders,
      });
      upstreamReq.on('response', (upstreamRes) => {
        process.stdout.write(`${new Date().toISOString()} <- ${upstreamRes.statusCode} ${clientReq.url} ${Date.now() - t0}ms\n`);
        const resHeaders = hopHeaders(upstreamRes.headers);
        const rtype = String(upstreamRes.headers['content-type'] || '');
        const ok2xx = upstreamRes.statusCode >= 200 && upstreamRes.statusCode < 300;
        const filtering = !thinkingKept() && !noStrip && ok2xx &&
          (rtype.includes('text/event-stream') || rtype.includes('application/json'));
        if (!filtering) {
          clientRes.writeHead(upstreamRes.statusCode, resHeaders);
          upstreamRes.pipe(clientRes);
          return;
        }
        clientRes.on('close', () => upstreamRes.destroy());
        if (rtype.includes('text/event-stream')) {
          // Length unknowable until the stream ends: drop any declared
          // length and let Node chunk the filtered stream.
          delete resHeaders['content-length'];
          clientRes.writeHead(upstreamRes.statusCode, resHeaders);
          const filter = createSseFilter((text) => {
            if (!clientRes.write(text)) upstreamRes.pause();
          });
          clientRes.on('drain', () => upstreamRes.resume());
          upstreamRes.on('data', (c) => filter.push(c));
          upstreamRes.on('end', () => { filter.flush(); clientRes.end(); });
          return;
        }
        // Non-streaming JSON: buffer, filter, re-declare the exact
        // length (mirror of the request-side fix).
        const chunks = [];
        upstreamRes.on('data', (c) => chunks.push(c));
        upstreamRes.on('end', () => {
          let out = Buffer.concat(chunks);
          try {
            const parsed = JSON.parse(out.toString('utf8'));
            stripResponseThinking(parsed);
            out = Buffer.from(JSON.stringify(parsed));
          } catch (e) { /* unparseable: forward untouched */ }
          resHeaders['content-length'] = String(out.length);
          clientRes.writeHead(upstreamRes.statusCode, resHeaders);
          clientRes.end(out);
        });
      });
      upstreamReq.on('error', (e) => {
        process.stdout.write(`${new Date().toISOString()} <- ERR ${clientReq.url} ${Date.now() - t0}ms ${e.message}\n`);
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
async function relaySseSelfTest() {
  const assert = require('assert');
  const thinkSaved = process.env.MUSE_SHIM_KEEP_THINKING;
  delete process.env.MUSE_SHIM_KEEP_THINKING;
  try {
    const events = [
      'event: message_start',
      'data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[]}}',
      '',
      'event: content_block_start',
      'data: {"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"opaque"}}',
      '',
      'event: content_block_stop',
      'data: {"type":"content_block_stop","index":0}',
      '',
      'event: content_block_start',
      'data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}',
      '',
      'event: content_block_delta',
      'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"hello-sse"}}',
      '',
      'event: content_block_stop',
      'data: {"type":"content_block_stop","index":1}',
      '',
      'event: message_stop',
      'data: {"type":"message_stop"}',
      '',
    ].join('\n');
    const upstream = http.createServer((req, res) => {
      res.writeHead(200, { 'content-type': 'text/event-stream', connection: 'close' });
      const bytes = Buffer.from(events, 'utf8');
      let i = 0;
      const timer = setInterval(() => {
        const end = Math.min(i + 11, bytes.length);
        res.write(bytes.slice(i, end));
        i = end;
        if (i >= bytes.length) {
          clearInterval(timer);
          res.end();
        }
      }, 5);
    });
    await new Promise((r) => upstream.listen(0, '127.0.0.1', r));
    const upPort = upstream.address().port;
    const shim = startServer(0, `http://127.0.0.1:${upPort}`, false);
    await new Promise((r) => shim.on('listening', r));
    const shimPort = shim.address().port;
    const collected = await new Promise((resolve, reject) => {
      const req = http.request({
        hostname: '127.0.0.1', port: shimPort, path: '/v1/messages', method: 'POST',
        headers: { 'content-type': 'application/json', 'content-length': 2 },
        timeout: 5000,
      }, (res) => {
        let data = '';
        res.on('data', (c) => { data += c; });
        res.on('end', () => resolve({ status: res.statusCode, body: data }));
      });
      req.on('timeout', () => { req.destroy(); reject(new Error('sse relay timed out')); });
      req.on('error', reject);
      req.end('{}');
    });
    assert.strictEqual(collected.status, 200);
    assert.ok(collected.body.includes('hello-sse'), 'sse text forwarded');
    assert.strictEqual(collected.body.includes('redacted_thinking'), false, 'sse thinking filtered');
    assert.ok(collected.body.includes('message_stop'), 'sse framing intact');
    await new Promise((r) => {
      let n = 0;
      const done = () => { if (++n === 2) r(); };
      shim.close(done);
      upstream.close(done);
    });
    process.stdout.write('RELAY-SSE-TEST PASS\n');
  } finally {
    if (thinkSaved !== undefined) process.env.MUSE_SHIM_KEEP_THINKING = thinkSaved;
  }
}

async function relaySelfTest() {
  const assert = require('assert');
  // The keep flags would preserve what this test drops; stash them.
  const keepSaved = process.env.MUSE_SHIM_KEEP_WEB_SEARCH;
  delete process.env.MUSE_SHIM_KEEP_WEB_SEARCH;
  const thinkSaved = process.env.MUSE_SHIM_KEEP_THINKING;
  delete process.env.MUSE_SHIM_KEEP_THINKING;
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
      let tMaxUsesPresent = null;
      let wsPresent = null;
      let thinkingPresent = null;
      try {
        const seen = JSON.parse(body.toString('utf8'));
        const t = (seen.tools || []).find((x) => x && x.name === 't');
        tMaxUsesPresent = !!t && Object.prototype.hasOwnProperty.call(t, 'max_uses');
        wsPresent = (seen.tools || []).some((x) => x && x.type === 'web_search_20250305');
        thinkingPresent = Object.prototype.hasOwnProperty.call(seen, 'thinking');
      } catch (e) { /* nulls fail the asserts below honestly */ }
      res.writeHead(200, { 'content-type': 'application/json', connection: 'close' });
      res.end(JSON.stringify({
        got: body.length,
        declared,
        stripped: !body.toString('utf8').includes('pattern'),
        tMaxUsesPresent,
        wsPresent,
        thinkingPresent,
        content: [
          { type: 'text', text: 'ok-json' },
          { type: 'thinking', thinking: 'x' },
          { type: 'redacted_thinking', data: 'y' },
        ],
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
    thinking: { type: 'enabled', budget_tokens: 100 },
    messages: [{ role: 'user', content: 'hi' }],
    tools: [
      { name: 't', max_uses: 9, input_schema: { type: 'object', properties: { p: { type: 'string', pattern: '^a+$' } } } },
      { type: 'web_search_20250305', name: 'web_search', max_uses: 5 },
    ],
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
  assert.strictEqual(result.body.tMaxUsesPresent, false, 'max_uses stripped in flight');
  assert.strictEqual(result.body.wsPresent, false, 'web_search dropped in flight');
  assert.strictEqual(result.body.thinkingPresent, false, 'thinking dropped in flight');
  assert.strictEqual(result.body.content.length, 1, 'thinking blocks filtered from JSON response');
  assert.strictEqual(result.body.content[0].text, 'ok-json');
  await new Promise((r) => {
    let n = 0;
    const done = () => { if (++n === 2) r(); };
    shim.close(done);
    upstream.close(done);
  });
  if (keepSaved !== undefined) process.env.MUSE_SHIM_KEEP_WEB_SEARCH = keepSaved;
  if (thinkSaved !== undefined) process.env.MUSE_SHIM_KEEP_THINKING = thinkSaved;
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
  const wsBody = { tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 5 }] };
  const wsOut = sanitizeTools(JSON.parse(JSON.stringify(wsBody)), false);
  assert.strictEqual(wsOut.tools, 0, 'broken web_search dropped');
  assert.strictEqual(wsOut.body.tools.length, 0);
  assert.strictEqual(wsOut.toolfields.max_uses, 1, 'toolfields counted');
  assert.strictEqual(wsOut.toolfields.web_search_dropped, 1, 'drop counted');
  const oddBody = { tools: [{ name: 'WebSearch', max_uses: 3 }] };
  const oddOut = sanitizeTools(JSON.parse(JSON.stringify(oddBody)), false);
  assert.strictEqual(oddOut.body.tools.length, 0, 'drop matches whatever the shape');
  assert.strictEqual(oddOut.toolfields.web_search_dropped, 1);
  const wsFrozen = JSON.parse(JSON.stringify(wsBody));
  const wsCounted = sanitizeTools(wsFrozen, true);
  assert.strictEqual(wsCounted.toolfields.max_uses, 1, 'no-strip counts toolfields');
  assert.strictEqual(wsCounted.toolfields.web_search_dropped, 1, 'no-strip counts the drop');
  assert.strictEqual(wsFrozen.tools.length, 1, 'no-strip forwards untouched');
  assert.strictEqual('max_uses' in wsFrozen.tools[0], true, 'no-strip leaves max_uses');
  process.env.MUSE_SHIM_KEEP_WEB_SEARCH = '1';
  try {
    const keepOut = sanitizeTools(JSON.parse(JSON.stringify(wsBody)), false);
    assert.strictEqual(keepOut.body.tools.length, 1, 'keep flag preserves web_search');
    assert.strictEqual('web_search_dropped' in keepOut.toolfields, false, 'keep flag counts no drop');
  } finally {
    delete process.env.MUSE_SHIM_KEEP_WEB_SEARCH;
  }
  assert.deepStrictEqual(topKeys({ b: 1, a: 2 }), ['b', 'a'], 'topKeys lists names only');
  assert.deepStrictEqual(topKeys(null), []);
  assert.deepStrictEqual(topKeys([1, 2]), []);
  const thinkBody = { thinking: { type: 'enabled', budget_tokens: 1000 }, model: 'x' };
  const thinkGone = JSON.parse(JSON.stringify(thinkBody));
  assert.deepStrictEqual(dropThinkingParam(thinkGone, false), ['thinking']);
  assert.strictEqual('thinking' in thinkGone, false, 'thinking param removed');
  assert.strictEqual(thinkGone.model, 'x', 'sibling params preserved');
  const thinkFrozen = JSON.parse(JSON.stringify(thinkBody));
  assert.deepStrictEqual(dropThinkingParam(thinkFrozen, true), ['thinking'], 'no-strip counts the drop');
  assert.strictEqual('thinking' in thinkFrozen, true, 'no-strip leaves thinking');
  process.env.MUSE_SHIM_KEEP_THINKING = '1';
  try {
    const keepThink = JSON.parse(JSON.stringify(thinkBody));
    assert.deepStrictEqual(dropThinkingParam(keepThink, false), [], 'keep flag preserves thinking');
    assert.strictEqual('thinking' in keepThink, true);
  } finally {
    delete process.env.MUSE_SHIM_KEEP_THINKING;
  }
  assert.deepStrictEqual(dropThinkingParam({}, false), []);
  assert.deepStrictEqual(dropThinkingParam(null, false), []);
  // --- Response SSE filter ---
  const sseTranscript =
    'event: message_start\n' +
    'data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[]}}\n' +
    '\n' +
    'event: content_block_start\n' +
    'data: {"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"opaque"}}\n' +
    '\n' +
    'event: content_block_stop\n' +
    'data: {"type":"content_block_stop","index":0}\n' +
    '\n' +
    'event: content_block_start\n' +
    'data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}\n' +
    '\n' +
    'event: content_block_delta\n' +
    'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"hi"}}\n' +
    '\n' +
    'event: content_block_stop\n' +
    'data: {"type":"content_block_stop","index":1}\n' +
    '\n' +
    'event: message_stop\n' +
    'data: {"type":"message_stop"}\n' +
    '\n';
  function runSseFilter(text, chunkSize) {
    let out = '';
    const f = createSseFilter((s) => { out += s; });
    for (let i = 0; i < text.length; i += chunkSize) {
      f.push(Buffer.from(text.slice(i, i + chunkSize), 'utf8'));
    }
    f.flush();
    return out;
  }
  const sseOnce = runSseFilter(sseTranscript, 1000000);
  assert.strictEqual(sseOnce.includes('redacted_thinking'), false, 'redacted block dropped from SSE');
  assert.ok(sseOnce.includes('"text":"hi"'), 'text delta preserved');
  assert.ok(sseOnce.includes('message_stop'), 'framing events preserved');
  assert.strictEqual(runSseFilter(sseTranscript, 7), sseOnce, 'chunk boundaries do not matter');
  const umlaut = 'event: content_block_delta\ndata: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Grüße"}}\n\n';
  const umBytes = Buffer.from(umlaut, 'utf8');
  let umOut = '';
  const umFilter = createSseFilter((s) => { umOut += s; });
  for (let i = 0; i < umBytes.length; i += 1) umFilter.push(umBytes.slice(i, i + 1));
  umFilter.flush();
  assert.ok(umOut.includes('Grüße'), 'multi-byte chars survive chunk splits');
  const thinkTranscript =
    'event: content_block_start\n' +
    'data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"hmm"}}\n' +
    '\n' +
    'event: content_block_delta\n' +
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" more"}}\n' +
    '\n' +
    'event: content_block_delta\n' +
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}\n' +
    '\n' +
    'event: content_block_stop\n' +
    'data: {"type":"content_block_stop","index":0}\n' +
    '\n' +
    ': keep-alive ping\n' +
    '\n' +
    'event: content_block_delta\n' +
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"STALE"}}\n' +
    '\n';
  const thinkOut = runSseFilter(thinkTranscript, 1000000);
  assert.strictEqual(thinkOut.includes('thinking_delta'), false, 'thinking deltas dropped');
  assert.strictEqual(thinkOut.includes('signature_delta'), false, 'signature deltas dropped');
  assert.ok(thinkOut.includes('keep-alive'), 'comments forwarded');
  assert.ok(thinkOut.includes('STALE'), 'index reuse after stop is forwarded');
  const badTranscript = 'event: content_block_delta\ndata: not-json{{{\n\n';
  assert.ok(runSseFilter(badTranscript, 1000000).includes('not-json'), 'malformed events pass through');
  const msTranscript =
    'event: message_start\n' +
    'data: {"type":"message_start","message":{"id":"m","content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"y"}]}}\n' +
    '\n';
  const msOut = runSseFilter(msTranscript, 1000000);
  assert.strictEqual(msOut.includes('"thinking"'), false, 'inlined thinking filtered');
  assert.ok(msOut.includes('"text":"y"'), 'sibling content preserved');
  const rj = { content: [{ type: 'text', text: 'a' }, { type: 'thinking', thinking: 'b' }, { type: 'redacted_thinking', data: 'c' }] };
  assert.strictEqual(stripResponseThinking(rj), true);
  assert.deepStrictEqual(rj.content, [{ type: 'text', text: 'a' }]);
  assert.strictEqual(stripResponseThinking({ content: [{ type: 'text', text: 'a' }] }), false);
  assert.strictEqual(stripResponseThinking({}), false);
  assert.strictEqual(stripResponseThinking(null), false);
  process.stdout.write(`SELF-TEST PASS tools=1 stripped=${JSON.stringify(stripped)}\n`);
  await relaySelfTest();
  await relaySseSelfTest();
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
