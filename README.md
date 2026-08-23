# Claude Code Discipline Pack

Guardrails for agentic coding: a small set of slash commands and hooks that
make Claude Code behave like a disciplined senior engineer instead of an
enthusiastic intern with push access.

Everything here is config-driven and stack-agnostic.

## The philosophy

Four failure modes account for most of the damage an AI coding agent does:

1. **Building the wrong thing confidently** — inventing a new abstraction when
   the codebase already has one, because it never looked.
2. **Digging when stuck** — retrying variations of a failed approach, stacking
   workarounds, "one more attempt and it'll work".
3. **Trusting the green light** — reporting work as verified on the strength of
   a signal that could not have failed. This is the expensive one, and the
   least discussed: a suite that passes with zero executed cases, a linter
   green against a toolchain the CI doesn't use, a pipeline reporting success on partial
   input, an HTTP 200 from a fallback route. Nothing here
   is a lie the agent tells; it's a claim it never tested.
4. **Leaving the campsite dirty** — ending the session with a broken build,
   unformatted code, or a commit on `develop`.

The pack attacks each one with a *structural* control, not a polite prompt:

- an **architecture gate** that must pass before implementation starts;
- a **mandatory stop protocol** that converts "stuck" into a human decision
  point instead of a workaround spiral;
- a **canary rule** — no green signal counts as evidence until it has been
  made to go red once — plus a four-part done report that forces
  *not verified, and why* to be written down;
- **evidence tiers** (`[OBSERVED]` / `[READ]` / `[INFERRED]`) that make the
  difference between running something and reading about it syntactic, because
  a cited line number otherwise *feels* like verification;
- **hooks** that mechanically block protected-branch writes, refuse to end
  a session that fails the definition-of-done, and re-ground the operating
  state that compaction throws away.

**Why hooks and not instructions.** A review of three months of real agent
sessions found that advisory controls reliably lose: a rule delivered as
context gets discounted by its own hedging, and a non-blocking hook fires
*after* the decision it was meant to influence. A later measurement put a number
on it: in one setup, five hooks fired roughly three and a half thousand times
over six weeks and **stopped nothing, not once** — four of them being advisory by
construction. Firing is not enforcing, and counting firings is how a control that
does nothing looks busy. The same review found every
verification failure listed above, including one that reached production
through checks that were all green. Everything in this pack that matters is
therefore either a hard exit code or a report structure with a slot that is
embarrassing to leave empty.

Two findings from that corpus shaped specific pieces here. The first is stable
across two independently measured corpora: **asserting before reading accounts
for roughly half of all confirmed failures** — split between claims that one
command would have settled and root causes that drifted under objection rather
than under evidence. Hence the evidence tiers and the falsifier rule.

The second is that **verification is skipped or faked far more often than anyone
admits**, and reporting a green suite as proof of a fix that no test exercises is
routine. Hence the DoD gate, the canary rule, and the coverage-honesty rule.

A caution about that second one, because measuring it is harder than it looks:
detectors keyed to build and test *commands* overstate it — starting a local
stand, invoking the artifact directly, or writing a throwaway probe are all real
verification that no pattern recognises. Take any specific percentage you see
quoted for this (including ones in earlier drafts of this file) as an upper bound
that needs adjudication, not a measurement. What survives that scrutiny is the
direction, not the digits.

## Components

### Slash commands (`commands/`)

A gated workflow — each command is a phase with hard boundaries:

| Command | Phase | Hard rule |
|---|---|---|
| `/orient` | Understand the project | No code. Ends by demanding `/arch-check` before feature work |
| `/arch-check <feature>` | Design gate | No code. Returns SAFE TO IMPLEMENT or NEEDS NEW ARCHITECTURE — the latter halts everything |
| `/implement <feature>` | Build | Only pre-approved abstractions, smallest possible diff, must show proof it works |
| `/orchestrate <feature>` | Design-for-delegation | Produces a self-contained worker prompt instead of implementing |
| `/stuck` | Circuit breaker | No fixes. Diagnose, present options with tradeoffs, wait for a human |

Operational commands, outside the build workflow. Each is a sequence performed a
handful of times, always the same way, and each loses a step the moment it is
performed from memory — and nothing reports the loss, because every part that
ran succeeded:

| Command | Does | Hard rule |
|---|---|---|
| `/release <version>` | Cut and publish a version | Never tags a build that is not green **for that exact SHA**; publication is confirmed from outside the pipeline, not from its exit code |
| `/bump-dependency <name> <version>` | Move onto a new version of a dependency | A green build is not a green upgrade — it must be run against clean state, and the docs reconciled in the same change |
| `/cleanup` | Find what the work left behind | Enumerates with the evidence that each item is safe, removes only what the human confirms, and never on a name |

### Hooks (`hooks/bash/`, `hooks/powershell/` — functional twins)

| Hook | Event | Behavior |
|---|---|---|
| `block-protected-branch` | PreToolUse (Bash) | Blocks commits and resets that would land on a protected branch, and local branch deletion. **Pushes are warned about, not blocked** — they are refused by `pre-push` below, which is handed the real refs |
| `pre-push` | git hook (`.githooks/pre-push`) | **Refuses** pushes to a protected branch, tag pushes, and protected-branch deletion. Reads the refs git gives it on stdin, so there is no command text to misread; optional `blockAllPush` makes *every* push a human action. One implementation for both platforms — git runs it through `sh` |
| `dod-gate` | Stop | If uncommitted changes match configured globs, build/test checks must pass before the session may end |
| `format-postcheck` | PostToolUse (Edit/Write) | Runs your formatter check on the edited file, feeds violations back to Claude |
| `secret-guard` | PreToolUse (Bash/Edit/Write) + UserPromptSubmit | **Blocks** credential material heading into a file or a command; **warns only** when a human pastes one into the chat, because by then the transcript already has it and the useful action is rotating it |
| `kb-first-reminder` | UserPromptSubmit | Nudges Claude to query your knowledge-base MCP before spelunking code |
| `session-envelope` | SessionStart + PreCompact | Persists the operating state before a compaction and re-grounds it after, with a count of compactions so far. Re-grounds the operating state — branch, HEAD, worktrees, dirty count per repo, plus your standing constraints. Compaction keeps conclusions and drops exactly this |

All hooks read a single per-project config: `.claude/discipline.json`
(see [examples/discipline.example.json](examples/discipline.example.json)).
Missing config section = hook silently no-ops.

### Shadow mode and the event log

Two settings turn the guardrails from folklore into something you can audit:

```jsonc
"mode": "enforce",                    // "shadow" = log what would have been blocked, allow it
"events": { "enabled": true, "path": ".claude/discipline-events.jsonl" }
```

**`mode: shadow`** is how a gate earns its place before it can annoy anyone: for
one window it records every block it *would* have made and blocks nothing. That
log is the gate's measured value, collected without an argument. Shadow is a
bootstrap state, not a parking spot — `check` warns while a repo sits in it and
**fails** once it has been months, because a repo that believes it is guarded
and isn't is worse than one with no gates at all.

**The event log** appends one line per firing:

```jsonc
{"ts":"…","asset":"dod-gate","event":"block","verdict":"fail","mode":"enforce","sessionId":"…","durationMs":41200}
```

With it, the questions that decide whether an asset stays become queries rather
than research: how often did it fire, what did it catch, how often did a human
override it, and what did it cost. `durationMs` on the DoD gate is the price you
pay at every session end — weigh it against the intercepts.

Both settings live in the repo config, in git, on purpose: there is deliberately
**no runtime override**. A bypass would be used in exactly the sessions that
went badly, which are the ones worth measuring.

### Skill templates (`skill-templates/`)

Where a project goes after it outgrows the generic commands: skeletons for a
project-specific `plan-feature` / `implement-plan` / `test-implementation` /
`code-review` skill set that encodes *your* docs, conventions, and hard-won bug
lessons by name — and replaces `/arch-check` + `/implement` in that repo. See
[skill-templates/README.md](skill-templates/README.md) and the "Graduating"
section of the adoption guide.

## Install

### As a plugin (recommended)

```bash
claude plugin marketplace add cotique/claude-discipline-pack
```

Then install `discipline-pack` from the `cotique-plugins` marketplace (or run
`/plugin` in an interactive session). Commands arrive namespaced
(`/discipline-pack:arch-check ...`); hooks register automatically and stay
inert until you create `.claude/discipline.json` in a project.

Windows note: the plugin wires the **bash** hook implementations, which need
Git Bash and `jq` on PATH. If you don't want those, skip the plugin's hooks
and register `hooks/powershell/*.ps1` manually per project (see below) — the
commands are unaffected either way.

### Manual

1. Copy `commands/*.md` to `~/.claude/commands/` (user-wide) or
   `<project>/.claude/commands/` (per project).
2. Copy the hooks for your platform to `<project>/.claude/hooks/`.
3. Copy `examples/discipline.example.json` to `<project>/.claude/discipline.json`
   and adjust branches, globs, and check commands.
4. Merge the matching `examples/settings.hooks.*.example.json` into
   `<project>/.claude/settings.json`.

Requirements: `git`; `jq` for the bash hooks; PowerShell 7+ for the `.ps1` hooks.
On Windows, prefer the PowerShell hooks — Git Bash usually ships without `jq`,
and the `.ps1` set has no dependencies beyond PowerShell itself.

Note for `dod-gate` and `format-postcheck` check commands: use commands that
report problems on stdout/stderr and exit non-zero (any real build tool does)
— the hook relays their output to Claude verbatim.

## Team distribution: init / apply / check

The plugin installs per **user**. To roll the pack out per **repo** — so the
whole team gets it through git, pinned and drift-checked — use the bundled
CLI (Node 18+, no dependencies):

```bash
node bin/discipline.mjs init  --target ../my-repo --components hooks
node bin/discipline.mjs apply --target ../my-repo
node bin/discipline.mjs check --target ../my-repo
```

- `init` writes `.claude/discipline-manifest.json` (pack version pin, chosen
  components) and seeds `.claude/discipline.json` from the example if absent.
- `apply` vendors the pack files (`commands/` → `.claude/commands/`,
  hooks → `.claude/hooks/`) and records a sha256 for each. It never touches
  your config or anything it doesn't track, and refuses to overwrite locally
  edited pack files without `--force`.
- `check` fails on **drift** (a vendored pack file was edited locally — the
  fix belongs upstream in the pack) and on **reserved-name collisions** (a project
  command or skill named like a pack command — overlays are additive, never
  overriding). Run it in CI.

Pick components per repo maturity: a young repo takes `commands,hooks`; a
repo that has graduated to its own skill set (see below) takes `hooks` only.

## For the developer using it

[docs/developer-guide.md](docs/developer-guide.md) is the human-facing half —
what *you* do, not what the agent is told to do: how to hand off a piece of work
(with the good and bad version of the same request), the red flags in agent
output and the exact sentence to say back to each one, a ten-minute review
checklist for AI-written code, when to pull the handbrake, what never to
delegate, and what each gate means when it blocks you.

## Scaling it up

- **When to add a code-structure graph** (and what to point it at), and
- **how the pack maps onto a monorepo vs. many package-linked repos** (the
  NuGet-sibling model) —

both are covered in [docs/adoption-guide.md](docs/adoption-guide.md).

## Design notes

- **Blocking beats prompting.** `CLAUDE.md` rules are advisory; an exit-2 hook
  is not. Anything that must never happen (ending on a red build, a commit
  landing on `main`) belongs in a hook, not in prose.
- **Put the block where the data is authoritative.** A `PreToolUse` hook only
  ever sees the text of a command that has not run, and every defect the branch
  gate had was that same defect — corrected once for quoting (a commit message
  containing "push main" read as a push) and again for chaining, where a real
  push hidden in a later segment was missed while a foreign token in another
  segment was blocked. Both happened live. So pushes moved to `pre-push`, which
  git hands the actual refs, and the `PreToolUse` layer only warns. A false
  positive in an advisory layer costs a sentence; in a blocking layer it costs a
  session, which is how gates end up switched off. Three layers, and the
  difference is what each is allowed to know — see
  [docs/adoption-guide.md](docs/adoption-guide.md) for the table, including the
  limitation that branch protection on a **private** GitHub repository needs a
  paid plan, so an unapproved *merge* cannot be prevented locally at all.
- **Feedback loops close on Claude, not on you.** `format-postcheck` and
  `dod-gate` report failures *to the agent*, which fixes them in-session —
  you review clean diffs.
- **`/stuck` is the highest-leverage command in the pack.** The instruction it
  encodes — "do not express confidence that one more attempt will fix it" —
  is aimed at the single most expensive agent behavior in practice.

## Measuring whether it works

Guardrails that nobody measures decay into folklore. These signals are cheap to
collect from your own session transcripts and git history, and they move for
real reasons:

| Signal | Where it comes from | Direction |
|---|---|---|
| **Turns that changed code** and ran no build or test | Transcripts, adjudicated — a raw pattern count overstates this badly | Toward zero. Count turns that touched *code*, never sessions: a session is an arbitrary container, and where one session spans a whole project the rate measures nothing |
| Fix-up commits on an already-pushed branch for lint/test failures | `git log` | Should reach zero — those are exactly what the DoD gate prevents |
| Corrections per turn, single-repo vs multi-repo | Transcripts (one corpus: several times worse across repos) | Gap should close as the preflight and envelope hook take hold |
| "Recheck that" / "why didn't you" requests from the human | Transcripts | Down at constant work intensity |
| New recorded failure notes per month | Your feedback/memory files | Down at constant intensity; a *rise* right after adopting the canary rule is good news — it's finding things |
| Share of factual claims carrying an evidence tier | Agent output | Toward 100% for causal and state claims |
| KB reads : writes | KB/MCP logs (read-heavy in one corpus, write-only in another) | Toward balance — findings that never flow back get re-derived, or re-failed |
| Tool calls per assistant message; share of messages batching >1 | Transcripts (single digits for batching in both corpora measured) | Up — serialised independent reads are pure wall-clock loss |
| Plan/estimate revisions per task | Plan history | One plan plus event-driven updates, not a standing series of re-estimates |

**How to measure it honestly** — the traps are large enough to invert
conclusions. Two of them cost a real analysis most of its raw numbers:
resumed/branched sessions **double-count** (55% of raw tool calls in one
corpus), and auto-generated compaction banners get scored as human pushback
(45% of raw failure signals). Pattern-matching for failures ran 58–83%
false-positive even after those fixes, so counts need adjudication before they
mean anything. The single highest-precision signal was the agent's own
self-correction text: when it says "I was wrong", it essentially always was.

Two more traps, both found by re-running a corrected instrument on the same
window instead of arguing about it. **Verification detectors keyed to command
shapes miss real verification** — a local stand brought up, the artifact invoked
directly, a throwaway probe — and every miss inflates the headline. And
**adjudicating an incident inside a fixed context window fails on rules stated
far earlier**: a standing rule broken thousands of messages after it was set
reads as "no rule shown" to a reviewer holding three messages of context. Hand
the adjudicator the standing rules directly, and widen the window until the
episode closes rather than by a fixed offset.

Three things that look like metrics but aren't: wall-clock reconstructed from
transcripts (a proxy for intensity, inflated by overlapping sessions — not a
timesheet); one estimate compared against a later estimate of the same work
(churn, not accuracy); and per-model failure counts from ordinary session data
(model, workload, and context pressure are hopelessly confounded — the model
carrying the longest, most compaction-pressured, most cross-repo work will
"lose" every such comparison).

## Limits and threat model

- **Config commands are executed, not parsed.** `dod.checks` and `format`
  entries run via `eval` / `Invoke-Expression` by design: `discipline.json`
  lives in your repo, so review changes to it like code. The pack is a set of
  guardrails for a cooperating agent, not a sandbox for a hostile one.
- **`block-protected-branch` is a guardrail, not a security boundary.** It
  parses the command string with regexes and can be sidestepped (`git -C`
  elsewhere, aliases, scripts that push internally). It exists to stop an
  agent's honest mistake in the common case — keep server-side branch
  protection enabled for the guarantees.
- **Keep DoD checks fast.** Stop hooks run within Claude Code's hook timeout
  (60s by default). If your build+test exceeds it, either trim the check list
  (e.g. typecheck only) or raise the hook `timeout` in `settings.json`.

## Testing

`tests/run.ps1` (PowerShell) and `tests/run.sh` (bash, needs `jq`) replay
simulated Claude Code payloads against every hook in throwaway git repos and
assert exit codes. CI runs both suites on every push — Windows for the `.ps1`
set, Ubuntu for the `.sh` set.

## License

MIT
