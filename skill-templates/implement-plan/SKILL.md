---
name: implement-plan
description: Writes code for «project» from an already-approved plan (see plan-feature). Use whenever the user asks to implement, build, or code up a task/feature that has a plan, or says "implement this", "write the code for X". Follows the project's established conventions and does not introduce new architectural decisions beyond what the docs already settled; if something isn't covered by the plan or the docs, stop and ask rather than guessing.
---

# Implement a plan for «project»

Work from an approved plan (from `plan-feature`, or given directly by the
user). Translate it into code that fits the existing conventions — this is not
the stage for making new architectural calls. If the plan is missing a
decision you need, stop and ask instead of inventing an answer. Docs that
deliberately deferred a decision to implementation time did not thereby
delegate it to whoever happens to be implementing.

## Structural conventions

«List the load-bearing rules of your codebase — the ones where a violation
compiles fine but breaks the design. Examples to replace:»

- «module layout: where new code goes, what requires flagging first»
- «mandatory abstraction layers: e.g. all external-service calls go through X;
  never import the SDK directly into business logic»
- «determinism/purity constraints: e.g. no I/O or clock access inside
  workflow/reducer code — side effects live in designated places»
- No speculative abstractions — build what the plan asks for, not a
  generalized version "in case" something needs it later.
- Comments only where the *why* isn't obvious from the code. Don't narrate
  what the code does.

## Conventions that exist in code (learned the hard way)

«Rules born from actual bugs in this repo — name the incident so the reason
survives. Examples to replace:»

- «secrets access pattern and its documented exceptions»
- «migration rules: what must never be edited after generation, and why»
- «privilege/role rules: which connection the app code must use, and what
  silently breaks when the wrong one is used»

## Before the first edit in a multi-repo session

Echo back, in one batch per repository: current branch, worktree list, short
status. Cross-repo sessions are where branch/base/worktree identity errors
cluster, and that state stops being re-read exactly when the conversation gets
long enough to need it.

## Execution style

Once a plan is approved, run the whole thing end to end — don't stop after
each file to check in. If a genuine ambiguity comes up, ask **before** acting
on an assumption, not after writing code that might need to be undone.

**Never commit without the user reviewing the changes first.** Implement,
verify, and report what's ready — the commit waits for the user to look at
the diff and say so.

## After writing code

Run «typecheck / lint / build / test commands» before considering the work
done. Apply the canary rule from `test-implementation`: a green check that has
never gone red in your hands is a claim, not evidence — and note that a local
toolchain can be greener than the CI-pinned one.

Report in four parts: **Changed** / **Verified** (literally what you ran and
what it printed) / **Not verified, and why** / **Yours next**.

If reality diverged from the approved plan (a bug forced a different approach,
scope narrowed, an extra migration appeared), append a "changed during
implementation: ..." note to the persisted plan file — the divergence is
*discovered* here, so recording it is this stage's job. If the implementation
introduced a new deliberate shortcut, add it to «tradeoffs log» with a revisit
trigger immediately — not at the end of the epic, when it's already been
rationalized away.

## When the plan and the docs disagree, or the plan is silent

Don't silently pick one — say what you see and ask. The reason planning and
implementation are separate stages is so architectural decisions get made
once, deliberately, with the user — not re-litigated implicitly during
implementation.
