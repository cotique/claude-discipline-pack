#!/usr/bin/env node
/**
 * discipline — distribute the pack into product repos and keep it healthy.
 *
 *   node bin/discipline.mjs init  --target <repo> [--components commands,hooks]
 *   node bin/discipline.mjs apply --target <repo> [--force]
 *   node bin/discipline.mjs check --target <repo>
 *   node bin/discipline.mjs report --target <repo> [--since 7d] [--min-firings 10]
 *
 * Model: this repo is the versioned pack (version = .claude-plugin/plugin.json).
 * `apply` vendors pack files into <repo>/.claude and records their sha256 in
 * .claude/discipline-manifest.json. Local edits to applied files are DRIFT —
 * `check` fails; fixes belong in the pack, not in the copy. Overlay is
 * additive-only: a project command/skill named like a pack command is a
 * collision error, never a silent override. `apply` never touches
 * .claude/discipline.json or anything it does not track.
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import url from 'node:url';
import { execSync, spawnSync } from 'node:child_process';

const PACK = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const MANIFEST_REL = path.join('.claude', 'discipline-manifest.json');
const ALL_COMPONENTS = ['commands', 'hooks'];

// ---------- helpers ----------
// Hash with line endings normalised. Everything the pack ships is text, and a
// target repo with core.autocrlf=true rewrites checked-out copies to CRLF — a
// byte hash would then report permanent drift on files nobody touched, which is
// exactly the false intercept that teaches people to ignore the gate.
const sha256 = (f) =>
  crypto.createHash('sha256')
    .update(fs.readFileSync(f).toString('utf8').split('\r\n').join('\n'), 'utf8')
    .digest('hex');
const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
const die = (msg) => { console.error(`error: ${msg}`); process.exit(1); };

function args(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--target') out.target = argv[++i];
    else if (argv[i] === '--components') out.components = argv[++i].split(',').map((s) => s.trim());
    else if (argv[i] === '--force') out.force = true;
    else if (argv[i] === '--since') out.since = argv[++i];
    else if (argv[i] === '--min-firings') out.minFirings = argv[++i];
    else out._.push(argv[i]);
  }
  return out;
}

function packVersion() {
  return readJson(path.join(PACK, '.claude-plugin', 'plugin.json')).version;
}

function reservedNames() {
  return fs.readdirSync(path.join(PACK, 'commands'))
    .filter((f) => f.endsWith('.md'))
    .map((f) => path.basename(f, '.md'));
}

/** Pack files for the chosen components as [srcAbs, destRel] pairs. */
function packFiles(components) {
  // destRel always uses forward slashes so manifests stay portable across OSes.
  const pairs = [];
  if (components.includes('commands')) {
    for (const f of fs.readdirSync(path.join(PACK, 'commands'))) {
      if (f.endsWith('.md')) pairs.push([path.join(PACK, 'commands', f), `.claude/commands/${f}`]);
    }
  }
  if (components.includes('hooks')) {
    for (const dir of ['bash', 'powershell']) {
      for (const f of fs.readdirSync(path.join(PACK, 'hooks', dir))) {
        if (f.endsWith('.sh') || f.endsWith('.ps1')) {
          pairs.push([path.join(PACK, 'hooks', dir, f), `.claude/hooks/${f}`]);
        }
      }
    }
    // The git hook is vendored into a TRACKED directory rather than .git/hooks,
    // which is neither tracked nor copied by clone. `core.hooksPath` then points
    // git at it — see installGitHooksPath. One implementation serves both
    // platforms: git invokes it through sh, so there is no PowerShell twin.
    pairs.push([path.join(PACK, 'hooks', 'git', 'pre-push'), '.githooks/pre-push']);
  }
  return pairs;
}

/**
 * Point git at the vendored hook directory, and report rather than assume.
 * Returns a short status string for the caller to print.
 *
 * Why this is not optional: the pre-push hook is the authoritative half of
 * protected-branch enforcement, and the PreToolUse gate only warns for pushes on
 * the strength of it being installed. If this step is skipped, the loud layer is
 * gone and nothing has replaced it.
 */
function installGitHooksPath(target) {
  const dir = path.join(target, '.githooks');
  const hook = path.join(dir, 'pre-push');
  if (!fs.existsSync(hook)) return 'pre-push: NOT installed (file missing)';
  try {
    fs.chmodSync(hook, 0o755);
  } catch { /* Windows filesystems have no execute bit; git runs it through sh anyway */ }
  const r = spawnSync('git', ['-C', target, 'config', 'core.hooksPath', '.githooks'], { encoding: 'utf8' });
  if (r.status !== 0) {
    return `pre-push: installed but core.hooksPath NOT set (${(r.stderr || '').trim() || 'git failed'})`;
  }
  return 'pre-push: installed, core.hooksPath=.githooks';
}

/** Approximate LOC of git-tracked source files; null when not measurable. */
function repoLoc(target) {
  const exts = new Set(['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.cs', '.py', '.go', '.java',
    '.rb', '.php', '.c', '.h', '.cpp', '.hpp', '.kt', '.rs', '.swift', '.scala', '.vue', '.svelte', '.sql']);
  try {
    const out = execSync('git ls-files', { cwd: target, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
    let loc = 0;
    for (const f of out.split('\n')) {
      if (!f || !exts.has(path.extname(f).toLowerCase())) continue;
      try {
        const buf = fs.readFileSync(path.join(target, f));
        for (let i = buf.indexOf(10); i !== -1; i = buf.indexOf(10, i + 1)) loc++;
      } catch { /* deleted/unreadable — skip */ }
    }
    return loc;
  } catch { return null; }
}

function loadManifest(target) {
  const p = path.join(target, MANIFEST_REL);
  if (!fs.existsSync(p)) return null;
  const m = readJson(p);
  // Manifests written before the field was renamed carry `coreVersion`.
  if (m.packVersion === undefined && m.coreVersion !== undefined) {
    m.packVersion = m.coreVersion;
    delete m.coreVersion;
  }
  return m;
}

function saveManifest(target, manifest) {
  const p = path.join(target, MANIFEST_REL);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(manifest, null, 2) + '\n');
}

// ---------- commands ----------
function init(opts) {
  const target = path.resolve(opts.target ?? die('init needs --target <repo>'));
  if (!fs.existsSync(target)) die(`target does not exist: ${target}`);
  if (loadManifest(target)) die('already initialized — use apply / check');
  const components = opts.components ?? ALL_COMPONENTS;
  for (const c of components) if (!ALL_COMPONENTS.includes(c)) die(`unknown component: ${c}`);

  saveManifest(target, {
    packVersion: packVersion(),
    source: PACK.split(path.sep).join('/'),
    components,
    files: {},
  });

  const cfg = path.join(target, '.claude', 'discipline.json');
  if (!fs.existsSync(cfg)) {
    fs.copyFileSync(path.join(PACK, 'examples', 'discipline.example.json'), cfg);
    console.log('created .claude/discipline.json from example — edit it for this repo');
  } else {
    console.log('kept existing .claude/discipline.json');
  }
  console.log(`initialized (pack ${packVersion()}, components: ${components.join(', ')})`);
  console.log('next: apply, then register hooks in .claude/settings.json (see pack README)');
}

function apply(opts) {
  const target = path.resolve(opts.target ?? die('apply needs --target <repo>'));
  const manifest = loadManifest(target) ?? die('not initialized — run init first');

  // Refuse to clobber local edits: check existing tracked files before writing.
  const drifted = Object.entries(manifest.files)
    .filter(([rel, hash]) => {
      const p = path.join(target, rel);
      return fs.existsSync(p) && sha256(p) !== hash;
    })
    .map(([rel]) => rel);
  if (drifted.length && !opts.force) {
    die(`local edits detected (drift) in:\n  ${drifted.join('\n  ')}\n` +
        'fixes belong upstream in the pack. Re-run with --force to overwrite.');
  }

  const files = {};
  for (const [src, destRel] of packFiles(manifest.components)) {
    const dest = path.join(target, destRel);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.copyFileSync(src, dest);
    files[destRel] = sha256(dest);
    console.log(`applied ${destRel}`);
  }

  // Previously tracked files the pack no longer ships: remove clean copies.
  for (const rel of Object.keys(manifest.files)) {
    if (!(rel in files)) {
      const p = path.join(target, rel);
      if (fs.existsSync(p) && sha256(p) === manifest.files[rel]) {
        fs.unlinkSync(p);
        console.log(`removed retired pack file ${rel}`);
      } else if (fs.existsSync(p)) {
        console.warn(`warning: ${rel} retired from the pack but locally modified — left in place`);
      }
    }
  }

  if (manifest.components.includes('hooks')) console.log(installGitHooksPath(target));

  saveManifest(target, { ...manifest, packVersion: packVersion(), files });
  console.log(`apply complete (pack ${packVersion()})`);
}

function check(opts) {
  const target = path.resolve(opts.target ?? die('check needs --target <repo>'));
  const manifest = loadManifest(target) ?? die('not initialized — run init first');
  let errors = 0;
  const err = (msg) => { console.error(`CHECK ERROR: ${msg}`); errors++; };

  // 1. Drift and missing files.
  for (const [rel, hash] of Object.entries(manifest.files)) {
    const p = path.join(target, rel);
    if (!fs.existsSync(p)) err(`tracked pack file missing: ${rel} (re-run apply)`);
    else if (sha256(p) !== hash) err(`drift: ${rel} modified locally — upstream the change to the pack, then apply`);
  }

  // 2. Staleness. A version string is not a reliable signal — the pack can move
  // on without one — so compare the installed copies against the pack's current
  // files directly. "Stale" (pack changed) is a different condition from "drift"
  // (the copy was edited locally) and needs a different fix.
  const stale = [];
  for (const [src, destRel] of packFiles(manifest.components)) {
    const installedHash = manifest.files[destRel];
    if (!installedHash) { stale.push(`${destRel} (new in the pack)`); continue; }
    try {
      if (sha256(src) !== installedHash) stale.push(destRel);
    } catch { /* pack file unreadable — reported by the version check below */ }
  }
  if (stale.length) {
    console.warn(`check: ${stale.length} file(s) stale — the pack has moved on:\n  ` +
                 stale.join('\n  ') + '\n  Run apply to update.');
  }
  try {
    const src = packVersion();
    if (src !== manifest.packVersion) {
      console.warn(`check: pack is ${src}, installed ${manifest.packVersion} — run apply to upgrade`);
    }
  } catch {
    console.warn('check: pack source unreachable — staleness check skipped');
  }

  // 3. Reserved-name collisions (additive-only overlay).
  const reserved = new Set(reservedNames());
  const tracked = new Set(Object.keys(manifest.files));
  const cmdDir = path.join(target, '.claude', 'commands');
  if (fs.existsSync(cmdDir)) {
    for (const f of fs.readdirSync(cmdDir)) {
      const rel = path.join('.claude', 'commands', f);
      if (f.endsWith('.md') && reserved.has(path.basename(f, '.md')) && !tracked.has(rel)) {
        err(`reserved-name collision: ${rel} shadows a pack command — rename the overlay`);
      }
    }
  }
  const skillsDir = path.join(target, '.claude', 'skills');
  if (fs.existsSync(skillsDir)) {
    for (const d of fs.readdirSync(skillsDir)) {
      if (reserved.has(d)) err(`reserved-name collision: .claude/skills/${d} shadows a pack command — rename the overlay`);
    }
  }

  // 4. Config sanity.
  const cfgPath = path.join(target, '.claude', 'discipline.json');
  let cfg = null;
  if (!fs.existsSync(cfgPath)) console.warn('check: no .claude/discipline.json — hooks will no-op');
  else { try { cfg = readJson(cfgPath); } catch { err('.claude/discipline.json is not valid JSON'); } }

  // 5. Shadow mode is a bootstrap window, not a parking spot: report how long
  // this repo has been logging instead of enforcing, and escalate with age.
  if (cfg?.mode === 'shadow') {
    const rel = cfg.events?.path ?? '.claude/discipline-events.jsonl';
    const log = path.isAbsolute(rel) ? rel : path.join(target, rel);
    let since = null;
    if (fs.existsSync(log)) {
      for (const line of fs.readFileSync(log, 'utf8').split('\n')) {
        if (!line.trim()) continue;
        try {
          const e = JSON.parse(line);
          if (e.mode === 'shadow' && e.ts && (!since || e.ts < since)) since = e.ts;
        } catch { /* skip malformed line */ }
      }
    }
    const days = since ? Math.floor((Date.now() - Date.parse(since)) / 86_400_000) : null;
    if (days !== null && days >= 30) {
      err(`shadow mode has been on for ~${days} days — nothing is being enforced. ` +
          'Shadow is one bootstrap window to measure a gate\'s value; set "mode": "enforce".');
    } else {
      console.warn(`check: mode is "shadow" — gates log but do not block` +
                   (days !== null ? ` (~${days} day(s) so far)` : '') +
                   '. Switch to "enforce" once you have a window of data.');
    }
  }

  // 6. Code-graph gate by codebase size: past a certain size, "read the code
  // to understand it" stops working and a dependency graph becomes required
  // equipment, not a nice-to-have. Thresholds are tunable per repo.
  const graph = cfg?.codeGraph ?? {};
  const recommendAt = graph.recommendAtLoc ?? 50_000;
  const requireAt = graph.requireAtLoc ?? 300_000;
  // A graph counts as configured in whatever form it exists: an MCP server, a
  // skill, or a plain command. What matters is that dependency questions have an
  // answer other than grepping the whole repo — not how the answer is delivered.
  const graphConfigured = Boolean(graph.toolName || graph.skill || graph.command);
  if (!graphConfigured) {
    const loc = repoLoc(target);
    if (loc !== null) {
      if (loc >= requireAt) {
        err(`codebase is ~${Math.round(loc / 1000)}k LOC (>= ${requireAt / 1000}k) and no code graph is configured — ` +
            'set codeGraph.toolName (MCP server), codeGraph.skill, or codeGraph.command in .claude/discipline.json');
      } else if (loc >= recommendAt) {
        console.warn(`check: codebase is ~${Math.round(loc / 1000)}k LOC — consider configuring a code graph ` +
                     `(codeGraph.toolName | .skill | .command; recommended above ${recommendAt / 1000}k LOC, ` +
                     `required above ${requireAt / 1000}k)`);
      }
    }
  }

  // 7. Graph freshness. A graph is built from a commit and ages from then on; a
  // stale one answers confidently about structure that no longer exists and gives
  // no visible sign of it. Only checkable when the tool records its build commit.
  const snap = graph.snapshot;
  if (snap?.path && snap?.commitField) {
    const gp = path.isAbsolute(snap.path) ? snap.path : path.join(target, snap.path);
    if (!fs.existsSync(gp)) {
      console.warn(`check: code graph not built yet (${snap.path} missing)` +
                   (snap.refresh ? ` — run: ${snap.refresh}` : ''));
    } else {
      let builtAt = null;
      try { builtAt = readJson(gp)[snap.commitField] ?? null; } catch { /* not JSON, or unreadable */ }
      if (!builtAt) {
        console.warn(`check: code graph has no "${snap.commitField}" field — freshness cannot be checked`);
      } else {
        let behind = null;
        try {
          behind = parseInt(execSync(`git rev-list --count ${builtAt}..HEAD`,
            { cwd: target, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(), 10);
        } catch { /* commit not in this repo's history (rebased, or a merged graph) */ }
        if (behind === null) {
          console.warn(`check: code graph was built at ${String(builtAt).slice(0, 8)}, which is not in this ` +
                       'history — treat its answers as dated');
        } else if (behind > (snap.staleAfterCommits ?? 25)) {
          console.warn(`check: code graph is ${behind} commits behind HEAD` +
                       (snap.refresh ? ` — run: ${snap.refresh}` : '') +
                       '. Until then, graph answers are [INFERRED], not [OBSERVED].');
        }
      }
    }
  }

  if (errors) { console.error(`check: ${errors} error(s)`); process.exit(1); }
  console.log('check: healthy');
}


// ---------- report ----------
/**
 * Read the event log as records, and count what could not be parsed. A
 * truncated or corrupt log must not read as a quiet one: `check` skips malformed
 * lines silently, which is right for a gate and wrong for a report — a report
 * that drops part of its input and prints a confident total is the same
 * false-green the pack's canary rule exists to catch.
 */
function readEvents(logPath, sinceMs) {
  const out = { events: [], malformed: 0, total: 0 };
  if (!fs.existsSync(logPath)) return out;
  for (const line of fs.readFileSync(logPath, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    out.total++;
    let e;
    try { e = JSON.parse(line); } catch { out.malformed++; continue; }
    if (!e || typeof e.asset !== 'string') { out.malformed++; continue; }
    if (sinceMs !== null && (!e.ts || Date.parse(e.ts) < sinceMs)) continue;
    out.events.push(e);
  }
  return out;
}

/** "7d" / "12h" / an ISO date -> epoch ms, or null for all-time. */
function parseSince(s) {
  if (!s) return null;
  const m = /^(\d+)([dh])$/.exec(s.trim());
  if (m) return Date.now() - Number(m[1]) * (m[2] === 'd' ? 86400000 : 3600000);
  const t = Date.parse(s);
  if (Number.isNaN(t)) die(`--since wants Nd, Nh, or an ISO date; got: ${s}`);
  return t;
}

function pctl(arr, p) {
  if (!arr.length) return null;
  const s = [...arr].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
}
const tally = (map, key) => map.set(key, (map.get(key) ?? 0) + 1);
const fmtTally = (map) =>
  [...map.entries()].sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k}=${n}`).join(' ');

function report(opts) {
  const target = path.resolve(opts.target ?? die('report needs --target <repo>'));
  const manifest = loadManifest(target);
  let cfg = null;
  const cfgPath = path.join(target, '.claude', 'discipline.json');
  if (fs.existsSync(cfgPath)) { try { cfg = readJson(cfgPath); } catch { /* reported by check */ } }

  const rel = cfg?.events?.path ?? '.claude/discipline-events.jsonl';
  const logPath = path.isAbsolute(rel) ? rel : path.join(target, rel);
  const sinceMs = parseSince(opts.since);
  const window = opts.since ? `since ${opts.since}` : 'all recorded time';

  if (!fs.existsSync(logPath)) {
    console.log(`report: no event log at ${rel}`);
    if (cfg?.events?.enabled === false) {
      console.log('  events are disabled in .claude/discipline.json — nothing is being recorded, so ' +
                  'nothing can be measured. That is a choice, not a clean bill of health.');
    } else {
      console.log('  events default to on, so an absent log means either no hook has fired yet or ' +
                  'none is registered in .claude/settings.json. Those are different problems — check ' +
                  'the registration before concluding the gates are quiet.');
    }
    return;
  }

  const { events, malformed, total } = readEvents(logPath, sinceMs);
  console.log(`report: ${logPath}`);
  console.log(`window: ${window} — ${events.length} event(s) of ${total} line(s)`);
  if (malformed) {
    console.log(`  WARNING: ${malformed} line(s) could not be parsed and are in none of the numbers ` +
                'below. A truncated log reads exactly like a quiet one; find out which this is.');
  }
  if (!events.length) { console.log('  nothing in this window'); return; }

  // Per asset: what fired, how it ruled, in which mode, and what it cost.
  const assets = new Map();
  for (const e of events) {
    let a = assets.get(e.asset);
    if (!a) {
      a = { n: 0, events: new Map(), verdicts: new Map(), modes: new Map(), durations: [],
            sessions: new Set(), shadowSessions: new Set(), first: null, last: null };
      assets.set(e.asset, a);
    }
    a.n++;
    tally(a.events, e.event ?? '?');
    tally(a.verdicts, e.verdict ?? '?');
    tally(a.modes, e.mode ?? '?');
    if (typeof e.durationMs === 'number') a.durations.push(e.durationMs);
    if (e.sessionId) a.sessions.add(e.sessionId);
    if (e.mode === 'shadow' && e.event === 'would-block' && e.sessionId) a.shadowSessions.add(e.sessionId);
    if (e.ts && (!a.first || e.ts < a.first)) a.first = e.ts;
    if (e.ts && (!a.last || e.ts > a.last)) a.last = e.ts;
  }

  console.log('');
  for (const [name, a] of [...assets.entries()].sort((x, y) => y[1].n - x[1].n)) {
    console.log(`${name}  ${a.n} firing(s)${a.sessions.size ? ` across ${a.sessions.size} session(s)` : ''}`);
    console.log(`  events   ${fmtTally(a.events)}`);
    console.log(`  verdicts ${fmtTally(a.verdicts)}`);
    console.log(`  mode     ${fmtTally(a.modes)}`);
    if (a.durations.length) {
      // The cost side of the ledger: a gate is worth what it catches minus what
      // it charges every time it runs.
      console.log(`  cost     p50 ${pctl(a.durations, 50)}ms · p95 ${pctl(a.durations, 95)}ms ` +
                  `(${a.durations.length} timed)`);
    }
    console.log(`  seen     ${a.first?.slice(0, 19) ?? '?'} -> ${a.last?.slice(0, 19) ?? '?'}`);
  }

  // Graduation: the question shadow mode exists to answer, and the one thing
  // this log cannot answer by itself.
  const minFirings = Number(opts.minFirings ?? 10);
  const shadowed = [...assets.entries()].filter(([, a]) => (a.events.get('would-block') ?? 0) > 0);
  console.log('');
  if (!shadowed.length) {
    console.log('graduation: no would-block events in this window — nothing is waiting in shadow mode.');
  } else {
    console.log('graduation: what shadow mode measured, and what it cannot');
    for (const [name, a] of shadowed) {
      const wb = a.events.get('would-block') ?? 0;
      const days = a.first && a.last
        ? Math.max(1, Math.round((Date.parse(a.last) - Date.parse(a.first)) / 86400000))
        : null;
      const verdict = wb < minFirings
        ? `too few to estimate anything (< ${minFirings})`
        : 'enough firings to sample';
      console.log(`  ${name}: ${wb} would-block(s)${days ? ` over ~${days} day(s)` : ''} — ${verdict}`);
      if (wb >= minFirings && a.shadowSessions.size) {
        console.log(`    sample these sessions: ${[...a.shadowSessions].slice(0, 5).join(', ')}` +
                    (a.shadowSessions.size > 5 ? ` (+${a.shadowSessions.size - 5} more)` : ''));
      }
    }
    console.log('  This log records that a gate WOULD have fired. It does not record whether firing');
    console.log('  would have been right — a gate with a 100% false-positive rate writes exactly the');
    console.log('  same lines as one that never errs. Read the sampled sessions before switching mode');
    console.log('  to "enforce", or you are graduating an unmeasured gate.');
  }

  // Applied but silent. Not automatically a fault — secret-guard is supposed to
  // be quiet — but an inert hook and a hook with nothing to catch look identical
  // from here, and only one of those is fine.
  if (manifest) {
    const applied = new Set(
      Object.keys(manifest.files)
        .filter((f) => f.replace(/\\/g, '/').startsWith('.claude/hooks/'))
        .map((f) => path.basename(f).replace(/\.(sh|ps1)$/, ''))
        .filter((n) => !n.startsWith('_')),
    );
    const silent = [...applied].filter((n) => !assets.has(n)).sort();
    if (silent.length) {
      console.log('');
      console.log(`silent in this window: ${silent.join(', ')}`);
      console.log('  Either they had nothing to catch, or they are not registered in ' +
                  '.claude/settings.json, or they are inert (missing jq). Those need different ' +
                  'fixes and the log cannot tell them apart.');
    }
  }
}
// ---------- main ----------
const opts = args(process.argv.slice(2));
const cmd = opts._[0];
if (cmd === 'init') init(opts);
else if (cmd === 'apply') apply(opts);
else if (cmd === 'check') check(opts);
else if (cmd === 'report') report(opts);
else {
  console.log('usage: discipline.mjs <init|apply|check|report> --target <repo> [--components commands,hooks] [--force]');
  console.log('       discipline.mjs report --target <repo> [--since 7d|12h|ISO] [--min-firings 10]');
  process.exit(cmd ? 1 : 0);
}
