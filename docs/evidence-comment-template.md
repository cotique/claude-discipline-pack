# The evidence comment

Nothing counts as done until what was tested is written down where a reviewer will
find it. This is the template for that.

The done report the agent produces at the end of a session
([developer-guide.md](developer-guide.md), §"When it says done") lives in a
terminal that gets closed. The evidence comment is the same content moved to
where the work is tracked, so a reviewer six weeks later can tell what was
actually observed from what was merely believed.

Jira is used as the worked example below because it is the common case. Nothing
here is Jira-specific: any tracker with a comment field works, and so does a PR
description if that is where your reviews happen.

## The rule

> A ticket is not done until it carries a comment saying **what was tested, how,
> and what was not**.

Two things make it worth the two minutes:

- **"Not verified" is the part a reviewer reads.** Everything else is
  bookkeeping. A reviewer who knows which paths were never exercised can review
  in ten minutes instead of an hour.
- **An empty "not verified" section is a claim.** It says *everything* was
  verified, and that is almost never true. Leaving it blank is worse than leaving
  it long.

## Template

```markdown
**Verified**
- <command run> → <what it printed, including counts>
- <endpoint / UI path exercised> → <what was observed>
- Canary: <which check was made to fail on purpose, and how>

**Not verified, and why**
- <path / case / environment> — <reason: no fixture, needs prod data, needs a human>

**Changed**
- <files or modules, one line each>

**Yours next**
- <what the reviewer or the next person has to run or decide>
```

Four headings, in that order. `Verified` before `Not verified` reads as an honest
report; the other way round reads as an apology.

## Filled example

```markdown
**Verified**
- `dotnet test --filter Category=Reservations` → 214 passed, 0 skipped
  (executed-case count checked: 214, expected 214)
- Booking flow in the dev stand, Chrome → card renders the resource icon,
  updates on location change
- Canary: temporarily inverted the icon assertion → suite went red, restored

**Not verified, and why**
- Recurring-instance path — no fixture for a materialised tail instance; needs
  the sync round-trip, which is not reproducible locally
- Behaviour under the legacy toggle — no test environment has it enabled

**Changed**
- `reservationCard.tsx`, `resourceItemCard.tsx` — icon resolution
- `renderer.spec.ts` — three cases added

**Yours next**
- Confirm the exact toggle label against the ticket screenshot
- Decide whether the legacy-toggle path is in scope for this release
```

## On screenshots

Attach one when the claim is visual — a rendered component, a dashboard, a
console. A screenshot is evidence of a *state*, not of a *process*: it shows what
the screen looked like, not that the check can fail. Pair it with the canary line
or it proves less than it appears to.

Do not paste a screenshot of a passing test suite in place of the command and its
output. The text is searchable, diffable, and countable; the image is none of
those.

## What not to put in it

- **Credentials, tokens, connection strings, customer data.** A tracker comment
  is broadly readable and permanently indexed. Redact before pasting, and if a
  secret has already been pasted anywhere, rotate it rather than deleting the
  comment.
- **The agent's self-assessment.** "Implementation is robust and follows best
  practices" is not evidence. Commands, outputs, and observed behaviour are.
- **A verdict on someone's work.** This is an instrumentation record, not a
  review.

## Who writes it

The agent, as the last step of the work, from what it actually ran — not a person
reconstructing it afterwards from memory. A reconstructed record is the thing the
rule exists to prevent: by the time you are writing it from memory, the unverified
paths are exactly the ones you have forgotten.

Sending it is a human action. Draft automatically, post deliberately
([developer-guide.md](developer-guide.md), §"Never delegate these").
