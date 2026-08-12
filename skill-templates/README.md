# Skill templates: plan → implement → test → review

The pack's slash commands (`/orient`, `/arch-check`, `/implement`) are
*generic* — they work on day one in any repo because they assume nothing about
it. That's their strength and their ceiling: they can tell Claude to "use
existing abstractions", but they can't name them.

As a project accumulates real decisions — a chosen stack, conventions born
from actual bugs, deliberate tradeoffs with revisit triggers — the highest-
leverage move is to graduate from the generic commands to **project-specific
skills** that encode those decisions by name. These templates are the skeleton
for that set:

| Template | Stage | Replaces |
|---|---|---|
| `plan-feature/` | Design gate: plan grounded in the project's own docs, approved before code | `/arch-check` |
| `implement-plan/` | Build from the approved plan; no new architectural calls | `/implement` |
| `test-implementation/` | Verify what was built; tests don't redesign | (new stage the commands don't cover) |
| `code-review/` | Last gate before a commit. One entry point, four stages: gather the input pack → fan out fresh-context lenses in parallel → refute each finding before reporting it → consolidate, or report coverage if nothing survives | (new stage the commands don't cover) |

## How to instantiate

1. Copy the four folders into `<project>/.claude/skills/`.
2. Replace every `«...»` placeholder with your project's real docs, modules,
   conventions, and commands. Delete sections that don't apply — a template
   section that survives without being made concrete is noise, not discipline.
3. Retire `/arch-check` and `/implement` for that project. Running both the
   generic commands and the specific skills creates two competing sources of
   truth for the same gate; the specific one wins, so remove the ambiguity.
4. Keep the hooks — they are per-repo mechanics (branches, DoD, formatting)
   and don't compete with the skills.

## Before you write one: should this be a hook instead?

**Ask this first, every time.** A skill is advisory, and advisory loses — a rule
delivered as context gets discounted by its own hedging, and it arrives *after*
the decision it was meant to influence. If what you are about to write down is
load-bearing — must never happen, or must always happen before something else —
it belongs in an exit code, not in prose. The hooks in this pack exist because
that lesson was learned the expensive way.

Write a skill when the thing needs **judgement** (which abstraction fits, how to
scope this, what to check for in review). Write a hook when the thing needs
**compliance** (never on this branch, never end on red, never write that
credential). Writing a skill for something a hook could enforce is the most
common way this discipline quietly stops working.

## How to write one that still helps in three weeks

The reader of a project skill is usually its author, having forgotten
everything. That audience does not need convincing — it needs the traps back.

**Write procedures, not conclusions.** This is the whole craft, and it is what
separates a skill that ages well from one that lies:

> ❌ "The icon bug is in `SummaryTile`, not `ListRow`."
> Correct today, wrong after one refactor, and *nothing warns you.*
>
> ✅ "Four components render a resource icon. Find which one your surface uses
> before touching anything — the obvious one was wrong twice."

Same length. Survives the refactor, and carries the trap instead of the answer.

**Symbols in instructions, line numbers in evidence.** These are different jobs
and the distinction matters: `[READ: path:line]` is how you show what you
actually read *now*; a durable instruction cites `UserPermissionValidator`,
because line 81 will have moved by next week.

**Say what it is *not*.** Half the value of a warning is "you will assume X —
it is not X". A bare positive instruction leaves the wrong prior in place.

**Leave the exact command in**, with its flags, copy-pasteable — including the
awkward one you needed to stop it running out of memory. "Run the typecheck" is
not the command.

**No "simply", no "just".** Every one marks a place where the author stopped
thinking, and it is exactly where the next reader gets stuck.

**Check whether you already wrote this.** Overlapping skills are worse than
none: you will find the stale one first. If it exists, edit it — `check` catches
name collisions but nothing catches two skills that quietly disagree.

**Spot-check the load-bearing claims against the code before writing them
down.** Your own transcript from an hour ago contains confident statements that
were wrong; that is normal, and it is why you check. Then say in the hand-off
which parts you did *not* verify — same rule as the done report, smaller scale.

### Retiring one

No review dates, no audit ritual: **when a skill misleads you, fix it in that
moment** — that is the whole maintenance policy. And if a skill has misled you
twice, delete it; it is load-bearing in the wrong direction. That is the
cheap version of a kill criterion, and a cheap one that is actually applied
beats a rigorous one nobody runs.

## What makes a good instantiation

The templates deliberately keep a few transferable rules verbatim — they earn
their place in any project:

- **A persisted plan is a frozen record.** If reality diverges during
  implementation, append a "changed during implementation: ..." note; never
  silently rewrite the plan to match what happened.
- **Implementation doesn't make architectural calls.** If the plan or the
  docs are silent on a decision, stop and ask — the whole point of separating
  the stages is that decisions get made once, deliberately.
- **An environment error is not a test failure.** "The database stand isn't
  running" and "the assertion failed" must be reported differently.
- **Leave a sandbox.** After automated tests pass, leave the service running
  (or give the exact start command) — a feature isn't done until the human
  has seen it move.
- **An empty review is a null result.** Nothing found is not assurance: report
  what was examined, what was not, and where an adversarial reviewer should
  start. Otherwise a miss cannot be told apart from a gap in scope.
- **Never write and review in one context.** A review that inherits the
  implementation's reasoning tests the story, not the code. Fresh context per
  reviewer; the intent is handed over, the reasoning is not.
- **A finding is a claim.** Refute it before reporting it — a wrong finding
  spends the user's time, which is the currency the review is supposed to save.

Everything else — doc names, module lists, framework rules — is yours to
fill in. The more specific you make it, the more it's worth; the specificity
IS the product.
