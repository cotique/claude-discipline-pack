---
name: test-implementation
description: Writes and runs tests for code already implemented in «project» (see implement-plan). Use whenever the user asks to test, verify, add coverage for, or confirm that a feature works — e.g. "write tests for this", "does X work". Does not redesign the plan or the implementation — if a test reveals a real bug, report it and ask before changing implementation logic beyond what the test task covers.
---

# Test an implementation for «project»

## Test framework

«Name the framework and where its config lives — this was decided once, it is
not a per-session choice. State where specs live relative to the code.»

## Environment pre-check for integration tests

«How to check the local stand is up, and how to start it. Example: docker
compose ps / up -d, env file, migrations applied.»

A connection error is "the stand isn't running," not "the test failed" —
report the two differently.

## What to test, by layer

«Replace with your project's real layers. The template lists the common
shape:»

- **Pure functions** — plain unit tests. Cheapest tests in the system; don't
  skip them in favor of only testing at a higher level.
- **Anything touching access-control or tenancy** — run the code-under-test
  with the same restricted role/context a real request gets. Running it with
  an admin connection looks like it works but silently bypasses the security
  layer, so the test proves nothing about it.
- **Async/stateful orchestration (workflows, sagas, schedulers)** — use the
  framework's own test environment (time-skipping, virtual clock) rather than
  mocking its internals — otherwise you test your mocks, not the logic.
- **API endpoints** — don't stop at handler-level tests. Start the app
  against the local stand and hit real endpoints with real HTTP calls
  yourself — routing, middleware, and serialization bugs only show up over
  real HTTP.
- **External paid/nondeterministic services (LLMs, payment providers)** —
  never call the real thing in tests. Test through the abstraction layer with
  a stub, and verify the real integration separately and sparingly.

## The canary rule — a green signal is a claim, not a proof

Before any green result is allowed to support a conclusion, make it go red on
demand once. Signals that have never failed in your hands are indistinguishable
from signals that *cannot* fail — and the second kind is common:

| False-green mechanism | What actually happened | Cheap canary |
|---|---|---|
| Suite reports PASSED with zero executed cases | Registration succeeded; nothing ran | Compare *executed* case count against expected; assert it's non-zero |
| Nested/conditional test blocks silently skipped | The runner never reached them | Same: executed-count, per file |
| Linter green on a method that doesn't exist in the pinned CI version | Local toolchain differs from CI | Run the CI-pinned version, or diff versions explicitly |
| Pipeline exits 0 having dropped most of its input | Partial failure swallowed | Compare items out vs. items in; fail on shortfall |
| HTTP 200 from an SPA fallback treated as a live endpoint | The router served index.html | Check content-type and body size/shape, never status alone |

Practical form: insert a deliberately failing assertion (or point the check at
known-bad input) and confirm the runner reports it. If you cannot make a
check fail, report the verification as **unproven** rather than passing.

## Always leave a sandbox for manual testing

After your own automated passes are done and reported, leave the relevant
local service(s) running (or give the exact command to start them) so the
user can poke at the result themselves. Don't tear down what you started
without telling them how to bring it back up.

## Coverage honesty

A green suite says the change didn't break what was already covered. It does
not say the change works. Every report names **which test exercises the changed
path** — or states plainly that none does. A large passing suite is the easiest
place in the world to hide an untested change; a fix that reintroduces the
exact defect it was meant to close will pass thousands of unrelated tests.

## Scope discipline

Test what the plan and implementation actually cover — not a wishlist of
everything that could theoretically be tested. If a real bug turns up, report
it clearly (expected, actual, why) and ask before fixing it if the fix goes
beyond what you were asked to test. Testing that quietly turns into a second,
uncoordinated implementation pass defeats the purpose of separate stages.

## After running tests

Report in four parts, and keep them separate:

- **Changed** — test files added/modified.
- **Verified** — the commands you ran and what they printed, including the
  executed-case counts from the canary rule.
- **Not verified, and why** — anything untestable here (missing
  infrastructure, external dependency, needs a human). Never let a skipped
  check pass as a silent success.
- **Yours next** — what the human should run or decide.

Don't present an estimate as a fact; mark status accurately.
