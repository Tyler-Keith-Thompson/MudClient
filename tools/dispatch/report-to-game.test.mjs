#!/usr/bin/env node
// Minimal harness for report_to_game's file-inbox reply path. No live MCP client:
// we import the exported writeReport() from the server module and assert the JSON
// reply file lands in the inbox with the right fields.
//
//   node tools/dispatch/report-to-game.test.mjs

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mud-inbox-test-'));
process.env.MUD_DISPATCH_INBOX = tmp;

const { writeReport } = await import('./mud-channel.mjs');

// 1. message + action -> file exists, 0600, parses, has all fields.
const file = writeReport({ message: 'reload done', action: '#reload' });
assert.ok(fs.existsSync(file), 'reply file written');
assert.ok(file.startsWith(tmp), 'reply file in inbox dir');
assert.match(file, /\.json$/, 'reply file is .json');
const mode = fs.statSync(file).mode & 0o777;
assert.equal(mode, 0o600, `reply file mode 0600 (got ${mode.toString(8)})`);
const obj = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.equal(obj.message, 'reload done');
assert.equal(obj.action, '#reload');
assert.ok(typeof obj.ts === 'string' && obj.ts.length > 0, 'ts is ISO string');
assert.ok(!Number.isNaN(Date.parse(obj.ts)), 'ts parses as a date');

// 2. no action -> action defaults to "".
const file2 = writeReport({ message: 'investigated, nothing to change' });
const obj2 = JSON.parse(fs.readFileSync(file2, 'utf8'));
assert.equal(obj2.action, '', 'absent action defaults to empty string');

// 3. two writes produce distinct files (no clobber).
assert.notEqual(file, file2, 'distinct reply files');
assert.equal(fs.readdirSync(tmp).filter((f) => f.endsWith('.json')).length, 2);

fs.rmSync(tmp, { recursive: true, force: true });
console.log('report-to-game.test: OK');
