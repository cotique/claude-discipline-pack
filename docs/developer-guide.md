# Writing code with an AI tool — a developer's guide

For the human. What the agent is told to do lives in `commands/` and
`skill-templates/`; this is your side of the desk.

**How to read this.** If you are new: work through it in order, the checklists
are meant to be followed literally until they are habit. If you have been
reviewing code for twenty years: read the next section and *Legacy codebases*,
skim the rest — most of your instincts transfer, but one of them is calibrated on
the wrong signal, and that is the section that says which.

Every rule here exists because it was measured going wrong, usually more than
once.

---

## What is actually different

You already know how to review code. The problem is what your reviewing reflex
is tuned to.

**Human-written mistakes usually look wrong.** Sloppy naming, copy-paste
残 left behind, an obvious missing null check, a function that grew hair. Your
eye is trained to find the mess and slow down where the mess is.

**This produces code that looks right and is sometimes wrong.** Clean naming,
plausible structure, a comment that explains an intention the code does not
implement, a method that does not exist called with perfect syntax, a test that
asserts something adjacent to the thing you asked for. There is no mess to
catch your eye, so nothing slows you down.

Two consequences worth internalising:

- **Confidence carries no information any more.** A wrong answer arrives with
  the same tone as a right one, and a citation (`path/file:line`) makes an
  unverified claim feel audited. In one measured corpus, **roughly half of all
  confirmed failures were claims that a single command would have settled** —
  they read exactly like verified statements.
- **The expensive failures are downstream of "verified".** Not "the code is
  bad", but "the check that said it was fine could not have failed": a suite
  passing with zero executed cases, a linter green against a toolchain CI does
  not use, a job exiting 0 after dropping most of its input. Same corpus: **half
  the sessions that wrote code ran neither a build nor a test.**

So the shift is not "be careful", it is *where* you spend care: less on style,
much more on whether a claim was observed or inferred, and on whether the check
you were shown was capable of failing.

---

## If you remember only five things

1. **You are the verification.** The agent produces; you decide whether it is
   true. Nobody else in the loop will.
2. **"Tests pass" is not "it works."** Ask which test covers the change. If none
   does, the change is untested however green the run was.
3. **If you cannot explain the diff, you cannot ship it.** Your name is on the
   commit; there is no version of code review where the agent takes the blame.
4. **Never paste a password, key, or token into the chat.** If you already did,
   rotate it today.
5. **When a gate blocks you, fix the state.** Don't look for the switch.

---

## Handing off a piece of work

One message with three parts. Not three messages — the third message
contradicting the first is the most common way a session sprawls.

**Bad:**

> can you fix the export thing

**Good:**

> In the reporting module, the CSV export writes the rows but skips the
> per-currency totals the header claims are there. Add them using the existing
> formatter helper.
> Out of scope: don't touch the schema, don't refactor the export route, this
> repo only.
> Done when: a test exports a two-currency fixture and asserts both totals, and
> that test fails if the totals are removed again.

| Part | Why |
|---|---|
| **The outcome**, with the area named | Vague scope gets filled with something plausible |
| **What is out of scope** | Scope creep is not wilfulness; it is silence being filled |
| **How you'll know it worked** | "Add tests" is a wish. "A test that fails without the fix" is checkable |

Three habits:

- **Don't feed files one at a time.** Point at the area and let it read. If you
  paste a file, wait, paste the next — you are the round-trip.
- **If you ask for a plan, read the plan.** Skimming and saying "ok" is latency,
  not a gate. Read it and push back on one specific thing, or skip the plan for
  work this small.
- **Put the constraint you keep repeating into config.** `envelope.notes` in
  `.claude/discipline.json` gets re-stated automatically instead of depending on
  your memory.

---

## While it works

| What you see | What to do |
|---|---|
| The same kind of fix failed twice | Stop it. A third variation is the same guess in a hat: *"stop — what measurement would tell us which of these is true?"* |
| Your objection produced a **new theory** instead of a check | The story is tracking you, not reality: *"don't give me another theory. What can we run that proves the current one wrong?"* |
| It is editing files while saying "probably" | Stop the editing. Investigation and mutation shouldn't interleave while something is unclear |
| It has been running a long stretch and you stopped reading | Read the last few steps now. Unrequested commits and quiet scope creep live in exactly these gaps |
| It is about to push | Push yourself. Approval never carries across a session: *"you said I could push last time"* is a real failure that happened |

**Don't reward speed with silence.** If it has been right for an hour and you
stop checking, that is when the next wrong thing lands.

---

## When it says "done"

Expect four parts. If you get prose, ask again:

- **Changed** — what was touched.
- **Verified** — literally what was run, and what it printed.
- **Not verified, and why** ← **read this first.**
- **Yours next** — what needs your decision.

**An empty "not verified" is a claim, not an achievement.** An agent with nothing
to put there stopped looking. Ask: *"what would you need to check this end to
end?"*

### Red flags and what to say back

| What you read | Say this |
|---|---|
| "should work" / "this will handle it" | *"Did you run it? Paste the command and the output."* |
| "tests pass" | *"Which test covers the changed path? Show me it failing without the fix."* |
| a `file:line` citation backing a **behaviour** claim | *"That's reading the code. Did you observe the behaviour or infer it?"* |
| "I couldn't find any usage of X" | *"Show me the searches you ran."* One empty grep does not establish absence |
| A confident claim about a queue, provider, or deployed environment | *"Local code can't tell you that. What did you query?"* |
| "The diff is clean, no issues found" | *"A zero-finding self-review is a null result. What would an adversarial reviewer look at?"* |
| A field, method, or config key you don't recognise | Grep it yourself. Invented-but-plausible surface is a real failure class |

One reliable tell: when it says *"I was wrong about that"*, it almost always was
— which tells you something about the confidence of everything it did **not**
correct.

---

## Reviewing the diff

Ten minutes, in this order. This is the job.

1. **Read the diff before the explanation.** Form your own view first; if you
   read the summary first you will simply agree with it.
2. **Check the seams, not the middle.** Function bodies are usually right. Call
   sites, error paths, and edge cases are where it breaks.
3. **Any claim about "all callers" — count them yourself.** "Every call site
   passes the id" has a habit of being true for most, not all.
4. **Prove the test.** Revert the fix and watch the test fail. A test that
   passes both ways is decoration — and a large green suite is the easiest place
   there is to hide a change nothing exercises.
5. **Grep one unfamiliar identifier.** Invented fields and methods look
   completely normal.
6. **If it touched twelve files where you expected three**, that is not
   thoroughness. Ask why; consider reverting and re-scoping.
7. **Can you explain every line?** If not: understand it, or don't ship it.

That last one is where the learning is, at any level. Ask *"why this way and not
X?"* — and on legacy code, ask it before letting anything change.

---

## Legacy codebases: when there is nothing to verify against

The advice above assumes a working test suite, a formatter, and a build you can
run in a minute. If your reality is a decade-old system with 4% coverage, a
forty-minute build, and documentation that describes a version that shipped in
2016, the principles hold but the tactics change.

**Use it for reading before you use it for writing.** The highest-value thing an
agent does in an old codebase is answer "where is this actually handled" and
"what calls this" across code nobody remembers. That work is verifiable by
inspection and cheap to check. Writing comes later.

**No test to prove? Write the characterisation test first.** Capture what the
code does *now* — not what it should do — and make that the fixture. Then the
canary rule works again: change the behaviour, watch the characterisation test
fail, decide whether that failure was intended.

**Don't let it refactor what it cannot verify.** An agent will confidently
modernise a load-bearing oddity, and the oddity is usually there because of
something that isn't in the repo: a client that sends malformed dates, a job that
depends on row order, a workaround for a vendor bug. When it proposes cleaning
something up, ask what it thinks the strange code was *for*. If it doesn't know,
that is your answer.

**Narrow the blast radius instead of trusting breadth.** In legacy, a one-file
change you can reason about beats a "consistent" ten-file change you cannot.
Prefer additive changes and adapters over touching shared paths.

**Make the gate affordable.** If your full build is forty minutes, do not put it
in the definition-of-done check — put the fast subset there (typecheck, unit
tests for the touched module, lint on changed files) and leave the long build to
CI. A gate you pay for at every session end must cost seconds to minutes, or it
gets disabled and then you have nothing. `durationMs` in the event log tells you
what you are actually paying.

**Your knowledge is the only documentation** — so the write-back rule matters
most here. Every "the real cause was X, not Y", every "this is here because of
that vendor", belongs in the knowledge base the moment you resolve it. Otherwise
the next session re-derives it, and the one after that gets it wrong.

**And the honest limit:** in a system where you cannot verify, the agent's
speed is a liability, not an asset. Go slower deliberately: smaller steps, more
observation, more commits. The tooling does not change what unverifiable means.

---

## Never delegate these

| Never | Why |
|---|---|
| Pasting secrets into chat | The transcript is written to disk and outlives the credential. Use the secret store or an env var name. **Already pasted? Rotate it now** — deleting the message is not remediation |
| Pushing | Set `blockAllPush` if you'd rather it be enforced than remembered |
| Committing on a protected branch | The pack blocks it; don't work around it |
| The final review | Agent review is additive: it cannot see its own blind spot, and its blind spot is its own green signals |
| Posting to the tracker or to customers | Drafting is fine. Sending is yours |

---

## Sessions, commits, compaction

**Commit small and often.** Commits are the boundary everything hangs on: the
DoD gate fires on uncommitted changes, review is easier per commit than per day,
and a bad hour becomes cheap to throw away.

**Start a fresh session after a change is verified and committed.** A session
that has run for days is not flow; it is a context that has been summarised
repeatedly.

**Watch the compaction count** printed at session start. Past two or three,
expect decay: instructions you gave once may be gone, and things flagged as
unverified can come back sounding like facts. The pack restores the mechanical
state across a compaction — branch, worktree, standing constraints — but it
cannot restore the caveat on a sentence. After a long stretch, re-state the one
constraint that actually matters.

---

## What the gates will do to your day

| When you see | It means | Do | Don't |
|---|---|---|---|
| `dod-gate` blocks the end of a turn | Uncommitted code, and the build or tests are red | Fix it or revert it | Don't end on red "to look at tomorrow" — that is how a broken tree gets forgotten |
| `block-protected-branch` blocks | A commit/push/reset/delete would hit a protected branch | Branch and retry | Don't edit the protected list to get past it |
| `format-postcheck` complains | The file just edited fails your linter | Let it fix it in-session | Don't push and fix up after — that commit is the thing this prevents |
| `secret-guard` blocks | Something in the command or file content looks like a real credential | Replace the literal with a secret-store lookup or an env var name | Don't work around it by splitting the string. If it misread a placeholder, add the pattern to `secrets.ignorePatterns` |
| `secret-guard` warns on your own message | You pasted a credential into the chat | **Rotate it now.** The transcript is on disk | Don't just delete the message — that is not remediation |
| A KB-first nudge appears | You asked a research question about this project | Let it check the knowledge base first, and write the answer back after | Don't go straight to code; that is how the same thing gets re-derived next month |
| The envelope warns about worktrees | This repo has more than one | Confirm which one you are in | Don't assume. Wrong-worktree edits look identical to correct ones until they don't |

- **Every firing is logged, including overrides.** That is not surveillance — it
  is how a badly calibrated gate gets found. If a gate is wrong, override it *and
  let the number show up*. Silently disabling it destroys the evidence that it
  was wrong.
- **Don't edit the pack's files inside your repo.** They are content-hashed;
  `check` reports your edit as drift forever and the next update reverts you
  silently. Change it upstream, then re-run `apply`.

---

## Your first week

1. `init` and `apply` into one repo — hooks only if the repo already has its own
   skills.
2. Fill in `.claude/discipline.json`: protected branches, a **fast** build/test
   command for the gate, your formatter, and the two or three constraints you
   repeat most.
3. If the repo had no enforcement before, leave `mode: shadow` for a few days:
   you get a log of what *would* have been blocked, with no arguments. Then
   switch to `enforce` — and don't park there, `check` starts failing on stale
   shadow deliberately.
4. On Friday read `.claude/discipline-events.jsonl` once: what fired, what it
   caught, what the checks cost.

---

## How you'll know it is working

Two questions, and neither is "does it feel faster":

- **Are you fixing things after the push?** Fix-up commits for lint and test
  failures on an already-pushed branch should trend to zero. That is the gates'
  whole job.
- **Are you repeating yourself?** Count how often you type "recheck that" or
  "why didn't you". Falling at the same workload is the signal. A spike right
  after you start demanding canaries is *good* news — things are being found
  that used to pass silently.

One caution, because it will tempt you: **the cheapest way to improve any speed
number is to skip verification.** Never read a throughput number without a
quality number beside it. In one measured corpus, half the code-writing turns ran
no build at all — and on every measure of speed, they looked excellent.
