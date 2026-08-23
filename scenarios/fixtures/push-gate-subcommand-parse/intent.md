# Stated intent for this diff

Handed to the reviewer with the diff, per `code-review` Stage 1: withholding the
intent is what makes a fresh reviewer produce confident false findings about
alternatives that were already ruled out.

## Task

`block-protected-branch.sh` matched git keywords anywhere in the command string,
so `git commit -m "push main fix"` read as a push to `main` and was blocked. A
gate that fires on legitimate work is how gates get switched off. Stop matching
raw text: strip quoted segments, then decide from the actual git subcommand.

## Constraints given

- The bash and PowerShell twins stay behaviourally in step; a fix landing in one
  only is not a fix.
- No new dependencies. `jq` and the shell's own builtins are what a hook gets.
- Existing config (`protectedBranches`, `blockAllPush`) keeps its meaning.
- Detections that already work must keep working: push to a protected branch,
  refspec pushes, `--delete`, `--force`, local branch deletion, and
  history-modifying commands while on a protected branch.

## Out of scope for this change

Moving enforcement out of the PreToolUse hook. That was raised and deferred: at
this point the text-parsing approach was still assumed to be fixable case by
case.
