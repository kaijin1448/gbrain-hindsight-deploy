#!/usr/bin/env node
// merge-mcp.mjs — string-aware, comment-preserving JSONC member merge.
//
// Inserts (or updates) the "gbrain" block inside the top-level "mcp" object of
// an opencode.jsonc file WITHOUT reformatting the rest of the file and WITHOUT
// destroying user comments. Runs under both `node` and `bun` (plain ESM, no deps).
//
// Usage:
//   node merge-mcp.mjs --file <opencode.jsonc> [--fragment <fragment.jsonc>]
//                      [--key gbrain] [--replace] [--dry-run] [--no-backup]
//
// Modes:
//   default      keep an existing different value untouched (report KEPT)
//   --replace    overwrite an existing different value
//
// Exit codes: 0 ok (incl. no-op), 1 environment error, 2 invalid target.

import { readFileSync, writeFileSync, copyFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// ------------------------------------------------------------------ args
const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const arg = (f, d) => {
  const i = argv.indexOf(f);
  return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : d;
};

const FILE = arg('--file', '');
const KEY = arg('--key', 'gbrain');
const DRY = has('--dry-run');
const REPLACE = has('--replace');
const NO_BACKUP = has('--no-backup');
const HERE = dirname(fileURLToPath(import.meta.url));
const FRAGMENT = arg('--fragment', resolve(HERE, '..', 'templates', 'opencode-mcp.fragment.jsonc'));

if (!FILE) { console.error('ERROR: --file <opencode.jsonc> is required'); process.exit(1); }

// ------------------------------------------------------------------ JSONC scanner
// All helpers treat text as opaque; strings and comments never confuse the scan.

function skipWsComments(t, i) {
  for (;;) {
    while (i < t.length && (t[i] === ' ' || t[i] === '\t' || t[i] === '\r' || t[i] === '\n')) i++;
    if (t[i] === '/' && t[i + 1] === '/') {
      while (i < t.length && t[i] !== '\n') i++;
      continue;
    }
    if (t[i] === '/' && t[i + 1] === '*') {
      const end = t.indexOf('*/', i + 2);
      i = end === -1 ? t.length : end + 2;
      continue;
    }
    return i;
  }
}

function readString(t, i) {
  if (t[i] !== '"') throw new Error(`expected string at offset ${i}`);
  let j = i + 1;
  while (j < t.length) {
    const c = t[j];
    if (c === '\\') { j += 2; continue; }
    if (c === '"') return { value: JSON.parse(t.slice(i, j + 1)), end: j + 1 };
    j++;
  }
  throw new Error('unterminated string');
}

function findValueEnd(t, i) {
  const c = t[i];
  if (c === '{' || c === '[') {
    let depth = 0;
    while (i < t.length) {
      const ch = t[i];
      if (ch === '"') { i = readString(t, i).end; continue; }
      if (ch === '/' && (t[i + 1] === '/' || t[i + 1] === '*')) { i = skipWsComments(t, i); continue; }
      if (ch === '{' || ch === '[') depth++;
      else if (ch === '}' || ch === ']') { depth--; if (depth === 0) return i + 1; }
      i++;
    }
    throw new Error('unterminated object/array');
  }
  if (c === '"') return readString(t, i).end;
  let j = i;
  while (j < t.length && !',}] \t\r\n'.includes(t[j])) j++;
  return j;
}

/** Members of the object whose first '{' is at objStart. */
function members(t, objStart) {
  const out = [];
  let i = skipWsComments(t, objStart + 1);
  if (t[i] === '}') return { members: out, close: i };
  for (;;) {
    const keyTok = readString(t, i);
    let j = skipWsComments(t, keyTok.end);
    if (t[j] !== ':') throw new Error(`expected ':' after key "${keyTok.value}" at ${j}`);
    j = skipWsComments(t, j + 1);
    const valueStart = j;
    const valueEnd = findValueEnd(t, valueStart);
    out.push({ key: keyTok.value, keyStart: i, keyEnd: keyTok.end, valueStart, valueEnd });
    j = skipWsComments(t, valueEnd);
    if (t[j] === ',') { i = skipWsComments(t, j + 1); continue; }
    if (t[j] === '}') return { members: out, close: j };
    throw new Error(`expected ',' or '}' at ${j}`);
  }
}

function rootObject(t) {
  const i = skipWsComments(t, 0);
  if (t[i] !== '{') throw new Error('target is not a JSON object');
  return i;
}

/** Leading whitespace of the line containing `offset` (empty if the line isn't pure ws). */
function lineIndent(t, offset) {
  const nl = t.lastIndexOf('\n', offset - 1);
  const start = nl === -1 ? 0 : nl + 1;
  const ws = t.slice(start, offset);
  return /^[ \t]*$/.test(ws) ? ws : '';
}

/** Detect the file's indent unit: shortest leading whitespace before a key. */
function detectUnit(t) {
  const re = /\n([ \t]+)"/g;
  let m, best = null;
  while ((m = re.exec(t))) {
    if (best === null || m[1].length < best.length) best = m[1];
  }
  return best === null ? '  ' : best;
}

/** JSON text of value with `unit` indents; lines after the first prefixed by base. */
function emitValue(value, base, unit) {
  const s = JSON.stringify(value, null, unit);
  return s.split('\n').map((l, i) => (i === 0 || !l ? l : base + l)).join('\n');
}

/** Strip comments + trailing commas (string-aware) so JSON.parse can run. */
function stripJsonc(t) {
  let out = '', i = 0;
  while (i < t.length) {
    const c = t[i];
    if (c === '"') { const s = readString(t, i); out += t.slice(i, s.end); i = s.end; continue; }
    if (c === '/' && t[i + 1] === '/') { while (i < t.length && t[i] !== '\n') i++; continue; }
    if (c === '/' && t[i + 1] === '*') { const e = t.indexOf('*/', i + 2); i = e === -1 ? t.length : e + 2; continue; }
    out += c; i++;
  }
  return out.replace(/,\s*([}\]])/g, '$1');
}

function tryParseJsonc(t) {
  try { return JSON.parse(stripJsonc(t)); } catch { return undefined; }
}

// ------------------------------------------------------------------ fragment
if (!existsSync(FRAGMENT)) { console.error(`ERROR: fragment not found: ${FRAGMENT}`); process.exit(1); }
const fragText = readFileSync(FRAGMENT, 'utf8').replace(/^\uFEFF/, '');
let fragValue;
{
  const root = skipWsComments(fragText, 0);
  const keyTok = readString(fragText, root);
  if (keyTok.value !== KEY) { console.error(`ERROR: fragment top-level key is "${keyTok.value}", expected "${KEY}"`); process.exit(1); }
  let j = skipWsComments(fragText, keyTok.end);
  if (fragText[j] !== ':') { console.error('ERROR: fragment malformed (no colon after key)'); process.exit(1); }
  j = skipWsComments(fragText, j + 1);
  const end = findValueEnd(fragText, j);
  fragValue = tryParseJsonc(fragText.slice(j, end));
  if (fragValue === undefined) { console.error('ERROR: fragment value is not parseable'); process.exit(1); }
}

// ------------------------------------------------------------------ target
const exists = existsSync(FILE);
const raw = exists ? readFileSync(FILE, 'utf8') : '{}\n';
const bom = raw.charCodeAt(0) === 0xFEFF;
const text0 = (bom ? raw.slice(1) : raw).split('\r\n').join('\n'); // normalize to LF for processing
const EOL = raw.includes('\r\n') ? '\r\n' : '\n';

let status = 'UNCHANGED';
let result = text0;

const trimmed = text0.trim();
if (trimmed === '' || trimmed === '{}') {
  // empty / `{}` -> rebuild with the standard 2-space unit
  const unit = '  ';
  const gv = emitValue(fragValue, ' '.repeat(4), unit);
  result = `{\n  "mcp": {\n    "${KEY}": ${gv}\n  }\n}\n`;
  status = 'INSERTED';
} else {
  try {
    const root = rootObject(text0);
    const rootMembers = members(text0, root);
    const mcp = rootMembers.members.find((m) => m.key === 'mcp');
    const unit = detectUnit(text0);

    if (!mcp) {
      const rootIndent = rootMembers.members.length ? lineIndent(text0, rootMembers.members[0].keyStart) : '  ';
      const rootCloseIndent = rootIndent.endsWith(unit) ? rootIndent.slice(0, -unit.length) : rootIndent;
      const m1 = rootIndent;          // "mcp" line indent (same level as siblings)
      const m2 = rootIndent + unit;   // "gbrain" line indent
      const gv = emitValue(fragValue, m2, unit);
      const insertAt = rootMembers.members.length
        ? rootMembers.members[rootMembers.members.length - 1].valueEnd
        : root + 1;
      const comma = rootMembers.members.length ? ',' : '';
      // fix the root's closing brace indentation inside the tail
      const rel = rootMembers.close - insertAt;
      const beforeClose = text0.slice(insertAt, insertAt + rel).replace(/(\r?\n)[ \t]*$/, `$1${rootCloseIndent}`);
      const tail = beforeClose + text0.slice(insertAt + rel);
      const insertText = `${comma}\n${m1}"mcp": {\n${m2}"${KEY}": ${gv}\n${m1}}`;
      result = text0.slice(0, insertAt) + insertText + tail;
      status = 'INSERTED_MCP';
    } else {
      const mcpObj = members(text0, skipWsComments(text0, mcp.valueStart));
      const existing = mcpObj.members.find((m) => m.key === KEY);

      if (!existing) {
        const memberIndent = mcpObj.members.length
          ? lineIndent(text0, mcpObj.members[0].keyStart)
          : lineIndent(text0, mcp.keyStart) + unit;
        const gv = emitValue(fragValue, memberIndent, unit);
        if (mcpObj.members.length) {
          const insertAt = mcpObj.members[mcpObj.members.length - 1].valueEnd;
          result = text0.slice(0, insertAt) + `,\n${memberIndent}"${KEY}": ${gv}` + text0.slice(insertAt);
        } else {
          // empty mcp object: fill it, keeping its closing brace aligned with "mcp"
          const closeIndent = lineIndent(text0, mcp.keyStart);
          result = text0.slice(0, mcp.valueStart + 1) +
            `\n${memberIndent}"${KEY}": ${gv}\n${closeIndent}` +
            text0.slice(mcpObj.close);
        }
        status = 'INSERTED';
      } else {
        const existingText = text0.slice(existing.valueStart, existing.valueEnd);
        const parsed = tryParseJsonc(existingText);
        const same = parsed !== undefined && JSON.stringify(parsed) === JSON.stringify(fragValue);
        if (same) {
          status = 'UNCHANGED';
        } else if (!REPLACE) {
          status = 'KEPT';
        } else {
          const memberIndent = lineIndent(text0, existing.keyStart);
          const gv = emitValue(fragValue, memberIndent, unit);
          result = text0.slice(0, existing.keyStart) + `"${KEY}": ${gv}` + text0.slice(existing.valueEnd);
          status = 'REPLACED';
        }
      }
    }
  } catch (e) {
    console.error(`merge-mcp: ERROR target is not valid JSONC (${e.message}); file left untouched.`);
    process.exit(2);
  }
}

// ------------------------------------------------------------------ output
if (status !== 'UNCHANGED' && status !== 'KEPT') {
  if (!DRY) {
    if (exists && !NO_BACKUP) {
      const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
      copyFileSync(FILE, `${FILE}.bak-${stamp}`);
    }
    const out = result.split('\n').join(EOL);
    writeFileSync(FILE, (bom ? '\uFEFF' : '') + out, 'utf8');
  }
}

console.log(`merge-mcp: ${status} (${FILE})`);
if (status === 'KEPT') {
  console.log(`  note: an existing "${KEY}" block differs from the template; it was kept.`);
  console.log('  re-run with --replace to standardize it (a backup is made first).');
}
process.exit(0);
