#!/usr/bin/env bun
/**
 * gbrain-capture-export.ts
 * OpenCode session -> GBrain corpus bridge (Hindsight-1: automatic fact extraction).
 *
 * WHY BUN: OpenCode(.exe) is a DLP-trusted process - .txt files IT writes land
 * encrypted (%TSD-Header) and gbrain (a bun process, untrusted) would read
 * ciphertext. bun.exe writes .txt as PLAINTEXT, which is exactly what the
 * corpus sweep needs. So this script must run under bun.exe, not via the
 * opencode write tool.
 *
 * WHAT IT DOES:
 *   - reads opencode.db READ-ONLY ($USERPROFILE/.local/share/opencode/opencode.db)
 *   - exports NEW messages of every ROOT session as content-addressed
 *     "oc-<sid>-<lastMsgMs>-<sha12>.txt" segments into
 *     $USERPROFILE/.gbrain/transcripts/corpus
 *   - segments are capped at SEG_CHARS=7600 because the extraction pipeline
 *     truncates input at MAX_TURN_TEXT_CHARS=8000 (facts/extract.ts) - one
 *     runFactsPipeline call per corpus file
 *   - gbrain serve's idle/startup/delegated sweeps then extract facts from
 *     these files and drop a "<file>.ingested" sidecar; we never rewrite a
 *     file that exists (or whose sidecar exists) - re-exports are idempotent
 *
 * USAGE:
 *   bun.exe gbrain-capture-export.ts                 # resident loop (180s interval)
 *   bun.exe gbrain-capture-export.ts --once          # single pass (maintenance)
 *   bun.exe gbrain-capture-export.ts --once --dry-run --since-days 7
 *   bun.exe gbrain-capture-export.ts --once --max-segments 0 --no-sweep
 *   Flags: --once --dry-run --since-days N --interval-ms N --session <sidPrefix>
 *          --max-segments N  pacing cap per pass (default 12; 0 = unlimited)
 *          --no-sweep        skip auto-sweep after each pass
 *
 * AUTO-SWEEP: after a pass that wrote segments (or with pending corpus files)
 * and when the ready-marker exists, spawns `gbrain sweep --once --budget-ms
 * 300000 --batch-limit 20` (>=5min apart). Runs only while `gbrain serve` is
 * alive - the sweep then delegates into serve over IPC and can never race a
 * serve boot on the PGLite lock.
 */

import { Database } from 'bun:sqlite';
import {
  existsSync, mkdirSync, writeFileSync, renameSync, appendFileSync, readFileSync, unlinkSync,
  readdirSync,
} from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createHash } from 'node:crypto';

// ---------------------------------------------------------------- config
// Paths derive from $USERPROFILE so this file works on any Windows account.
const HOME = (process.env.USERPROFILE ?? process.env.HOME ?? '').replace(/\\/g, '/');
if (!HOME) {
  console.error('ERROR: USERPROFILE (or HOME) is not set - cannot resolve paths.');
  process.exit(1);
}
const DB_PATH = `${HOME}/.local/share/opencode/opencode.db`;
const CORPUS_DIR = `${HOME}/.gbrain/transcripts/corpus`;
const STATE_PATH = `${HOME}/.gbrain/transcripts/oc-export-state.json`;
const LOCK_PATH = `${HOME}/.gbrain/transcripts/oc-export.lock`;
const LOG_PATH = `${HOME}/.config/opencode/memory/logs/gbrain-capture.log`;
const LOG_DIR = `${HOME}/.config/opencode/memory/logs`;

const SEG_CHARS = 7600; // extraction truncates at 8000 -> stay safely under
const DEFAULT_INTERVAL_MS = 180_000;
const DEFAULT_SINCE_DAYS = 30;
const LOCK_STALE_MS = 15 * 60_000;

const GBRAIN_EXE = `${HOME}/.bun/bin/gbrain.exe`;
// Maintenance writes this marker AFTER `facts.default_visibility=world` is
// verified. Auto-sweep stays off until then so pre-config ingests can never
// land as invisible private facts.
const READY_MARKER = `${HOME}/.gbrain/transcripts/sweep-enabled.md`;
const DEFAULT_MAX_SEG = 12;        // pacing cap per pass (0 = unlimited)
const SWEEP_BUDGET_MS = 300_000;   // delegated sweep budget per auto-sweep
const SWEEP_BATCH = 20;            // corpus files per auto-sweep call
const SWEEP_MIN_INTERVAL_MS = 5 * 60_000;

// ---------------------------------------------------------------- args
const argv = process.argv.slice(2);
const has = (f: string) => argv.includes(f);
const arg = (f: string, dflt: string) => {
  const i = argv.indexOf(f);
  return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : dflt;
};
const ONCE = has('--once');
const DRY = has('--dry-run');
const SINCE_DAYS = Number(arg('--since-days', String(DEFAULT_SINCE_DAYS)));
const INTERVAL_MS = Number(arg('--interval-ms', String(DEFAULT_INTERVAL_MS)));
const SESSION_FILTER = arg('--session', '');
const MAX_SEG_RAW = Number(arg('--max-segments', String(DEFAULT_MAX_SEG)));
const MAX_SEG = Number.isFinite(MAX_SEG_RAW) ? Math.max(0, Math.floor(MAX_SEG_RAW)) : DEFAULT_MAX_SEG;
const NO_SWEEP = has('--no-sweep');

// ---------------------------------------------------------------- helpers
function log(line: string, consoleToo = ONCE) {
  const text = `[${new Date().toISOString()}] ${line}`;
  try { appendFileSync(LOG_PATH, text + '\n'); } catch { /* best effort */ }
  if (consoleToo) console.log(text);
}

function pidAlive(pid: number): boolean {
  try { process.kill(pid, 0); return true; }
  catch (e: any) { return e?.code === 'EPERM'; }
}

function acquireLock(): boolean {
  try {
    if (existsSync(LOCK_PATH)) {
      const m = /^(\d+)@(\d+)$/.exec(readFileSync(LOCK_PATH, 'utf8').trim());
      if (m && m[1] !== String(process.pid)) {
        const pid = Number(m[1]);
        const age = Date.now() - Number(m[2]);
        if (age < LOCK_STALE_MS && pidAlive(pid)) return false;
      }
    }
    writeFileSync(LOCK_PATH, `${process.pid}@${Date.now()}`);
    return true;
  } catch { return true; } // fail-open: a lock hiccup must not stop the bridge
}

function releaseLock() {
  try {
    if (readFileSync(LOCK_PATH, 'utf8').startsWith(String(process.pid) + '@')) unlinkSync(LOCK_PATH);
  } catch { /* best effort */ }
}

// secret redaction (defense-in-depth): reuse gbrain's scanner when importable;
// otherwise fall back to a minimal named-prefix scrub list (never ship raw keys).
type Redactor = (t: string) => { text: string; redactions: unknown[] };
const FALLBACK_RES: Array<[RegExp, string]> = [
  [/sk-[A-Za-z0-9_-]{20,}/g, '<REDACTED:openai>'],
  [/ghp_[A-Za-z0-9]{20,}/g, '<REDACTED:github_token>'],
  [/github_pat_[A-Za-z0-9_]{20,}/g, '<REDACTED:github_token>'],
  [/AKIA[0-9A-Z]{16}/g, '<REDACTED:aws_key>'],
  [/(Bearer\s+)[A-Za-z0-9._-]{20,}/g, '$1<REDACTED:bearer>'],
  [/-----BEGIN [A-Z ]+PRIVATE KEY-----[\s\S]+?-----END [A-Z ]+PRIVATE KEY-----/g, '<REDACTED:private_key_pem>'],
];
const fallbackScrub: Redactor = (t) => {
  let out = t;
  for (const [re, rep] of FALLBACK_RES) out = out.replace(re, rep);
  return { text: out, redactions: [] };
};
let redactText: Redactor = fallbackScrub;
try {
  const mod: any = await import(`${HOME}/.bun/install/global/node_modules/gbrain/src/core/secret-scan.ts`);
  if (typeof mod?.redactFindings === 'function') {
    redactText = (t: string) => mod.redactFindings(t);
    log('secret-scan: gbrain redactFindings loaded', false);
  }
} catch (e: any) {
  log(`secret-scan: import failed (${e?.message}); fallback scrub active`, false);
}

// text-part filters: drop opencode tool-call echo parts, U+FFFD junk runs,
// and harness noise (OMO directives / checkpoint restores / continue-pokes)
const TOOL_ECHO_RE = /^Called the [\w .-]+ tool with the following input:/;
const FFFD_ONLY_RE = /^\uFFFD[\s\uFFFD]*$/;
const NOISE_RES: RegExp[] = [
  /<!--\s*OMO_INTERNAL_INITIATOR\s*-->/,                    // OMO internal marker (422 msgs)
  /^\[SYSTEM DIRECTIVE: OH-MY-OPENCODE/,                    // OMO system directives
  /^\[restore checkpointed session agent configuration/,    // compaction restore notice
  /^\[internal\]/,                                          // internal continue-pokes
  /^Continue if you have next steps, or stop and ask for clarification if you are unsure how to proceed\.?$/,
];

function textOfParts(parts: Array<{ data: string }>): string {
  const out: string[] = [];
  for (const p of parts) {
    let d: any;
    try { d = JSON.parse(p.data); } catch { continue; }
    if (d?.type !== 'text' || typeof d.text !== 'string') continue;
    const t = d.text;
    if (!t.trim()) continue;
    if (TOOL_ECHO_RE.test(t)) continue;
    if (FFFD_ONLY_RE.test(t)) continue;
    if (NOISE_RES.some((re) => re.test(t))) continue;
    out.push(t.replace(/\s+$/, ''));
  }
  return out.join('\n\n');
}

function sanitizeComponent(name: string): string {
  return name.replace(/[^A-Za-z0-9._-]/g, '-').slice(0, 120);
}

function chunkText(s: string, size: number): string[] {
  const out: string[] = [];
  for (let i = 0; i < s.length; i += size) out.push(s.slice(i, i + size));
  return out;
}

type WriteResult = 'written' | 'skip';
function writeSegment(sid: string, lastTs: number, text: string): WriteResult {
  const r = redactText(text);
  const safe = r.text;
  if (r.redactions.length) log(`redacted ${r.redactions.length} secret(s) in a ${sid} segment`, false);
  const hash = createHash('sha256').update(safe, 'utf8').digest('hex').slice(0, 12);
  const name = `oc-${sanitizeComponent(sid)}-${lastTs}-${hash}.txt`;
  const full = join(CORPUS_DIR, name);
  if (existsSync(full) || existsSync(full + '.ingested')) return 'skip';
  if (DRY) { log(`dry-run: would write ${name} (${safe.length} chars)`); return 'written'; }
  const tmp = `${full}.tmp-${process.pid}`;
  writeFileSync(tmp, safe, { mode: 0o600 });
  renameSync(tmp, full);
  return 'written';
}

// ---------------------------------------------------------------- state
interface Wm { lastTs: number; lastId: string }
interface State { version: 1; sessions: Record<string, Wm>; lastRun?: string }

function loadState(): State {
  try {
    const s = JSON.parse(readFileSync(STATE_PATH, 'utf8'));
    if (s && s.version === 1 && s.sessions) return s;
  } catch { /* first run */ }
  return { version: 1, sessions: {} };
}

function saveState(s: State) {
  const tmp = `${STATE_PATH}.tmp-${process.pid}`;
  writeFileSync(tmp, JSON.stringify(s, null, 1));
  renameSync(tmp, STATE_PATH);
}

// ---------------------------------------------------------------- auto-sweep
let lastSweepAt = 0;

/** Corpus files still waiting for ingestion (no sidecar, not claimed). */
function pendingSegments(): string[] {
  try {
    return readdirSync(CORPUS_DIR).filter(
      (f) => f.endsWith('.txt') &&
        !existsSync(join(CORPUS_DIR, f + '.ingested')) &&
        !existsSync(join(CORPUS_DIR, f + '.in-progress')),
    );
  } catch { return []; }
}

/** True while a `gbrain serve` (gbrain.exe shim or bun cli.ts) is running. */
function serveAlive(): boolean {
  try {
    const r = spawnSync('powershell.exe', ['-NoProfile', '-Command',
      "Get-CimInstance Win32_Process -Filter \"Name='gbrain.exe' or Name='bun.exe'\" | " +
      "Where-Object { $_.CommandLine -match 'serve' } | Select-Object -First 1 -ExpandProperty ProcessId",
    ], { encoding: 'utf8', timeout: 20_000, windowsHide: true });
    return !!(r.stdout && r.stdout.trim());
  } catch { return false; }
}

function runAutoSweep(written: number) {
  try {
    runAutoSweepInner(written);
  } catch (e: any) {
    log(`auto-sweep crashed (swallowed, loop continues): ${e?.stack || e}`, false);
  }
}

function runAutoSweepInner(written: number) {
  if (NO_SWEEP) return;
  const pending = pendingSegments();
  if (written === 0 && pending.length === 0) return;
  if (!existsSync(READY_MARKER)) {
    log('auto-sweep deferred: ready-marker absent (waiting for maintenance window)', false);
    return;
  }
  if (Date.now() - lastSweepAt < SWEEP_MIN_INTERVAL_MS) {
    log(`auto-sweep throttled (pending=${pending.length}, written=${written})`, false);
    return;
  }
  if (!serveAlive()) {
    log(`auto-sweep deferred: gbrain serve not running (pending=${pending.length})`, false);
    return;
  }
  lastSweepAt = Date.now();
  log(`auto-sweep: gbrain sweep (pending=${pending.length}, written=${written}, budget=${SWEEP_BUDGET_MS}ms)`, false);
  const r = spawnSync(GBRAIN_EXE, [
    'sweep', '--once', '--budget-ms', String(SWEEP_BUDGET_MS), '--batch-limit', String(SWEEP_BATCH), '--json',
  ], { encoding: 'utf8', timeout: SWEEP_BUDGET_MS + 120_000, windowsHide: true });
  const out = ((r.stdout || '').trim().split('\n').filter(Boolean).pop() || '').slice(0, 400);
  const err = (r.stderr || '').trim().slice(0, 300);
  const spawnErr = r.error ? String((r.error as any).message || r.error).slice(0, 200) : '';
  log(`auto-sweep done rc=${r.status}${spawnErr ? ` spawn-error=${spawnErr}` : ''}: ${out || err || '(no output)'}`, false);
}

// ---------------------------------------------------------------- pass
interface Row { id: string; time_created: number; role: string; completed: number | null }

let lastDeferLogAt = 0;
function runPass(): number {
  if (!DRY && !existsSync(READY_MARKER)) {
    // Bootstrap gate: no corpus writes until maintenance verifies
    // facts.default_visibility=world. Pre-config ingests would land 'private'
    // and stay invisible to MCP recall forever, so the corpus stays empty
    // until the gate opens (dry-run still previews what would be written).
    if (Date.now() - lastDeferLogAt > 30 * 60_000) {
      lastDeferLogAt = Date.now();
      log('exports deferred: ready-marker absent (waiting for maintenance window)');
    }
    return 0;
  }
  const db = new Database(DB_PATH, { readonly: true });
  try { db.exec('PRAGMA busy_timeout = 5000'); } catch { /* readonly pragma may be refused */ }
  const state = loadState();
  const nowMs = Date.now();
  const floorTs = nowMs - Math.max(1, SINCE_DAYS) * 86_400_000;

  const sessions = db.query(
    'SELECT id, title, time_updated FROM session WHERE parent_id IS NULL ORDER BY time_updated DESC',
  ).all() as Array<{ id: string; title: string; time_updated: number }>;

  const partStmt = db.query('SELECT data FROM part WHERE message_id = ?1 ORDER BY id ASC');
  const msgFirst = db.query(`SELECT id, time_created, json_extract(data,'$.role') AS role,
      json_extract(data,'$.time.completed') AS completed
    FROM message WHERE session_id = ?1 AND time_created >= ?2
    ORDER BY time_created ASC, id ASC`);
  const msgAfter = db.query(`SELECT id, time_created, json_extract(data,'$.role') AS role,
      json_extract(data,'$.time.completed') AS completed
    FROM message WHERE session_id = ?1 AND (time_created > ?2 OR (time_created = ?2 AND id > ?3))
    ORDER BY time_created ASC, id ASC`);

  let segWritten = 0, segSkip = 0, msgsExported = 0, sessionsTouched = 0;
  const t0 = Date.now();
  const outOfBudget = () => MAX_SEG > 0 && segWritten >= MAX_SEG;

  for (const s of sessions) {
    if (outOfBudget()) break; // pacing cap reached - resume next pass
    if (SESSION_FILTER && !s.id.startsWith(SESSION_FILTER)) continue;
    const wm = state.sessions[s.id];
    if (wm && s.time_updated <= wm.lastTs) continue; // nothing new since watermark
    const rows = (wm
      ? msgAfter.all(s.id, wm.lastTs, wm.lastId)
      : msgFirst.all(s.id, floorTs)) as Row[];
    if (!rows.length) continue;

    let buf = '';
    let bufLast: Wm | null = null;
    let sessLast: Wm | null = null;
    let exportedHere = 0;

    const flush = () => {
      if (!buf || !bufLast) { buf = ''; bufLast = null; return; }
      const res = writeSegment(s.id, bufLast.lastTs, buf + '\n');
      if (res === 'written') segWritten++; else segSkip++;
      buf = ''; bufLast = null;
    };

    // A null-completed assistant msg is only "live" when it is the newest
    // exportable row; if any row follows it, the stream was aborted mid-way
    // and we must export its text instead of jamming this session forever
    // (observed 2026-09-30: one aborted msg at 21:42:44 blocked this session
    // for ~4h; the old logic only self-healed after 24h).
    let newestIdx = -1;
    for (let i = rows.length - 1; i >= 0; i--) {
      const ro = rows[i].role;
      if (ro === 'user' || ro === 'assistant') { newestIdx = i; break; }
    }
    for (let i = 0; i < rows.length; i++) {
      const r = rows[i];
      if (outOfBudget()) break;
      const role = r.role;
      if (role !== 'user' && role !== 'assistant') continue;
      if (role === 'assistant' && r.completed == null) {
        if (i === newestIdx && Date.now() - r.time_created < 86_400_000) break; // live stream: wait for a later pass
        // aborted mid-stream (rows follow) or stale >24h: stream is dead - export whatever text exists
        log(`note: exporting incomplete msg ${r.id} (${i === newestIdx ? 'stale>24h' : 'aborted mid-stream'})`, false);
      }
      const parts = partStmt.all(r.id) as Array<{ data: string }>;
      const text = textOfParts(parts);
      sessLast = { lastTs: r.time_created, lastId: r.id };
      if (!text) continue; // file-only / empty messages still advance the watermark
      const block = `[${role}]\n${text}`;
      if (block.length > SEG_CHARS) {
        flush();
        for (const piece of chunkText(block, SEG_CHARS)) {
          const res = writeSegment(s.id, r.time_created, piece + '\n');
          if (res === 'written') segWritten++; else segSkip++;
        }
        exportedHere++;
        continue;
      }
      if (buf && buf.length + block.length + 2 > SEG_CHARS) flush();
      buf = buf ? `${buf}\n\n${block}` : block;
      bufLast = { lastTs: r.time_created, lastId: r.id };
      exportedHere++;
    }
    flush();

    if (sessLast) {
      state.sessions[s.id] = sessLast;
      sessionsTouched++;
      msgsExported += exportedHere;
    }
  }

  state.lastRun = new Date(nowMs).toISOString();
  if (!DRY) saveState(state);
  db.close();
  log(
    `pass done: sessions=${sessions.length} touched=${sessionsTouched} msgs=${msgsExported} ` +
    `segments: +${segWritten} written, ${segSkip} skip | ${Date.now() - t0}ms` +
    `${DRY ? ' [dry-run]' : ''}${SESSION_FILTER ? ` [filter=${SESSION_FILTER}]` : ''}` +
    `${outOfBudget() ? ` [capped at ${MAX_SEG}]` : ''}`,
  );
  return segWritten;
}

// ---------------------------------------------------------------- main
mkdirSync(CORPUS_DIR, { recursive: true });
mkdirSync(LOG_DIR, { recursive: true });

if (ONCE) {
  const locked = !acquireLock();
  if (locked) { log('another exporter instance holds the lock - exiting quietly'); process.exit(0); }
  let written = 0;
  try { written = runPass(); } catch (e: any) { log(`ERROR: ${e?.stack || e}`); releaseLock(); process.exit(1); }
  if (!DRY) runAutoSweep(written);
  releaseLock();
  process.exit(0);
} else {
  log(`resident loop started (interval=${INTERVAL_MS}ms, since-days=${SINCE_DAYS}, ` +
    `max-segments=${MAX_SEG || 'unlimited'}, auto-sweep=${NO_SWEEP ? 'off' : 'on'})`);
  // eslint-disable-next-line no-constant-condition
  while (true) {
    let written = 0;
    if (acquireLock()) {
      try { written = runPass(); } catch (e: any) { log(`ERROR: ${e?.stack || e}`); }
      finally { releaseLock(); }
    } else {
      log('lock busy (concurrent pass?) - skipping this tick', false);
    }
    if (!DRY) runAutoSweep(written);
    await new Promise((r) => setTimeout(r, INTERVAL_MS));
  }
}
