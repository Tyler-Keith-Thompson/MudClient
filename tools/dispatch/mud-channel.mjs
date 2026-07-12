#!/usr/bin/env node
// mud-dispatch-channel: a Claude Code custom "channel" MCP server.
//
// The MudClient game process HTTP POSTs freeform developer feedback (typed in
// the game via `#claude <text>`) plus a path to a context bundle to this
// server. The server, loaded by a running `claude` session as a channel,
// PUSHES that feedback into the session as a channel notification so Claude
// sees it and acts on it. One-way only (game -> Claude); no reply path.
//
// stdout is the MCP stdio transport channel -- NEVER write logs to stdout.
// All logging goes to stderr.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';

const log = (...args) => console.error('[muddispatch]', ...args);

// ---- config -----------------------------------------------------------------

const PORT = parseInt(process.env.MUD_DISPATCH_PORT || '8788', 10);
const HOST = process.env.MUD_DISPATCH_HOST || '127.0.0.1';

function resolveToken() {
  if (process.env.MUD_DISPATCH_TOKEN) {
    log('using token from MUD_DISPATCH_TOKEN env var');
    return process.env.MUD_DISPATCH_TOKEN;
  }
  const tokenPath = path.join(os.homedir(), 'Documents', 'MudClient', 'dispatch.token');
  log('token path:', tokenPath);
  try {
    if (fs.existsSync(tokenPath)) {
      const tok = fs.readFileSync(tokenPath, 'utf8').trim();
      if (tok) {
        log('loaded existing token file');
        return tok;
      }
      log('token file empty; regenerating');
    }
    const tok = crypto.randomBytes(24).toString('hex');
    fs.mkdirSync(path.dirname(tokenPath), { recursive: true });
    fs.writeFileSync(tokenPath, tok, { mode: 0o600 });
    try { fs.chmodSync(tokenPath, 0o600); } catch { /* best effort */ }
    log('generated new token file (mode 0600)');
    return tok;
  } catch (err) {
    log('WARNING: could not read/create token file:', err && err.message);
    const tok = crypto.randomBytes(24).toString('hex');
    log('falling back to an in-memory token (not persisted)');
    return tok;
  }
}

const TOKEN = resolveToken();

// ---- MCP server -------------------------------------------------------------

const INSTRUCTIONS = [
  "Events on the 'muddispatch' channel are freeform developer feedback typed in",
  "the MudClient game via `#claude <text>`. Each arrives as",
  '`<channel source="muddispatch" bundle="/path/to/dispatch.md" dir="/path">FEEDBACK</channel>`.',
  'When one arrives: read the bundle file at the `bundle` path (it contains the',
  'feedback plus a timestamped, interleaved transcript of what the player and the',
  'Lua scripts sent and what the server displayed, and a sibling raw.log), then',
  'act on the feedback -- typically by spawning a subagent to implement or',
  'investigate the requested change in this repo. Treat the feedback as a task to',
  'work, not a message to reply to.',
].join(' ');

const mcp = new Server(
  { name: 'muddispatch', version: '1.0.0' },
  {
    capabilities: {
      experimental: { 'claude/channel': {} },
    },
    instructions: INSTRUCTIONS,
  }
);

// Sanitize meta keys: string->string only, keys restricted to [A-Za-z0-9_].
function cleanMeta(meta) {
  const out = {};
  for (const [k, v] of Object.entries(meta || {})) {
    const key = String(k).replace(/[^A-Za-z0-9_]/g, '');
    if (!key) continue;
    out[key] = v == null ? '' : String(v);
  }
  return out;
}

async function pushChannel(content, meta) {
  await mcp.notification({
    method: 'notifications/claude/channel',
    params: {
      content: String(content),
      meta: cleanMeta(meta),
    },
  });
}

// ---- HTTP listener ----------------------------------------------------------

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(body),
  });
  res.end(body);
}

function readBody(req, limitBytes = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limitBytes) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

async function handleDispatch(req, res) {
  const token = req.headers['x-dispatch-token'];
  if (token !== TOKEN) {
    log('rejected POST /dispatch: bad or missing token');
    sendJson(res, 403, { ok: false, error: 'forbidden' });
    return;
  }

  let raw;
  try {
    raw = await readBody(req);
  } catch (err) {
    sendJson(res, 400, { ok: false, error: 'bad body: ' + (err && err.message) });
    return;
  }

  let payload;
  try {
    payload = JSON.parse(raw || '{}');
  } catch {
    sendJson(res, 400, { ok: false, error: 'malformed JSON' });
    return;
  }

  const feedback = payload && typeof payload.feedback === 'string' ? payload.feedback : '';
  if (!feedback) {
    sendJson(res, 400, { ok: false, error: 'missing feedback' });
    return;
  }
  const bundle = payload && typeof payload.bundle === 'string' ? payload.bundle : '';
  const dir = payload && typeof payload.dir === 'string' ? payload.dir : '';

  try {
    await pushChannel(feedback, { bundle: bundle || '', dir: dir || '' });
    log('dispatched feedback to channel (bundle=' + (bundle || '-') + ')');
    sendJson(res, 200, { ok: true });
  } catch (err) {
    // Expected when no parent MCP client is attached over stdio. Do not crash;
    // report that the dispatch was accepted but not yet deliverable.
    log('notification failed (no MCP peer connected?):', err && err.message);
    sendJson(res, 202, { ok: false, error: 'channel not connected', detail: err && err.message });
  }
}

const httpServer = http.createServer((req, res) => {
  // Wrap so a bad request never crashes the process.
  Promise.resolve()
    .then(() => {
      if (req.method === 'POST' && req.url === '/dispatch') {
        return handleDispatch(req, res);
      }
      sendJson(res, 404, { ok: false, error: 'not found' });
    })
    .catch((err) => {
      log('unhandled request error:', err && err.message);
      try {
        if (!res.headersSent) sendJson(res, 500, { ok: false, error: 'internal error' });
      } catch { /* ignore */ }
    });
});

httpServer.on('error', (err) => {
  log('HTTP server error:', err && err.message);
});

// ---- boot -------------------------------------------------------------------

async function main() {
  const transport = new StdioServerTransport();
  await mcp.connect(transport);
  log('MCP stdio transport connected');

  httpServer.listen(PORT, HOST, () => {
    log(`HTTP listener bound to http://${HOST}:${PORT} (POST /dispatch)`);
  });
}

main().catch((err) => {
  log('fatal:', err && err.stack ? err.stack : err);
  process.exit(1);
});

process.on('uncaughtException', (err) => {
  log('uncaughtException:', err && err.stack ? err.stack : err);
});
process.on('unhandledRejection', (err) => {
  log('unhandledRejection:', err && (err.stack || err.message || err));
});
