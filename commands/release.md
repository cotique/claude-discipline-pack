Version to release: $ARGUMENTS

Cut and publish a release. Read `release` in `.claude/discipline.json`; every key
below is optional and the step that needs it is skipped, out loud, when it is
absent.

```json
"release": {
  "defaultBranch": "main",
  "tagFormat": "v{version}",
  "publishWorkflow": "publish.yml",
  "artifactCheck": "<command that resolves the published artifact from outside>",
  "consumers": ["../consuming-repo"]
}
```

**The failure this exists to stop is a sequence that lives in someone's head.**
It is performed a handful of times, always the same way, and the step that falls
off is never the loud one — it is the release notes, or the consumer that keeps
pinning the previous version, or the check that the artifact actually resolves.
Nothing reports a missing step, because the parts that ran all succeeded.

Steps:

0. **Preflight, one batch.** Repo identity (`git remote -v` — a fork or a second
   remote makes tooling target the wrong repository), current branch, clean
   tree, and whether local and remote agree on the default branch. Echo it back
   before anything is tagged.

1. **Refuse to tag anything but a green commit.** Look up CI for *that exact
   SHA*, not the latest run on the branch and not the PR's checks. In progress is
   not green; a run that succeeded on a different commit is not evidence about
   this one. If there is no CI, say so — that is a fact about the release, not a
   detail to skip past.

2. **Take the tag style from the last tag, do not invent one.** Read whether the
   existing tags are annotated or lightweight and what their messages look like,
   and match. A tag that publishes must look like its predecessors, or the next
   person reading the history sees two conventions and trusts neither.

3. **Write the notes before pushing the tag**, while the reasons are still in
   front of you. Diff against the previous tag for *what changed*, and read the
   previous release's own text for *what it promised* — a candidate that said
   "untried" is answered by this release or it is not. Notes assembled after
   publication get written from memory and shrink to a changelog.

4. **Push the tag, then watch the publish to completion.** Do not report from the
   push.

5. **Verify from outside the pipeline.** A workflow that exited zero is the
   pipeline's opinion of itself. Run `artifactCheck` and confirm the artifact
   resolves for a consumer who was not part of the build. Indexing lag is normal
   on public registries: retry before concluding failure, and never conclude
   success from the workflow's exit code alone. If the artifact never appears,
   say the publish is unconfirmed and stop.

6. **Create the release object** if the platform has one and previous versions
   have it. A tag without the release everything else has is the missing step
   that this command exists to catch.

7. **Bump the consumers** listed in config, each with `/bump-dependency`. A
   release nobody consumes has not been proven to work.

Report as **Changed / Verified / Not verified, and why / Yours next**, with the
version, the tag, the artifact's public identifier, and the test counts from the
run that gated it.

Rules:
- Never tag a red build, an in-progress build, or a commit you have not resolved
  CI for.
- **A published version is immutable.** Most registries refuse a re-push and none
  of them let you edit what was downloaded. A mistake is fixed by publishing the
  next version, never by re-tagging — and a tag that has already published must
  not be moved.
- Publication is irreversible and outward-facing: unless the human has said to
  publish in this session, stop before pushing the tag and ask.
- Do not invent the version. It comes from the argument or from the tag, and it
  is validated against `tagFormat` before anything is pushed.
