Incident to debug: $ARGUMENTS

Find the cause of a production incident BEFORE any fix. Do NOT write code in this
step, and do NOT change configuration or restart anything.

Order matters: **logs → metrics → traces → hypothesis → verification.** Each
stage narrows what the next one has to search. Jumping to a hypothesis first and
then looking for evidence finds the evidence, every time.

Evidence tiers: the table in `commands/arch-check.md` — same tiers, same hard
rules. In particular, anything about a provider, runtime, deployment topology or
remote state needs `[OBSERVED]` or an explicit *"I have no verified source for
this"*. Local source cannot contradict a plausible story about a remote system,
so nothing in context will stop you telling one.

Steps:

1. **Fix the window and the identifiers before querying anything.** Symptom in
   one sentence, first and last observed occurrence, and the ids you can search
   on: request/trace/correlation id, entity id, tenant, user, job id. A log
   query without a window and an id returns volume, and volume reads as
   understanding. Separate **started** from **noticed** — if you only have
   "noticed", say so; the gap between them is where the cause usually lives.

2. **Query the knowledge base first, if one is configured** (`discipline.json` →
   `kb`). Ask for prior incidents on the same component, not for the component's
   design. A recurrence diagnosed from scratch costs the whole investigation
   twice, and this pack nudges KB-first for exactly that reason
   (`kb-first-reminder`). A KB answer carries the tier it was written with —
   which may be none. Treat `[KB]` as a lead, not as a finding.

3. **Logs.** If an observability MCP, skill, or command is configured
   (`discipline.json` → `observability`, declared the same way as `codeGraph`:
   `toolName`, `skill`, or `command`), query it. Otherwise say which log source
   you used and how you reached it.
   - Quote the actual lines. `[OBSERVED: query → result]` means the query text
     and what came back, not a summary of the mood of the logs.
   - **"The logs show nothing" is a claim about absence.** Show the query, the
     window and the result count, or downgrade it to *"I found none, searching
     for X and Y in window W."* An empty result from a wrong index looks
     identical to a healthy system.
   - Errors are the easy half. Look for what *stopped* appearing: a periodic job
     line that goes missing, a retry that never logs its success.

4. **Metrics.** Establish the shape and the start time, which logs are bad at.
   Error rate, latency percentiles, saturation, throughput, and the deploy or
   config timeline over the same window.
   - A dashboard that has never gone red in your hands is not a signal — the
     canary rule applies to observability itself. If a metric cannot be made to
     move, treat it as unproven rather than as evidence of health.
   - **Correlation with a deploy is `[INFERRED]` until it is bracketed.** Two
     data points make a line; the claim needs the symptom absent before and
     present after, on the same query.

5. **Traces.** One real failing request, end to end, and one succeeding request
   for contrast. Logs say what broke, a trace says *where* — which hop, which
   dependency, which retry storm. If tracing is not available, say so plainly
   here; the missing signal is part of the verdict.

6. **Structure, if a code graph is configured** (`discipline.json` →
   `codeGraph`). Resolve the exact node by name, confirm it is the one you meant,
   then ask for neighbors and callers to bound the blast radius. Structurally,
   not conversationally: a prose question traverses from whatever the phrasing
   matched and answers confidently from the wrong subgraph. Seeded from a guess,
   the traversal is `[INFERRED]`. Check the graph's build commit against `HEAD`.

7. **Hypothesis — falsifier first.** Write the falsifier line *before* the
   claim: *"this is wrong if ___"*, then go and check it, then present. A claim
   with no falsifier drifts toward whatever the human last objected to.
   - **Two refuted hypotheses mean stop, not a third story.** When a hypothesis
     is refuted the next move is a measurement, not a nearer-fitting narrative.
     Run `/stuck` rather than producing the alternative that best survives the
     objection you just got — a cause that migrates under social pressure
     instead of under new evidence is not converging on anything.
   - Name the competing explanations you ruled out, and what ruled each out.

8. **Verification — make it appear or disappear on demand.** A cause you cannot
   switch is a story that fits the data.
   - Reproduce it: the input, load, config, or race that triggers the symptom,
     in an environment you may touch. Never in production.
   - Or bracket it in what already happened: the symptom is present in every
     window where the condition holds and absent in every window where it does
     not, on the same query. Show both queries.
   - If neither is possible, the verdict is **INCONCLUSIVE**. That is a real
     result and it is much cheaper than a wrong fix on a live system.

9. **Return exactly one of two verdicts.**

   **ROOT CAUSE FOUND**
   > Symptom: [one sentence, with the window]
   > Evidence: [logs / metrics / traces, each line tagged with its tier]
   > Cause: [claim] — falsifier: [what would disprove it] — checked by: [how]
   > Ruled out: [competing explanations, and what ruled each out]
   > Blast radius: [who and what else is affected, tagged]
   > Fix: [the proposed change] — proceed with `/arch-check` if it needs new
   > structure, `/implement` if it does not
   > Not verified: [what remains unchecked, and why]

   **INCONCLUSIVE**
   > Symptom: [one sentence, with the window]
   > What was checked: [each stage, with tiers, including the empty results and
   > their queries]
   > What is missing: [the specific signal — name it; "more logs" is not a
   > signal]
   > Best current guess, explicitly labelled `[INFERRED]`, and the one
   > measurement that would settle it
   > STOP — do not ship a fix built on an unfalsified guess. A wrong fix on a
   > live system costs the incident twice and destroys the evidence.

Rules:
- Never write the fix in this step. The fix is a separate, gated step.
- Never mutate production to test a hypothesis. Read-only queries only; a
  restart is a hypothesis test that also destroys the evidence.
- `[INFERRED]` may not appear in an RCA, a KB write, a ticket comment, or a
  reply to a human. Upgrade it or drop it.
- **Write it back.** If a KB is configured and this incident produced something
  durable — the real cause behind a misleading symptom, a signal that lied, an
  operational gotcha — record it with its tier once the cause is `[OBSERVED]`.
  Never write an inferred cause into a KB: every future session that trusts it
  pays for it.
- If the incident is still burning and the ask is mitigation rather than
  diagnosis, say which one you are doing. Mitigating is legitimate; mitigating
  while reporting a root cause is not.
