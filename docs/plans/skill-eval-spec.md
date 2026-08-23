# Spec: skill-eval scenario format

Prerequisite for §2 of `agent-feedback-additions.md`. Written before any
runner code, checked against two real skills already in this pack
(`code-review`, `test-implementation`) rather than designed in the abstract.

## Why two skills, and what they already reveal

Neither skill needed this spec invented from scratch — both already carry an
informal version of it:

- **`code-review`** ends with its own "Measuring whether this review is any
  good" section: two ground-truth numbers, **misses** (what the human caught
  that the review didn't) and **false findings** (what the review reported
  that the human dismissed). Nobody automates tracking this today.
- **`test-implementation`** already runs a canary rule — make a signal fail on
  demand before trusting it green. That is mutation testing without the name:
  plant a defect, confirm detection.

The spec below is these two patterns made uniform and runnable, not a new
idea layered on top.

## Finding: one format does not fit both — two scenario classes

Trying to force `code-review` and `test-implementation` into one scoring rule
produces a false uniformity. They differ on how a scenario's outcome gets
verified:

| | Mechanical | Judged |
|---|---|---|
| Example | `test-implementation` (mutation) | `code-review` (finding match) |
| Pass/fail decided by | Running the suite, reading exit code | Comparing a reported finding against a planted issue |
| Automatable end to end? | Yes | Partially — needs a matcher, and periodic human recalibration |
| Evidence tier of the eval's own verdict | `[OBSERVED]` | `[INFERRED]` unless the matcher's calls are themselves spot-checked by a human, same as `code-review`'s existing "ground truth is the human reviewer" line |

A scenario file declares its class. Don't build one runner that pretends both
are the same kind of check.

## Scenario file format

`scenarios/<skill-name>/<scenario-id>.yaml`

```yaml
skill: test-implementation          # must match a skill-templates/ directory name
class: mechanical                   # mechanical | judged
task: "write tests for the discount calculation in pricing.ts"
fixture: fixtures/pricing-base/     # known-good starting state, checked into the repo
mutants:                            # mechanical class only
  - id: off-by-one
    diff: fixtures/pricing-base/mutants/off-by-one.patch
    expect: fail                    # the produced tests must fail against this mutant
  - id: wrong-comparator
    diff: fixtures/pricing-base/mutants/wrong-comparator.patch
    expect: fail
```

```yaml
skill: code-review
class: judged
task: "review this diff before commit"
fixture: fixtures/payment-diff/      # a diff with issues planted on purpose
planted_issues:
  - id: swallowed-exception
    description: "catch block in payment.ts drops the error silently"
    severity: must-fix
  - id: missing-auth-scope
    description: "new endpoint doesn't scope by session user"
    severity: must-fix
judge: reuse-verify-stage            # score with code-review's own Stage-3 refutation prompt,
                                      # run against {reported findings} x {planted_issues}, not invented fresh
```

**Why `fixture` is a checked-in file and not a prompt-generated one**: a
scenario that regenerates its own starting state on every run is not
comparable across runs — the exact defect above the pass/fail line
(§4b's report needs runs to compare `run bash` to `run bash`).

## Scoring

**Mechanical**: mutant-kill rate = mutants where `expect: fail` actually
failed ÷ total mutants. 100% is the bar; report which mutant(s) survived by
id, never just the aggregate rate — a survived mutant names exactly which
behavior has no real test, which is the actionable output.

**Judged**: run the skill's *own* verify-stage mechanism (`code-review`
already ships a refutation prompt in Stage 3 — reuse that exact prompt
against `{reported finding} vs {planted issue}` pairs, don't write a second
judge prompt that could disagree with the skill's own standard). Two numbers,
matching the skill's own self-defined metric:
- **miss** = a `planted_issue` with no matching reported finding.
- **false finding** = a reported finding that doesn't match any
  `planted_issue` *and* survives a refutation check (so a correct finding
  outside the planted set — the review earning a bonus catch — is not
  penalized as a false finding).

## Logging

Extend the existing event schema (`_events.sh`), don't create a second log
format: `disc_log <skill-name> eval <mechanical-pass|mechanical-fail|judged> "<scenario-id>: <score detail>"`.
Same file, same schema, queryable by the `discipline report` command from
§4b once that exists — one report surface for hooks and skills both.

## What `commands/eval-skill.md` does once this spec is validated

Takes a skill name, runs every scenario under `scenarios/<skill-name>/`,
applies the scoring rule matching each scenario's declared class, reports
pass rate and names every miss/false-finding/survived-mutant explicitly —
never just an aggregate percentage, per the pack's existing coverage-honesty
standard (`test-implementation`'s own "Coverage honesty" section already
states this principle; this command applies it to itself).

## Before writing the runner

Author 2-3 real scenario files by hand for `code-review` and
`test-implementation` using this format and check they actually express real
past findings/regressions from this pack's own history. If the format can't
express a real case that already happened, fix the format before writing any
code against it.
