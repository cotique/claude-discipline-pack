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
