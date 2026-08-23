# Skill-eval scenarios

Fixed test cases for the pack's own skills. Format and scoring rules live in
[docs/plans/skill-eval-spec.md](../docs/plans/skill-eval-spec.md); this directory
holds the scenarios themselves and the fixtures they run against.

**There is no runner yet, and that is deliberate.** The spec's own last section
says to hand-author real scenarios first and fix the format wherever it cannot
express a case that actually happened. These three are that pass. What they
changed in the format is recorded in the spec under "What authoring these
scenarios changed".

## What is here

| Scenario | Class | Real case it encodes |
|---|---|---|
| [code-review/push-gate-subcommand-parse](code-review/push-gate-subcommand-parse.yaml) | judged | A push gate that could be walked past by chaining, and that invented push targets. Both found live, long after review. |
| [code-review/config-read-carriage-return](code-review/config-read-carriage-return.yaml) | judged | A comment asserting `$()` reads were safe, which was true on one platform and refused every push on the other. |
| [test-implementation/events-config-reads](test-implementation/events-config-reads.yaml) | mechanical | Three config-read defects the pack shipped; each mutant is a revert of the commit that fixed it. |

Every fixture is checked in and pinned to the commit it was taken from
(`pinned_from`). A scenario that regenerates its own starting state is not
comparable between runs, which is the whole point of keeping them here.

## Ground rules these scenarios follow

- **Every planted issue is one a human actually found.** `confirmed_by` names
  the commit or the command that establishes it. No invented defects: a scenario
  that penalises a review for missing something that was never wrong measures
  nothing.
- **Rejected candidates get written down.** `config-read-carriage-return` carries
  one at the bottom — a plausible finding that turned out to be false when
  checked against the commit. Recording it stops the next author replanting it.
- **Severity is part of the test.** One issue is planted at `optional` on
  purpose. A review that ranks it with the must-fixes has a broken scale, and
  that is a different defect from missing it.
