Skill to evaluate: $ARGUMENTS

Measure whether a skill changes outcomes. Hooks already get shadow mode — they
log before they block, so adoption is a query. Skills get nothing: one can ship,
be used for months, and nobody learns whether it moved a number or just spent
context. This command is that missing measurement.

Do NOT edit the skill in this step, and do NOT write scenarios in this step. A
scenario invented during its own eval measures nothing.

Format and scoring rules: `docs/plans/skill-eval-spec.md`. Scenarios and
fixtures: `scenarios/README.md`. Scenarios are not distributed by the pack:
they encode one repo's skills and its own past defects, so they live in the repo
being evaluated. A repo with no `scenarios/` directory gets NOT MEASURED, which
is the honest answer. Evidence tiers: the table in
`commands/arch-check.md` — same tiers, same hard rules, including that a
negative finding must show its searches.

Steps:

1. **Resolve the scenario set.** Every `scenarios/<skill-name>/*.yaml`. If there
   are none, stop and say so: an unmeasured skill is an unmeasured skill, and
   inventing scenarios here would score the skill against a test written by the
   thing under test. That is a **NOT MEASURED** verdict, not a zero.

2. **Check the fixtures for drift.** Each scenario names `pinned_from`. For any
   fixture that is a copy of a live file in this repo, diff the copy against that
   revision *and* against the current file. A fixture matching neither is
   corrupt — stop. A fixture matching its pin but not the current file is
   **stale**: it still scores, and the report says which behaviour it is scoring
   against. Silently scoring a skill against code that no longer exists is the
   most expensive failure this command can have, because the number still looks
   like a number.

3. **Run the control first.** For each scenario, run the task with the skill
   **not** loaded. This is the baseline, and it is the whole point: a skill whose
   scenarios pass identically without it costs context and buys nothing. Where
   the question is a *change* to an existing skill, the control is the previous
   version, not the empty prompt — say which control you used.

4. **Run each scenario by its declared class.** Do not build one procedure that
   pretends the two are the same kind of check.

   **`class: mechanical`** — the skill produces tests; mutants decide whether the
   tests are real.
   - Copy the fixture to a scratch directory. Never mutate the checked-in copy.
   - Run the skill on the scenario's `task`, keep the tests it produced.
   - Confirm the produced tests pass against the unmutated fixture. If they fail
     here, the run is void — report it and stop scoring this scenario.
   - For each mutant, in this order:
     - Read `requires`. If it is `none`, proceed.
     - If `injectable: true`, set up the condition described in `injection`
       before applying the patch. `tests/run.sh`'s `crlf_shim()` is the worked
       example: a fake `jq` on PATH that fabricates the Windows CRLF output, so a
       platform-specific defect is reproducible on every runner.
     - If `injectable: false` and the condition does not hold here, record
       **NOT-REACHABLE** with its reason and move on. It is excluded from the
       kill-rate denominator and named in the report. `tests/run.sh`'s
       `NOJQ_SKIP` is the precedent — a loud SKIP, never a silent pass.
     - Apply the patch, run the produced tests, expect `expect: fail`.
   - Score: killed ÷ (killed + survived). **Not-reachable mutants are not in
     that denominator and not in that numerator.** Name every survivor by id — a
     survivor names exactly which behaviour has no real test, which is the
     actionable output; the percentage is not.

   **`class: judged`** — the skill produces findings; planted issues decide
   whether the findings are real.
   - Assemble the input pack the way the skill under test requires it. For
     `code-review` that is Stage 1: the diff **and** the stated intent from the
     scenario's `intent` file. Handing over the diff alone manufactures false
     findings and then charges them to the skill.
   - Run the skill. Collect its findings with their severities.
   - Match findings against `planted_issues` using the skill's **own** verify
     mechanism — `judge: reuse-verify-stage` means `code-review`'s Stage 3
     refutation prompt, run over {reported finding} × {planted issue}. Do not
     write a second judge prompt: a judge that can disagree with the skill's own
     standard measures the judge.
   - Report three numbers, and the ids behind each:
     - **misses** — a planted issue with no matching finding. This is recall, and
       it is the metric `code-review` already names as its own.
     - **false findings** — a reported finding matching no planted issue *and*
       surviving refutation. A correct finding outside the planted set is a bonus
       catch, not a false finding; say which it was.
     - **severity errors** — a matched issue reported at the wrong rank. A review
       that puts a cosmetic finding beside a gate that refuses every push has a
       broken scale, and that is a different defect from missing it.
   - A judged verdict is `[INFERRED]` until a human has spot-checked the
     matcher's calls. Label it that way every time, including when the number
     looks good.

5. **Log every scenario through the existing event schema.** One line per
   scenario, same file, same shape as every hook firing — not a second log
   format:

   ```bash
   . .claude/hooks/_events.sh   # in this pack: hooks/bash/_events.sh
   disc_log "<skill>" eval "<mechanical-pass|mechanical-fail|judged>" "<scenario-id>: <score>, platform=<os/shell>"
   ```

   The platform belongs in there. CI runs the bash suite on ubuntu-latest and the
   PowerShell suite on windows-latest, and two of this pack's own shipped defects
   were each invisible on one of those, so a score without a platform is an
   average over the exact thing that hides.

6. **Return exactly one of two verdicts.**

   **MEASURED**
   > Control: [no skill | version X] — [its numbers]
   > With the skill: [its numbers], per platform
   > Delta: [what changed, per scenario]
   > Survived mutants: [ids] · Not reachable here: [ids + reason]
   > Misses: [ids] · False findings: [ids] · Severity errors: [ids]
   > Fixtures: [fresh | stale, and against which revision]
   > Evidence tier of this verdict: [OBSERVED for mechanical, INFERRED for judged]

   **NOT MEASURED**
   > What ran: [scenarios, classes]
   > Why no comparable number came out: [no scenarios | fixture corrupt | the
   > produced tests failed on the clean fixture | every mutant not reachable on
   > this platform | matcher never spot-checked]
   > STOP — do not report a pass rate. An unbacked number is worse than none,
   > because it gets quoted.

Rules:
- Never edit the skill under test, its scenarios, or its fixtures during an eval.
  If a scenario looks wrong, finish the run, then say so separately.
- **A pass rate with no control is not a result.** Report the delta or report
  NOT MEASURED.
- **Never fold NOT-REACHABLE into the pass rate.** That is the canary rule
  applied to this command: a check that cannot fail here has not passed here.
- Names, not rates. Every number is accompanied by the ids behind it.
- Two runs are comparable only if the fixture was identical. Say when it wasn't.
- No conclusion about *why* a skill scored the way it did unless the run produced
  evidence for it. A plausible story about a skill's weakness is the same failure
  mode the skill itself is being measured for.
