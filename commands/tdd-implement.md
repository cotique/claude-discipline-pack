Feature to implement test-first: $ARGUMENTS

Implement this feature test-first. This step assumes `/arch-check` already
returned SAFE TO IMPLEMENT. It is a stricter sibling of `/implement`, not a
replacement — use it where a wrong green would be expensive: money, access
control, data migration, anything whose failure is silent.

This is not a new philosophy. The pack's canary rule already says **no green
signal counts as evidence until it has been made to go red once**. Writing the
test first is the cheapest way there is to satisfy it, because the red comes free
and arrives before there is any code to be attached to.

Steps:

1. **Write the test. Only the test.** From the feature description, in the
   project's existing framework and layout. No implementation, no stub that
   returns the expected value, not in the same edit and not "while I'm in there".
   The order is the mechanism, not a formality: a test written after the code
   inherits the code's assumptions, including the wrong ones.
   - One behaviour per test. A test asserting five things produces a red that
     does not name which of the five is missing.
   - Assert on observable behaviour — a return value, a stored row, a rejected
     call. A test that asserts on a mock's return value is a test of the mock.

2. **Run it, and read the failure.** It must fail, and it must fail **for the
   stated reason**. This is the step people skip, and skipping it is what makes
   the whole exercise decorative.

   | Failure you see | What it proves | Verdict |
   |---|---|---|
   | Assertion failure naming the missing behaviour | The behaviour is absent and this test detects it | **Red for the right reason** |
   | Import/collection error, syntax error, missing symbol | Only that the file does not load yet | Not yet red — fix the harness and re-run |
   | Fixture, factory, or seed-data error | The setup is wrong | Not yet red |
   | Connection refused, missing service, missing env var | The stand is not up | Not a verdict on anything — start it |
   | Zero tests executed, suite still "passed" | The runner never reached your test | Not yet red — check the *executed* count, not the registered one |

   Quote the failing output. If you cannot get a red that names the behaviour,
   stop and run `/stuck` — do not proceed to implement against a red you do not
   understand.

3. **Implement the minimum that turns it green.** Only the abstractions the
   arch-check approved. No speculative features, no configurability nobody asked
   for, no refactoring of adjacent code that is not in the way. If making it pass
   needs a pattern the arch-check did not approve, that is a design change: stop
   and go back to `/arch-check`.

4. **Never weaken the test to reach green.** Relaxing an assertion, widening a
   tolerance, deleting a case, marking it skipped — each of those converts a
   failing test into a passing decoration. If the test itself turns out to be
   wrong, say so explicitly, fix it, and **return to step 2**: a changed test has
   not been seen to go red yet.

5. **Run the full suite, not just your test.** Your green says the new behaviour
   works; the suite says you did not break what was already covered. Reuse what
   the repo already has — `dod-gate`'s configured build/test commands
   (`discipline.json` → `dod.checks`) are the same commands this step should run.
   Do not invent a second definition of "the tests pass".
   - Count *executed* cases, not registered ones, and say the number.
   - If a precondition is missing (no database, no Docker), that is "the checks
     did not run", not "the checks passed".

6. **Repeat per behaviour, not per feature.** Next behaviour, back to step 1. Two
   behaviours implemented against one test means one of them has never been red.

7. **Report in five parts.** The four from `/implement`, plus the one this
   command exists for:
   - **Red** — the test, and the failing output you observed before implementing,
     quoted. For each test: the assertion that failed and what it named. This
     section is the proof; without it this was `/implement` with extra steps.
   - **Changed** — test files and implementation files, separately.
   - **Verified** — literally what you ran and what it printed, including
     executed-case counts. Name which test exercises the changed path.
   - **Not verified, and why** — anything you could not check. Empty is a claim;
     make sure it is true.
   - **Yours next** — what the human has to review, run, or decide.

The words **done, complete, clean, ready to push** are prohibited unless a build
and a test run appear in the same turn, with their counts.

**If you implemented first and wrote the test afterwards, say so plainly and
call it `/implement`.** That is a legitimate workflow; it is not this one, and
the difference is not procedural — the test's power to detect the defect is
unproven, which is exactly the property this command exists to establish.

Rules:
- No commits or pushes unless explicitly asked.
- Never work directly on a protected branch.
- A test that passes both before and after the change is decoration. Delete it or
  fix it; do not report it as coverage.
- **Write back what you learned.** If a knowledge base is configured and the red
  step surfaced something durable — a behaviour the API does not actually have, a
  framework default that lies — record it with its evidence tier. Never write an
  `[INFERRED]` claim into a KB.
- If you get stuck, do not retry the same approach or stack workarounds. Run
  `/stuck`.
