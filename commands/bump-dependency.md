Dependency and version to take: $ARGUMENTS

Move this repository onto a new version of a dependency and prove it still runs.

**The failure this exists to stop is "it builds, ship it."** A build proves the
signatures still line up. It says nothing about whether the thing starts, and
nothing at all about the sentence in the docs that still names the version from
three releases ago — which stays wrong for as long as nobody greps for it.

Steps:

0. **Preflight.** Current branch, clean tree. Never do this on a protected
   branch; branch first.

1. **Find every place that names the dependency**, do not edit the manifest you
   happen to remember. Search the whole repo: lock files, container images, CI
   pins, sample configs, the README's quick-start line. A version bumped in one
   of two manifests is worse than not bumping it, because the build stays green.

2. **Build with this repository's own command.** Read it from CI or from the
   project's own instructions. Do not carry a command over from another project
   you were just in: a stricter flag from elsewhere turns pre-existing warnings
   into a wall of errors that has nothing to do with your change, and the
   twenty minutes that follow are spent on someone else's backlog.

3. **Run it, do not only build it.** Against clean state — a fresh database, an
   empty cache, whatever this service starts from — and watch the path the
   dependency is actually on. If the dependency is a scheduler, see something
   fire; if it is a client, see a request complete. State how long you ran and
   what you saw.

4. **Reconcile the docs with what is now true.** Grep for the old version string,
   then read the surrounding sentence: the stale part is often not the number
   but the claim next to it. Anything the upgrade invalidates gets corrected in
   this change, not later.

5. **Read the release notes for what is aimed at you.** Migration steps, changed
   defaults, a mixed-version warning. If the notes say the upgrade is not safe
   to roll while the old version is still running somewhere, that is a
   deployment instruction and it belongs in the report, not in your memory.

Report as **Changed / Verified / Not verified, and why / Yours next**. Under
Verified put what you ran and what it printed — the build command with its
counts, and the run with the evidence that the dependency did its job.

Rules:
- A green build is not a green upgrade. The words done, working and safe are
  prohibited unless step 3 appears in the same turn with its observations.
- If the new version changes an API this repo touches, stop and say so before
  adapting the call sites: that is a code change riding inside a version bump,
  and it deserves its own review.
- No unrelated dependency updates in the same change, however tempting the
  outdated list looks.
