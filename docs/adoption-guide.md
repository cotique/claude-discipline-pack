# Adoption guide

The pack is deliberately modular: each command and hook works alone. This guide
covers the two questions that actually decide what to enable — **how big is the
codebase** and **how are your repos laid out**.

## Scaling by project size

The commands assume Claude can build a correct mental model of the codebase
before writing code. How it should build that model depends on size.

| Project size | Orientation source | Code-graph layer | KB layer |
|---|---|---|---|
| **Small** — one service, < ~50k LOC | README + grep is enough | Skip — graph setup costs more than it saves | Optional |
| **Medium** — several modules, 50–300k LOC | README + targeted search | **Recommended** for `/arch-check`: impact analysis by hand starts missing edges at this size | Recommended once tribal knowledge stops fitting in CLAUDE.md |
| **Large** — many modules / monorepo, > ~300k LOC | Docs alone go stale; search alone is too noisy | **Strongly recommended** — the graph is the only truthful map of what depends on what | Strongly recommended; KB holds the *why*, the graph holds the *what* |

The LOC thresholds are heuristics, not laws. The real trigger for the graph
layer is this: if "what breaks when I change this class?" cannot be answered by
one grep, wire up a graph.

These thresholds are also enforced mechanically: `bin/discipline.mjs check`
measures the repo's tracked LOC and — unless a code graph is declared — warns
above `recommendAtLoc` (default 50k) and fails above `requireAtLoc`
(default 300k). The guideline above is the *why*; `check` is the *reminder that
doesn't rely on someone rereading this document*.

### What "code-graph layer" means here

Anything that can answer dependency queries over your codebase — a
Graphify-style dependency/call graph, an LSIF/SCIP index, Sourcegraph, Neo4j
over roslyn/ts-morph output. The pack doesn't ship one; it defines where it
plugs in, and it is deliberately indifferent to the delivery mechanism:

- `discipline.json` declares it as **`codeGraph.toolName`** (an MCP server),
  **`codeGraph.skill`** (a skill), or **`codeGraph.command`** (a CLI
  invocation). Any one of the three satisfies the size gate. The same tool
  often ships in more than one of these forms, and which one you run is an
  operational choice — a graph that answers the question through a skill is not
  a lesser graph.
- `/orient` step 4 pulls the top-level module graph instead of guessing
  structure from folder names.
- `/arch-check` step 3 queries the dependency neighborhood of the affected
  area and uses it as the impact map — inbound edges are your blast radius,
  outbound edges are the abstractions you should be reusing.

### Ask it structurally, not conversationally

Graph tools usually expose both a natural-language query and exact structural
lookups (*get this node*, *its neighbors*, *the shortest path between these
two*). **Use the structural ones.** A question like "which components render
X?" gets answered by traversing outward from whatever nodes the phrasing
happened to match — and when the seed is wrong the traversal still returns
something, confidently, from a part of the codebase that has nothing to do with
your change. One observed run wandered into a vendored ES5 bundle and reported
it as the answer.

That is a false green in graph form: a result shaped like a dependency fact,
produced from the wrong subgraph. So:

- **Resolve the exact identifier first, then traverse.** Look the node up by
  name, confirm it is the one you meant (file path, kind), and only then ask for
  neighbors or paths.
- **A traversal is `[OBSERVED]` only if the seed was verified.** Seeded from a
  guess, the result is `[INFERRED]` no matter how precise the edge list looks.
- Prefer *path* and *neighbor* questions over open ones: "what reaches this
  symbol" is answerable; "how does feature X work" is not a graph question.

### A graph is a snapshot, and a stale one is worse than none

The graph is built from a commit and starts aging immediately. A stale graph
answers confidently about structure that no longer exists — the same failure
class as a vendored file nobody re-applied, except a graph gives no visible
sign of it.

Two habits, and one mechanical check:

- Rebuild it when you rebase onto significant work, not on a calendar. Most
  tools have an incremental update; use it before an impact analysis you intend
  to trust, and re-merge if you keep one graph across several repos.
- Read the build commit out of the graph when the tool records one (most do)
  and compare it to `HEAD`. Distance in commits is the freshness signal.
- If the graph is more than a handful of commits behind and you cannot rebuild
  it now, downgrade every answer it gives to `[INFERRED]` and say so in the
  verdict.

Rule of thumb for graph **scope**: index at the boundary Claude works within.
Per-repo graph for a monorepo; per-repo graph *plus a package-level graph*
for multi-repo (see below).

## Repo topology: how the pack maps

### Model 1 — monorepo

The happy path. Install once at the repo root:

- One `discipline.json`, one set of protected branches, one settings file.
- `dod.fileGlobs` + per-path `format` globs scope the gates to the languages
  that live in the repo.
- A single code graph covers every internal dependency — `/arch-check` sees
  the full blast radius of any change, including cross-module edges.
- `/orient` reads one README tree and is genuinely complete.

Monorepo-specific tip: if different areas have different rules (e.g. stricter
DoD for `payments/`), keep one `discipline.json` but express it in the check
commands themselves (`dotnet test payments.sln`), not by forking the config.

### Model 2 — many sibling repos linked by packages (NuGet/npm)

Each repo is small, but the *system* is large and its edges are invisible: they
live in package manifests, not in any single checkout. Three adjustments:

1. **Install per repo, template the config.** Keep a canonical
   `discipline.json` template in a shared tooling repo (or ship the pack as a
   Claude Code plugin) and stamp it out; only `kb.projectTerms` and DoD
   commands differ per repo. Don't hand-maintain N divergent copies.

2. **The KB becomes the connective tissue.** In a monorepo the graph can
   answer "who uses this"; across repos it can't. Cross-repo knowledge —
   "package X is consumed by services A, B, C", "bump the major version only
   with a migration note" — belongs in the shared KB that
   `kb-first-reminder` points at. Same `toolName` in every repo's config.

3. **`/arch-check` gets a package-contract duty** (already wired in, step 6):
   when the touched code is a published package, the check must name the
   downstream consumers and classify the change as breaking or not. A
   breaking package change without a consumer-migration plan is an automatic
   NEEDS NEW ARCHITECTURE — that is exactly the class of change that must not
   ship on autopilot, because the blast radius is in repos Claude cannot see.

   Where does the consumer list come from? Best: a package-level graph
   (internal feed + reverse-dependency query — for NuGet, walk the feed's
   package metadata; for npm, an internal registry query). Acceptable: a
   hand-maintained `CONSUMERS.md` in each package repo — stale is still
   better than absent, and `/orient` will read it.

The gates behave identically in both models — protected branches, DoD, and
format checks are per-repo concerns by nature. What changes is where the
*architecture knowledge* lives: in the monorepo it's derivable from one graph;
in the package model it must be curated (KB + consumer lists), and the
commands are written to go look for it.

## Writing a new gate: three rules learned the hard way

Each of these came from a gate in this pack misbehaving in a live session, not
from design review. Apply them to anything you add.

### 1. Jurisdiction before dependencies

A gate must establish that this session is its business *before* it reports
anything at all — including its own broken setup. `dod-gate` once put its
"jq is missing, this is not a pass" check above every applicability test, and on
a session with no changed files, in a directory that was not a repository and had
no config, it returned `exit 2` for seventeen turns running. Every applicability
check would have passed the session in silence.

Order: loop guard → applicability (config present? inside a repo? anything
actually changed?) → dependency check → the work. On that last position the
"cannot read the checks" verdict is honest, because everything before it
established that there was something to read them *for*.

### 2. A loop guard must not depend on anything that can be missing

The same incident had a second half. `stop_hook_active` — the flag that stops a
Stop hook from blocking forever — was read through `jq`, so in the one failure
mode that fired on every single turn, the protection against an infinite loop was
itself unreachable. Read the re-entry flag with the crudest possible method
(substring match on the raw payload). Looser parsing is the correct trade here:
the guard has to survive exactly the conditions that break everything else.

### 3. Decide what a missing dependency means, and never let it mean "fine"

Measured on a machine without `jq`: four of five bash gates exited 0 and printed
nothing. A push to a protected branch and a literal secret both went through, and
the setup was indistinguishable from one where the rules simply allowed it. A
guardrail that vanishes quietly is worse than one that was never installed,
because its presence is still being counted on.

Three legitimate answers, and the choice is per-asset:

| Answer | When | Example |
|---|---|---|
| **Reduced** — keep guarding, on built-in defaults, and label the verdict | The asset's core job does not actually need the dependency | `block-protected-branch`, `secret-guard` |
| **Block** | The gate's absence is the whole risk and blocking is proportionate | `dod-gate`, once per session at the end |
| **Pass, but say so** | Nothing useful survives without the dependency | `format-postcheck`, `kb-first-reminder`, `dep-vuln-guard` |
| — | | never: pass in silence |

Reduced mode is the answer to reach for first, because the choice between
"vanish" and "refuse everything" is usually false. Both of the gates above do
their most important work with no parser at all: `block-protected-branch` ships a
default branch list (`main`, `master`, `develop`, `release/*`) and needs only the
command, which can be pulled out of the payload crudely; `secret-guard`'s
detectors are literals in the script and never needed `jq` — only the *custom*
pattern lists did. Losing a custom list is worth far less than losing the gate.

Three things reduced mode owes the reader:

1. **Label every verdict** `REDUCED`, so a block is never mistaken for a full
   check. Crude payload extraction stops at the first quote, so a command with
   escaped quotes comes back truncated — real lost coverage, stated rather than
   hidden.
2. **Err toward missing, not toward blocking.** A gate that fires on input it
   misread is how gates get switched off; that is the same reasoning as rule 1.
3. **Still honour an explicit off switch.** `"enabled": false` is the owner's
   decision, and a degraded gate must not override it just because it cannot
   parse the file — check for it crudely instead.

Alongside that, `session-envelope` reports once at session start which assets are
reduced and which are inert, so a degraded setup states itself instead of being
inferred. The PowerShell twins need no external parser and have no equivalent
failure mode — which is itself an argument for preferring them on Windows.

### 4. A dependency that is *present* can still differ by platform

Rule 3 is about a tool being absent. This one is worse, because everything looks
installed and working. The Windows build of `jq` emits CRLF, and a trailing `\r`
survives every line-wise read, so `case b.cs in *.cs<CR>)` never matched: the
definition-of-done gate was a complete no-op on Windows — no block, no message —
while reporting nothing wrong. With several protected branches configured, only
the last one was enforced. Custom secret patterns never matched.

Two habits that would have caught it:

- **Normalise at the boundary, not at the use site.** Strip `\r` on every capture
  of external-tool output, including single-value ones. `$()` looks safe and is
  not: it strips trailing *newlines*, and the carriage return sits in front of
  them — so an empty config value arrived as `"\r"`, `[ -n ... ]` saw a value, and
  the gate switched itself on. It happens to work on Git Bash, which drops the
  `\r`; depending on that is depending on a quirk.
- **Make the platform difference reproducible on every runner.** The Linux CI
  could not see this bug at all, because Linux `jq` emits LF. The regression test
  injects a `jq` shim that emits CRLF, so the failure exists everywhere the suite
  runs rather than only on the machine that reported it.

### 5. Put enforcement where the data is authoritative

The first four rules are about writing a gate well. This one is about not writing
it at all when a better layer exists.

A `PreToolUse` gate has to decide from a shell command line, and every defect this
pack's branch gate ever had was the same defect: no model of shell structure. It was
corrected once for quoting — a commit message containing "push main" read as a push
— and again for separators, where a token in a later segment of a chained command
was read as a push target while a *real* push in a later segment was missed
entirely. Both were observed live. The next instances were already predictable:
`$(...)`, `bash -c "git push …"`, `xargs`, backgrounding, multi-line scripts,
aliases. Patching instances does not end a class.

Three layers, and the difference between them is what they are allowed to know:

| Layer | Knows | Can be routed around |
|---|---|---|
| Forge rules (branch protection / rulesets) | The server's own decision: approvals, required checks, who may push, force-push and deletion bans, tag protection | No |
| `pre-push` git hook | The **real refs**, handed to it by git on stdin — no text to misread, and tags arrive as `refs/tags/*` for free | Only by removing the hook |
| `PreToolUse` hook | The text of a command that has not run yet | Trivially |

So the branch gate splits: `pre-push` refuses, and `PreToolUse` only warns for
pushes. A false positive in an advisory layer costs a sentence; in a blocking layer
it costs a session, and that is how gates get switched off. `PreToolUse` keeps its
`exit 2` for exactly the cases `pre-push` cannot see — a commit landing on a
protected branch, and a local branch deletion.

**A limitation worth writing down rather than discovering.** The top layer is not
always available. On GitHub, branch protection and rulesets on a **private**
repository require a paid plan; the API answers `403 Upgrade to GitHub Pro or make
this repository public`. Measured on this project: available and unconfigured on the
public repo, unavailable on the private one. Where the top layer is missing, an
"unapproved merge" cannot be prevented at all — a merge happens on the server, and
no local hook is in the path. What remains is the local hook for pushes plus a
human agreement for merges, and the honest thing is to say so rather than describe
a control that is not installed.

Pushing to `main` does **not** deliver anything. The marketplace entry carries the
version, so `claude plugin update` sees a new release only when
`.claude-plugin/plugin.json` *and* `.claude-plugin/marketplace.json` are both
bumped. A fix that is merged but not bumped sits invisible between the repository
and every installed cache — the cached copy keeps running the old code, including
the bug you just fixed. `claude plugin tag` validates that the two manifests
agree before it creates the release tag; use it rather than tagging by hand.

## Graduating from commands to project skills

The generic commands are a starting point, not an end state. They work on day
one precisely because they assume nothing — which also caps how much they can
enforce. As a project accumulates real decisions (a settled stack, conventions
born from actual bugs, a tradeoffs log), encode them into project-specific
skills using the templates in `skill-templates/`: a `plan-feature` /
`implement-plan` / `test-implementation` / `code-review` set that names your docs, your
modules, and your failure modes explicitly.

When you instantiate that set for a project, retire `/arch-check` and
`/implement` there — running the generic gate and the specific gate side by
side gives Claude two competing sources of truth for the same decision. The
hooks stay: branch protection, DoD, and format checks are mechanical per-repo
concerns that don't compete with the skills.

The lifecycle, in short: **hooks from day one, commands while the project is
young, skills once it has opinions.**

One question comes before writing any of them: **would a hook do this job?**
Skills are advisory, and advisory loses to an exit code. Reach for a skill when
the work needs judgement, and for a hook when it needs compliance — see
[skill-templates/README.md](../skill-templates/README.md), which also covers how
to write a project skill that still helps three weeks later (procedures rather
than conclusions, symbols rather than line numbers, and the exact command left
in).
