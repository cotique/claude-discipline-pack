---
name: code-review
description: Reviews uncommitted or recently written code in «project» before it is committed — one entry point that fans out into fresh-context reviewers, verifies each finding before reporting it, and consolidates. Use at the end of a plan→implement→test cycle, whenever the user asks for a review, and always before proposing a commit. Fixes only what the user approves. Not an architecture review and not a spec-conformance review.
---

# Code review for «project»

One command, four stages: **gather → fan out → verify → consolidate.**

The goal is to catch what tests don't: conventions that quietly rot, boundaries
that got softened, and code that works today but misleads whoever reads it in
three months.

**A green test suite is not a passing review.** If the tests pass and the code
still has a problem, say so plainly.

---

## Stage 0 — where this runs

**Every reviewer gets a fresh context.** Do not review inline in the session
that wrote the code: there the review inherits every claim made while
implementing, including the ones that were reasoned rather than checked. An
unverified premise is indistinguishable from a verified one once it is in the
transcript, so the review ends up standing on the story instead of testing it.
Compaction makes it worse — summarising drops the "unverified" qualifier and
promotes the claim to a fact.

In practice: dispatch subagents (each gets its own context window), or run in a
new session. Never both write and review in one context.

**A fresh context removes inherited premises. It does not remove the model's own
blind spots** — those are shared across contexts. If your runtime lets you pick
the model per subagent, run the **verify** stage on a different model than the
finders: two models fail differently, so their agreement carries information.
That is also why this review is additive and never a substitute for a human
reviewer.

---

## Stage 1 — gather the input pack (once)

Assemble this once and hand the *same* pack to every reviewer, so findings are
comparable and nobody re-derives it four times:

| Include | Withhold |
|---|---|
| The diff: staged, unstaged, **and untracked files** — new files are the easiest to forget | The implementation transcript and its reasoning |
| The stated intent: the plan («plans location»), the task, the constraints the user gave | Approaches tried and abandoned mid-session |
| The conventions: «the implement-stage skill», «the tradeoffs/decisions log» | The implementer's own summary of what it built |

Withholding the reasoning is the point. **Including the intent is equally the
point:** without it a fresh reviewer produces confident false findings — "why not
do X?" — about alternatives that were ruled out for reasons it cannot see.

### Size the review to the diff

| Diff | Reviewers |
|---|---|
| A few hunks in one or two files | **One** fresh subagent, all lenses, no verify stage — the fan-out costs more than it finds |
| A normal change set | The four lenses below, in parallel, plus verify |
| Touches migrations, auth, money, or shared paths | All four lenses **and** verify on a different model, even if the diff is small |

---

## Stage 2 — fan out (one message, in parallel)

Dispatch all lenses **in a single message** so they run concurrently. Serial
dispatch is pure wall-clock loss with no correctness benefit.

Each lens gets the input pack, its brief, and the reporting contract from Stage 4.
Lenses are deliberately few and non-overlapping — five redundant reviewers cost
five times as much and bury the one finding that mattered.

**Lens A — correctness and seams.** Does the code do what the plan says and what
its own comments claim? Concentrate on the seams, not the middle: function bodies
are usually right; call sites, error paths and edge cases are where it breaks. On
failure, can the caller distinguish failure from success — silent catches and
swallowed errors are findings. **Any claim about "all callers" gets counted, not
assumed.**

**Lens B — test integrity.** Do the new tests exercise the new behaviour, or
assert on a mock's return? Is the interesting case covered or only the happy
path? **Would each new test fail without the fix?** If that was not checked, say
so — a test that passes both ways is decoration, and a large green suite is the
easiest place there is to hide a change nothing exercises. Anything found by hand
during this cycle must have a regression test.

**Lens C — load-bearing conventions.** «List this project's rules where a
violation is a real defect rather than a style opinion: the secrets access path,
migration rules, which connection or role may read user data, mandatory
abstraction layers, trusted-vs-untrusted input handling, what may go into a job
payload. Name the incident behind each rule where there was one — a rule with a
remembered cause survives; a rule without one gets argued away.»

**Lens D — security and data.** Is a new endpoint behind the auth guard, and
does it scope by the session user rather than a client-supplied id? Does new PII
reach a log, an error message, a model prompt, or a queue payload? Anything
touching identity, sessions, or account linking gets extra scrutiny.

---

## Stage 3 — verify before reporting

**A finding is a claim, and a wrong finding spends the user's time.** Every
candidate goes through one refutation pass before it reaches the report:

> Try to refute this finding: «finding». You have the same diff and intent.
> Default to *refuted* if you cannot show the problem is real. State which of
> `[OBSERVED]` / `[READ: path:line]` / `[INFERRED]` your conclusion rests on.

Drop what gets refuted. Keep what survives, carrying the tier its evidence
earned. Run these in parallel too, and on a different model than the finder
where you can.

This stage is also what stops lens overlap turning into noise: two lenses
reporting the same issue collapse into one finding with the stronger evidence.

---

## Stage 4 — consolidate and report

Dedupe across lenses, then rank. Be concrete: file, line, what's wrong, why it
matters, what the fix would be.

- **Must fix before commit** — correctness bugs, security issues, convention
  violations with real consequences.
- **Should fix** — costs time later, breaks nothing now.
- **Optional** — keep this short. Twenty nitpicks bury the finding that mattered.

**Each finding states its evidence tier:** `[OBSERVED: cmd → result]`,
`[READ: path:line]`, or `[INFERRED]`. Inferred findings are legitimate — *"this
looks like it swallows the error, I didn't run it"* is honest and useful — but
they must be labelled, because the user triages by confidence.

**Negative claims need their searches shown.** "Nothing else calls this" and "no
secrets reach the log" are claims about absence: cite what you searched, or
downgrade to *"I found none, searching for X and Y."*

Don't manufacture findings to look thorough. An invented finding costs real time
to evaluate.

### When nothing survives: report coverage, not a pass

An empty review is a **null result**, not assurance. Report, in three lines:

- what was examined — which lenses ran, which files and paths, which risks;
- what was deliberately **not** examined, and why (outside the diff, needs a
  running environment, needs domain knowledge nobody had);
- where an adversarial reviewer should start.

The reason is measured, not philosophical: consecutive "the diff is clean"
verdicts followed by human change requests are a known pattern, and they are
indistinguishable from a broken review until coverage is written down. Written
coverage is what makes a later miss diagnosable — **not examined**, or
**examined and missed**? Those have different fixes.

---

## After the review

Fix only what the user approves, then re-run «typecheck / lint / test» before
proposing a commit. **Never commit as part of this skill** — commits happen after
the human has looked at the diff.

## Measuring whether this review is any good

The ground truth is the human reviewer. Track two numbers over time:

- **Misses** — things the human raised that this review did not. This is the
  metric; it is what recall means for a review asset.
- **False findings** — things reported here that the human dismissed. A rising
  count means the verify stage is too permissive, not that the reviewer is
  thorough.
