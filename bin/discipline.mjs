#!/usr/bin/env node
/**
 * discipline — distribute the pack into product repos and keep it healthy.
 *
 *   node bin/discipline.mjs init  --target <repo> [--components commands,hooks]
 *   node bin/discipline.mjs apply --target <repo> [--force]
 *   node bin/discipline.mjs check --target <repo>
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
import { execSync } from 'node:child_process';

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
  }
  return pairs;
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

// ---------- main ----------
const opts = args(process.argv.slice(2));
const cmd = opts._[0];
if (cmd === 'init') init(opts);
else if (cmd === 'apply') apply(opts);
else if (cmd === 'check') check(opts);
else {
  console.log('usage: discipline.mjs <init|apply|check> --target <repo> [--components commands,hooks] [--force]');
  process.exit(cmd ? 1 : 0);
}
