Scope, if narrowing to one: $ARGUMENTS

Find what this work left behind, show it with the evidence that it is safe to
remove, and remove only what the human confirms.

Read `cleanup` in `.claude/discipline.json` if present; without it, use the
defaults named in each category.

```json
"cleanup": {
  "defaultBranch": "main",
  "containerLabel": "com.docker.compose.project=<project>",
  "scratchPaths": [".scratch", "tmp/"]
}
```

**Two failures this exists to stop.** The first is leftovers being invisible one
at a time: a worktree, a container, a merged branch — each too small to mention,
and together they are the reason a machine fills up and a repository stops being
readable. The second is worse: a cleanup that deletes on a guess. Nothing here
is removed on a name, a label, or a plausible story. Each item is removed on a
check that was run and printed.

**Enumerate first. Delete nothing before the list has been shown and answered.**

Categories, each item classified `safe` with its evidence or `unsafe` with the
reason:

1. **Local branches** whose tip is contained in the default branch. The test is
   `git merge-base --is-ancestor <branch> <defaultBranch>` — not the branch name,
   not the naming convention, and **not the pull request's state**: a PR page can
   read open long after its branch was merged, and reading it instead of the
   graph deletes or spares the wrong thing.

2. **Remote branches**, same test against the remote default branch. After a
   history rewrite, run the containment test against the *current* remote head:
   every pre-rewrite branch will look unmerged, and it is not.

3. **Worktrees** whose directory is gone, or whose branch is contained per (1).
   A worktree that refuses to be removed is usually a live process holding it —
   most often another session whose working directory is inside it. Find that
   owner and name it in the report; do not force-remove a directory somebody is
   sitting in.

4. **Containers, volumes, networks** created by this project's own runs, matched
   by the configured label or compose project — never by a name that looks
   similar. Anything not matched belongs to somebody else's work and is not
   yours to remove.

5. **Build leftovers.** Report what the tool itself says it reclaimed, from its
   own output. Do not estimate from a listing: `docker images --filter
   dangling=true` will happily list layers that a prune then declines to remove,
   and an estimate quoted as a result is a number the human now believes.

6. **Scratch directories** from the configured list.

Then:

- Print the classified list, grouped, with counts and the total each category
  would free.
- Ask which categories to remove. Nothing is removed without that answer.
- Remove, **never muting output**. A cleanup step whose failure is invisible is
  not a cleanup step: work continues on state that was supposed to be gone, and
  the next result is contaminated by data nobody knows is still there.
- Re-enumerate afterwards and print what remains, including anything that
  refused to go and why.

Report as **Removed / Kept, and why / Refused, and what holds it**.

Rules:
- Never remove anything classified `unsafe`, and never reclassify it to get on
  with the job.
- Backups, dumps and bundles are data until the human says otherwise, however
  temporary the directory they sit in.
- A container that is running is out of scope unless the human names it: it may
  be somebody's afternoon.
- If a category is empty, say so. An unmentioned category reads as clean when it
  may only have been skipped.
