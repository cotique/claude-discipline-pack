# Plan: additions from external feedback (2026-08-23)

## Status (2026-08-23)

Built in the order the pack owner set — 2, 1, 4, 3:

- **§2 skill evals** — three scenarios hand-authored against real past defects
  (`scenarios/`), the format changed in three places by what those cases forced
  (see the spec's "What authoring these scenarios changed"), and
  `commands/eval-skill.md`. No runner code: the command drives it, like every
  other command here.
- **§1 production debugging** — `commands/debug-incident.md`. The open question
  (which observability tool to assume) is answered by assuming none:
  `discipline.json` gains an `observability` section shaped like `codeGraph`.
- **§4a dependency scan** — `hooks/{bash,powershell}/dep-vuln-guard.sh|ps1`,
  registered in both settings examples, nine tests per suite.
- **§4b event report** — `discipline report`, with the graduation view and an
  explicit statement of what the log cannot tell you.
- **§3 TDD enforcement** — `commands/tdd-implement.md`.

Not done, and deliberately: no version bump or release notes — that is a
release decision, not part of building these.

---

Four items, in priority order set by the pack owner. Each section states what
already exists (verified by reading the actual files, not assumed from the
README), what is genuinely missing, and what to build.

## 0. What's already there (verified before planning, not assumed)

- **Secrets scanning**: `hooks/bash/secret-guard.sh` (+ PowerShell twin) already
  blocks credential writes and warns on prompt-pasted secrets, with placeholder
  detection and a degraded mode without `jq`. The "add a security scan" ask
  from the feedback thread is **already substantially covered** for secrets.
- **Event logging**: `hooks/bash/_events.sh` already logs every hook firing
  (asset, event, verdict, mode, sessionId, detail, duration) to
  `.claude/discipline-events.jsonl`. Raw observability data collection
  **already exists**.
- **CLI**: `bin/discipline.mjs` does `init` / `apply` / `check` (distribution
  and drift detection into target repos). No `report` command exists yet.
- **CI**: `.github/workflows/ci.yml` runs hook tests only. No dependency
  scanning (no Dependabot, no CodeQL, no `npm audit`/equivalent).

What this changes: item 4 below is narrower than the feedback comment implied.
Not "add security + observability" — specifically "add dependency-vulnerability
detection" (genuinely absent) and "add a report over the events that are
already being logged" (data exists, no analysis layer does).

## 1. Production debugging skill — priority 1

New command: `commands/debug-incident.md`, same shape as `arch-check.md`
(numbered steps, exactly one of two verdicts, no code written in this step).

Flow, matching the feedback thread's own ordering: **logs → metrics → traces →
hypothesis → verification**.

Reuses existing mechanisms rather than inventing new ones:
- **Evidence tiers** (already defined in `arch-check.md`) — every claim about
  what a log/metric/trace shows must be `[OBSERVED: query → result]`, not
  `[INFERRED]`. Reference the same table, don't redefine it.
- **Falsifier-first RCA rule** (already in `arch-check.md`) — the hypothesis
  step writes *"this is wrong if ___"* before presenting a root cause. This is
  the same rule, just applied to incidents instead of design decisions.
- **KB-first reminder** (`hooks/bash/kb-first-reminder.sh`) — query the KB for
  prior incidents on the same component before forming a hypothesis from
  scratch.
- **Code graph** (if configured) — same structural-query discipline as
  `arch-check` step 3: resolve the exact node, confirm it, then ask for
  neighbors/impact — not a natural-language traversal from a guess.

Verdicts, mirroring `arch-check`'s two-verdict shape:

> **ROOT CAUSE FOUND**
> Evidence: [logs/metrics/traces, each tagged]
> Hypothesis: [claim] — falsifier: [what would disprove it, checked]
> Fix: [proposed change] — proceed with `/implement`

> **INCONCLUSIVE**
> What was checked: [list, with evidence tiers]
> What's missing: [specific signal not available — name it, don't guess]
> STOP — do not ship a fix built on an unfalsified guess.

Open question to resolve before writing this: which observability
MCP/connector does the command assume (this pack is stack-agnostic — the step
should say "if an observability MCP is configured, query it for X" the same
way `arch-check` hedges on the KB and code graph, not hard-code a specific
tool).

## 2. Skill evals — priority 2

The most infrastructure-heavy of the four; needs its own short design pass
before a command gets written, not just a command.

**The core idea**: apply the same discipline that hooks already get (shadow
mode — measure before you trust) to *skills* (prompt/instruction files), which
currently have no equivalent. A skill can currently ship, get used, and nobody
learns whether it changed outcomes or just added context.

Sketch:
- A skill under evaluation runs against a fixed set of test scenarios (a
  scenario = a fixture prompt + defined pass/fail criteria — **this
  definition itself needs a short spec**, it's not obvious yet what "criteria"
  means generically across a stack-agnostic pack).
- Run the same scenarios with and without the skill (or old vs. new version).
- Score against the criteria, log results — either a new
  `.claude/skill-evals.jsonl` or an extension of the existing events schema
  (`_events.sh`) with a new `asset` type. Reuse the schema, don't invent a
  second logging format.
- New command: `commands/eval-skill.md` — takes a skill name, a scenario set,
  runs both variants, reports pass-rate delta, flags regressions.

**Do not start implementing this one directly** — the scenario-format mini-spec
is written and checked against `code-review` and `test-implementation`: see
[skill-eval-spec.md](skill-eval-spec.md). Next step per that spec: hand-author
2-3 real scenario files before writing the runner.

## 3. TDD-enforcement — priority 3

New command: `commands/tdd-implement.md`, parallel to `implement.md`, not a
replacement.

This is an application of a rule the pack already has, not a new philosophy:
the README's canary rule — *"no green signal counts as evidence until it has
been made to go red once"* — is exactly what a failing-test-first workflow
enforces, just not yet as its own gated command.

Flow:
1. Write the test from the feature description, before any implementation.
2. Run it. It must fail, **and fail for the stated reason** (a syntax error or
   missing import is not a red test proving the feature is absent — check the
   failure message names the actual missing behavior).
3. Implement the minimum to pass (ties to the "Simplicity first" rule already
   added to `arch-check.md`).
4. Run it again — green. Run the full suite (reuses `dod-gate.sh`'s existing
   build/test check, don't duplicate that logic here).
5. Verdict format matches `implement.md`'s existing proof-of-work requirement.

## 4. From item 3 of the feedback — dependency scan + event reporting — priority 4

Two separate, narrow additions (see §0 for why the broader "security +
observability" framing was replaced with these two specifics):

**4a. Dependency-vulnerability hook**: `hooks/bash/dep-vuln-guard.sh` (+
PowerShell twin, matching every existing hook's dual-implementation pattern).
Fires on writes to `package.json`, `*.csproj`, `requirements.txt`,
`go.mod`, etc. Shells out to the ecosystem's own tool (`npm audit`,
`dotnet list package --vulnerable`, `pip-audit`) rather than building a
custom CVE database — consistent with the pack's existing philosophy of
gating around real tools, not reimplementing them (same reasoning as
`secret-guard.sh` not trying to be a full secrets-manager). Shadow mode first,
same as every other blocking hook — measure the false-positive rate on a real
repo before it can block a commit.

**4b. Event-log report**: extend `bin/discipline.mjs` with a `report`
subcommand. Reads `.claude/discipline-events.jsonl`, aggregates by hook,
verdict, and mode. Purpose: answer "which shadow-mode controls have enough
firings to graduate to enforce" and "what's this hook's real trigger rate" —
the exact question the pack's own shadow-mode design implies but has no
built-in way to answer yet. This is the natural completion of a mechanism
that already half-exists, not a new one.

## Build order

1 (debug-incident) and 3 (tdd-implement) are ready to build directly — they
recombine existing primitives, no open design questions. 4a and 4b are ready
to build with standard care (new hook pair, new CLI subcommand, both following
established patterns in this repo). 2 (skill evals) needs a short spec
written and checked against 1-2 real skills before any code — start there
when its turn comes, not with the runner.
