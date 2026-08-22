#!/usr/bin/env bash
# Test suite for the bash hooks. Mirror of tests/run.ps1.
# Run: bash tests/run.sh   (requires git, jq)
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
hooks="$root/hooks/bash"
work=$(mktemp -d)
failed=0

new_repo() { # branch -> path
  local dir; dir=$(mktemp -d "$work/repo.XXXXXX")
  git init -q -b "$1" "$dir"
  git -C "$dir" -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m init
  printf '%s' "$dir"
}

set_config() { # proj json
  mkdir -p "$1/.claude"
  printf '%s' "$2" > "$1/.claude/discipline.json"
}

run_hook() { # hook payload proj -> sets RC, OUT
  OUT=$(printf '%s' "$2" | CLAUDE_PROJECT_DIR="$3" bash "$hooks/$1" 2>&1)
  RC=$?
}

assert() { # name expect_rc [expect_out_substr]
  local name="$1" want="$2" sub="${3:-}"
  local ok=1
  [ "$RC" -eq "$want" ] || ok=0
  if [ -n "$sub" ] && ! printf '%s' "$OUT" | grep -qF "$sub"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    echo "PASS  $name"
  else
    echo "FAIL  $name (exit $RC, expected $want; output: $OUT)"
    failed=$((failed + 1))
  fi
}

# Making jq unavailable is environment-specific, and getting it wrong produces a
# green test for the wrong reason. Three cases, each handled explicitly:
#   - jq genuinely absent  -> that IS the condition under test; run as-is;
#   - jq present           -> run under a PATH holding the hook's other tools only;
#   - masking unusable     -> SKIP loudly. On Git Bash `ln -sf` copies the binary
#     and the copy cannot find msys-2.0.dll, so the masked tools silently return
#     nothing. That is how the original version of this test came to pass on a
#     failed `source` rather than on the guard it claims to exercise.
NOJQ_SKIP=""
mask_jq() { # -> echoes a PATH value where jq is unavailable, or empty if impossible
  local t p d probe
  # Cheapest and most faithful: drop the directory jq lives in. Works when jq has
  # its own bin dir (common on Windows); useless when it shares /usr/bin with
  # coreutils, which is the normal Linux layout.
  local jqdir; jqdir=$(dirname "$(command -v jq)")
  probe=$(printf '%s' "$PATH" | tr ':' '
' | grep -vxF "$jqdir" | paste -sd: -)
  if [ -n "$probe" ] && ! PATH="$probe" command -v jq >/dev/null 2>&1 &&
     [ -n "$(PATH="$probe" dirname /a/b 2>/dev/null)" ]; then
    printf '%s' "$probe"; return 0
  fi
  # Otherwise mirror every executable on PATH except jq. Naming the tools a hook
  # needs was tried first and is a losing game: the list silently goes stale the
  # moment a hook calls one more utility, and the test then fails for a reason
  # that has nothing to do with the code under test (it failed on `tail`).
  # On Git Bash this branch is unusable anyway — `ln -sf` copies the binary and
  # the copy cannot find msys-2.0.dll — hence the probe before trusting it.
  d=$(mktemp -d)
  printf '%s' "$PATH" | tr ':' '
' | while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    for p in "$dir"/*; do
      [ -x "$p" ] || continue
      t=$(basename "$p")
      [ "$t" = jq ] && continue
      [ -e "$d/$t" ] || ln -sf "$p" "$d/$t" 2>/dev/null
    done
  done
  if [ -n "$(PATH="$d" dirname /a/b 2>/dev/null)" ] && ! PATH="$d" command -v jq >/dev/null 2>&1; then
    printf '%s' "$d"
  else
    rm -rf "$d"
  fi
}
run_nojq() { # payload proj [hook=dod-gate.sh] -> sets RC, OUT; NOJQ_SKIP if it cannot run
  NOJQ_SKIP=""
  local bash_bin hook; bash_bin=$(command -v bash); hook="${3:-dod-gate.sh}"
  if ! command -v jq >/dev/null 2>&1; then
    OUT=$(printf '%s' "$1" | CLAUDE_PROJECT_DIR="$2" "$bash_bin" "$hooks/$hook" 2>&1); RC=$?
    return 0
  fi
  local masked; masked=$(mask_jq)
  if [ -z "$masked" ]; then NOJQ_SKIP="cannot make jq unavailable in this environment"; RC=0; OUT=""; return 0; fi
  OUT=$(printf '%s' "$1" | PATH="$masked" CLAUDE_PROJECT_DIR="$2" "$bash_bin" "$hooks/$hook" 2>&1); RC=$?
  case "$masked" in /tmp/*|"${TMPDIR:-/tmp}"/*) rm -rf "$masked" ;; esac
}
assert_nojq() { # name expect_rc [substr]
  if [ -n "$NOJQ_SKIP" ]; then echo "SKIP  $1 ($NOJQ_SKIP)"; return 0; fi
  assert "$@"
}

base_cfg='{"protectedBranches":["main","master","develop","release/*"]}'

# ---- block-protected-branch ----
feat=$(new_repo feature/test); set_config "$feat" "$base_cfg"
bp() { run_hook block-protected-branch.sh "{\"tool_input\":{\"command\":\"$1\"}}" "$feat"; }
bp 'git push origin main';                              assert 'warn: push to main advises, pre-push refuses' 0 'pre-push'
bp 'git push origin feature/test';                      assert 'block: push feature ok' 0
bp 'git push --force origin HEAD:refs/heads/develop';   assert 'warn: force refspec develop' 0 'pre-push'
bp 'git push origin :develop';                          assert 'warn: delete develop' 0 'pre-push'
# Still exit 2, deliberately: neither of these reaches a remote, so git never
# offers a hook with authoritative data. Everything push-shaped is a warning here
# and a refusal in .githooks/pre-push, which is handed the real refs by git.
bp 'git branch -D master';                              assert 'block: branch -D master' 2
bp 'npm test';                                          assert 'block: non-git ignored' 0

on_main=$(new_repo main); set_config "$on_main" "$base_cfg"
run_hook block-protected-branch.sh '{"tool_input":{"command":"git commit -m x"}}' "$on_main"
assert 'block: commit on main' 2

# A commit message is not a command. Measured in the field: the only intercept in
# a whole corpus was this false positive.
bp 'git commit -m "push main fix"';        assert 'block: "push" inside a commit message is not a push' 0
bp 'git commit -m "block push to main"';   assert 'block: "main" inside a message is not a target' 0
bp 'git commit -m "branch -D main is bad"'; assert 'block: "branch -D main" inside a message' 0
bp 'git -C /other push origin master';     assert 'warn: git -C elsewhere push still seen' 0 'pre-push'
bp 'git -c user.name=x push origin main';  assert 'warn: -c option before subcommand still parsed' 0 'pre-push'

# Chaining. Deciding from the first git invocation in the string failed both ways,
# and both were observed on a live setup: the bypass pushed to a protected branch
# for real, and the false intercept blocked a legitimate push because a later
# segment merely mentioned a protected name.
bp 'git remote set-url origin git@github.com:o/r.git && git push origin main'
assert 'chain: push after another git command is still seen' 0 'pre-push'
bp 'git status && git push origin main';        assert 'chain: push in a later segment is seen' 0 'pre-push'
bp 'echo hi; git push origin main';            assert 'chain: semicolon separator is seen' 0 'pre-push'
bp 'timeout 90 git push origin main';          assert 'chain: wrapper before git still parsed' 0 'pre-push'
bp 'git push origin feature/test && gh pr create --base main'
assert 'chain: --base main in another segment is not a push' 0
bp 'git push origin feature/test && ls release/notes'
assert 'chain: a path under a wildcard in another segment is not a push' 0
bp 'git push origin feature/test; echo done';  assert 'chain: feature push with a trailing command is allowed' 0

set_config "$feat" '{"protectedBranches":["main"],"blockAllPush":true}'
bp 'git push origin feature/test'; assert 'warn: blockAllPush warns on a feature push' 0 'pre-push'
bp 'git commit -m x';             assert 'block: blockAllPush allows commit' 0
set_config "$feat" "$base_cfg"

# ---- pre-push: the authoritative half, exercised with real pushes ----
# Calling the hook directly would prove nothing: its whole point is that git hands
# it the real refs on stdin. So this drives actual `git push` against a bare remote.
# The first version of the hook passed a direct-call test and still allowed a push
# to main — is_protected ran in a subshell inside a pipeline, so a match exited 0,
# the `&&` after `done` fired, and the function returned the inverse of the truth.
# Only a real push showed it.
pp_remote=$(mktemp -d "$work/remote.XXXXXX"); git init -q --bare "$pp_remote"
pp=$(new_repo main)
mkdir -p "$pp/.claude/hooks"; cp "$hooks/_events.sh" "$pp/.claude/hooks/"
set_config "$pp" '{"protectedBranches":["main","release/*"],"events":{"enabled":true}}'
cp "$root/hooks/git/pre-push" "$pp/.git/hooks/pre-push"; chmod +x "$pp/.git/hooks/pre-push"
git -C "$pp" remote add origin "$pp_remote"
echo x > "$pp/a.txt"; git -C "$pp" add -A
git -C "$pp" -c user.email=t@t.t -c user.name=t commit -q -m seed

pp_try() { # label want(refused|allowed) args...
  local label="$1" want="$2"; shift 2
  if git -C "$pp" "$@" >/dev/null 2>&1; then got=allowed; else got=refused; fi
  if [ "$got" = "$want" ]; then echo "PASS  pre-push: $label"
  else echo "FAIL  pre-push: $label (got $got, wanted $want)"; failed=$((failed + 1)); fi
}

pp_try 'push to main is refused'            refused push origin main
git -C "$pp" checkout -q -b feature/ok
echo y >> "$pp/a.txt"; git -C "$pp" -c user.email=t@t.t -c user.name=t commit -qam f
pp_try 'push to a feature branch passes'    allowed push origin feature/ok
git -C "$pp" checkout -q -b release/1.2
echo z >> "$pp/a.txt"; git -C "$pp" -c user.email=t@t.t -c user.name=t commit -qam g
pp_try 'wildcard release/* is refused'      refused push origin release/1.2
git -C "$pp" tag v9.9.9
pp_try 'pushing a tag is refused'           refused push origin v9.9.9
pp_try 'deleting main is refused'           refused push origin :main
pp_try 'deleting a feature branch passes'   allowed push origin :feature/ok

# The refusal must be recorded, or asset-effectiveness has nothing to count.
if [ -f "$pp/.claude/discipline-events.jsonl" ] &&
   grep -q '"asset":"pre-push","event":"block"' "$pp/.claude/discipline-events.jsonl"; then
  echo 'PASS  pre-push: refusals are logged'
else echo 'FAIL  pre-push: no block event logged'; failed=$((failed + 1)); fi

# Shadow mode must let it through and say so — the same escape hatch every other
# gate has, or a repo cannot adopt this incrementally.
set_config "$pp" '{"mode":"shadow","protectedBranches":["main"],"events":{"enabled":true}}'
git -C "$pp" checkout -q -b feature/shadow
echo s >> "$pp/a.txt"; git -C "$pp" -c user.email=t@t.t -c user.name=t commit -qam s
out=$(git -C "$pp" push origin HEAD:main 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q SHADOW; then
  echo 'PASS  pre-push: shadow allows and reports'
else echo "FAIL  pre-push: shadow (rc=$rc): $out"; failed=$((failed + 1)); fi

# ---- dod-gate ----
dod=$(new_repo feature/test)
echo 'const x = 1' > "$dod/dirty.ts"
set_config "$dod" '{"dod":{"fileGlobs":["*.ts"],"checks":[{"name":"pass","command":"true"}]}}'
run_hook dod-gate.sh '{"stop_hook_active":false}' "$dod";  assert 'dod: green check allows stop' 0
set_config "$dod" '{"dod":{"fileGlobs":["*.ts"],"checks":[{"name":"fail","command":"echo boom && exit 1"}]}}'
run_hook dod-gate.sh '{"stop_hook_active":false}' "$dod";  assert 'dod: red check blocks stop' 2 'boom'
run_hook dod-gate.sh '{"stop_hook_active":true}'  "$dod";  assert 'dod: stop_hook_active guard' 0
set_config "$dod" '{"dod":{"fileGlobs":["*.cs"],"checks":[{"name":"fail","command":"exit 1"}]}}'
run_hook dod-gate.sh '{"stop_hook_active":false}' "$dod";  assert 'dod: no matching dirty files' 0

# ---- format-postcheck ----
fmt=$(new_repo feature/test)
set_config "$fmt" '{"format":{"*.ts":"exit 1"}}'
run_hook format-postcheck.sh '{"tool_input":{"file_path":"/x/app.module.ts"}}' "$fmt"; assert 'format: violation feeds back' 2
set_config "$fmt" '{"format":{"*.ts":"true"}}'
run_hook format-postcheck.sh '{"tool_input":{"file_path":"/x/app.module.ts"}}' "$fmt"; assert 'format: clean file passes' 0
run_hook format-postcheck.sh '{"tool_input":{"file_path":"/x/README.md"}}' "$fmt";     assert 'format: non-matching ignored' 0

# ---- code-graph gate: any declaration form satisfies it ----
cg=$(new_repo feature/graph)
for i in $(seq 1 600); do echo "const x$i = $i;" >> "$cg/big.ts"; done
git -C "$cg" add -A && git -C "$cg" -c user.email=t@t.t -c user.name=t commit -q -m add
# check needs an initialised install, or every case exits 1 for the wrong reason
node "$root/bin/discipline.mjs" init --target "$cg" --components hooks >/dev/null
for form in '{"codeGraph":{"recommendAtLoc":100,"requireAtLoc":200}}'             '{"codeGraph":{"toolName":"g","recommendAtLoc":100,"requireAtLoc":200}}'             '{"codeGraph":{"skill":"code-graph","recommendAtLoc":100,"requireAtLoc":200}}'             '{"codeGraph":{"command":"npx depgraph","recommendAtLoc":100,"requireAtLoc":200}}'; do
  set_config "$cg" "$form"
  out=$(node "$root/bin/discipline.mjs" check --target "$cg" 2>&1); rc=$?
  if printf '%s' "$form" | grep -q 'toolName\|skill\|command'; then want=0; label='graph declared -> gate satisfied'
  else want=1; label='no graph over threshold -> gate errors'; fi
  if [ "$rc" -eq "$want" ]; then echo "PASS  codeGraph: $label"
  else echo "FAIL  codeGraph: $label (exit $rc, expected $want): $out"; failed=$((failed+1)); fi
done

# ---- CRLF must not read as drift ----
crlf=$(new_repo feature/crlf)
node "$root/bin/discipline.mjs" init --target "$crlf" --components hooks >/dev/null
node "$root/bin/discipline.mjs" apply --target "$crlf" >/dev/null
victim="$crlf/.claude/hooks/dod-gate.sh"
# rewrite the copy with CRLF endings, the way a target repo with
# core.autocrlf=true would on checkout (pure sed: no escape-eating shells)
sed -i -e 's/\r$//' -e 's/$/\r/' "$victim"
node "$root/bin/discipline.mjs" check --target "$crlf" >/dev/null 2>&1
if [ $? -eq 0 ]; then echo 'PASS  drift: CRLF rewrite is not drift'
else echo 'FAIL  drift: CRLF rewrite reported as drift'; failed=$((failed+1)); fi
echo '# a real local edit' >> "$victim"
node "$root/bin/discipline.mjs" check --target "$crlf" >/dev/null 2>&1
if [ $? -eq 1 ]; then echo 'PASS  drift: a real edit is still caught'
else echo 'FAIL  drift: real edit missed'; failed=$((failed+1)); fi

# ---- shadow mode + event logging ----
sh=$(new_repo feature/shadow)
set_config "$sh" '{"mode":"shadow","protectedBranches":["main"],"events":{"enabled":true}}'
run_hook block-protected-branch.sh '{"session_id":"s1","tool_input":{"command":"git push origin main"}}' "$sh"
assert 'shadow: push to main warns and is logged' 0 'pre-push'
log="$sh/.claude/discipline-events.jsonl"
# `warn-push` regardless of mode: shadow suppresses blocking, and this layer has no
# blocking left to suppress for pushes. The event must still be there to count.
if [ -f "$log" ] && head -1 "$log" | grep -q '"event":"warn-push"' && head -1 "$log" | grep -q '"mode":"shadow"'; then
  echo 'PASS  shadow: event line has warn-push/shadow'
else echo 'FAIL  shadow: event log missing or wrong'; failed=$((failed+1)); fi

set_config "$sh" '{"mode":"enforce","protectedBranches":["main"],"events":{"enabled":true}}'
run_hook block-protected-branch.sh '{"tool_input":{"command":"git push origin main"}}' "$sh"
assert 'enforce: push to main warns, pre-push refuses' 0 'pre-push'
if tail -1 "$log" | grep -q '"event":"warn-push"'; then echo 'PASS  enforce: warn-push event appended'
else echo 'FAIL  enforce: block event missing'; failed=$((failed+1)); fi

set_config "$sh" '{"protectedBranches":["main"],"events":{"enabled":false}}'
before=$(wc -l < "$log")
run_hook block-protected-branch.sh '{"tool_input":{"command":"git push origin main"}}' "$sh"
if [ "$(wc -l < "$log")" -eq "$before" ]; then echo 'PASS  events: disabled writes nothing'
else echo 'FAIL  events: wrote while disabled'; failed=$((failed+1)); fi

dg=$(new_repo feature/shadow-dod)
echo 'const x=1' > "$dg/x.ts"
set_config "$dg" '{"mode":"shadow","dod":{"fileGlobs":["*.ts"],"checks":[{"name":"f","command":"exit 1"}]}}'
run_hook dod-gate.sh '{"stop_hook_active":false}' "$dg"
assert 'shadow: dod-gate allows stop but logs' 0 'SHADOW'

# ---- session-envelope ----
env1=$(new_repo feature/envelope)
set_config "$env1" '{"envelope":{"repos":["."],"notes":["never switch branches in the sibling repo"]}}'
run_hook session-envelope.sh '{"source":"startup"}' "$env1"
assert 'envelope: reports branch' 0 'branch=feature/envelope'
assert 'envelope: reports constraints' 0 'never switch branches'
env2=$(new_repo feature/plain)
run_hook session-envelope.sh '{"source":"resume"}' "$env2"
assert 'envelope: no config still runs' 0 'operational envelope'
set_config "$env2" '{"envelope":{"repos":[".","../nope"]}}'
run_hook session-envelope.sh '{"source":"startup"}' "$env2"
assert 'envelope: missing repo noted' 0 'not a git worktree'

# ---- PreCompact persists state, SessionStart hands it back ----
pc=$(new_repo feature/compact)
set_config "$pc" '{"envelope":{"repos":["."],"notes":["deliverable is a patch"]}}'
for i in 1 2 3; do
  run_hook session-envelope.sh '{"hook_event_name":"PreCompact","session_id":"pet-1"}' "$pc"
done
sf="$pc/.claude/session-state.json"
if [ -f "$sf" ] && [ "$(jq -r '.compactions' "$sf")" = "3" ] && [ "$(jq -r '.sessionId' "$sf")" = "pet-1" ]; then
  echo 'PASS  compact: state persisted with count and envelope'
else echo 'FAIL  compact: bad or missing state file'; failed=$((failed+1)); fi
run_hook session-envelope.sh '{"hook_event_name":"SessionStart","source":"compact","session_id":"pet-1"}' "$pc"
assert 'compact: count handed back' 0 'compactions so far in this session: 3'
assert 'compact: nudge past threshold' 0 'clean boundary'
run_hook session-envelope.sh '{"hook_event_name":"SessionStart","source":"startup","session_id":"other"}' "$pc"
if ! printf '%s' "$OUT" | grep -q 'compactions so far'; then echo 'PASS  compact: count resets for a new session'
else echo 'FAIL  compact: count leaked across sessions'; failed=$((failed+1)); fi

# ---- dod preconditions: a missing environment is not a verdict ----
pre=$(new_repo feature/pre)
echo 'const x=1' > "$pre/x.ts"
set_config "$pre" '{"dod":{"fileGlobs":["*.ts"],"preconditions":[{"name":"docker daemon","command":"exit 1","remedy":"Start Docker, then retry."}],"checks":[{"name":"t","command":"true"}]},"events":{"enabled":true}}'
run_hook dod-gate.sh '{"stop_hook_active":false}' "$pre"
assert 'dod: failed precondition blocks' 2 'Cannot run the checks'
assert 'dod: says it is not a verdict' 2 'not a verdict on your changes'
assert 'dod: prints the remedy' 2 'Start Docker'
if tail -1 "$pre/.claude/discipline-events.jsonl" | grep -q '"event":"precondition-failed"'; then
  echo 'PASS  dod: precondition logged as its own event, not a check failure'
else echo 'FAIL  dod: precondition event mislabelled'; failed=$((failed+1)); fi
set_config "$pre" '{"dod":{"fileGlobs":["*.ts"],"preconditions":[{"name":"absent tool","command":"definitely-not-a-real-binary-xyz"}],"checks":[{"name":"t","command":"true"}]}}'
run_hook dod-gate.sh '{"stop_hook_active":false}' "$pre"
assert 'dod: missing binary is unavailable' 2 'absent tool'
set_config "$pre" '{"dod":{"fileGlobs":["*.ts"],"preconditions":[{"name":"ok","command":"true"}],"checks":[{"name":"t","command":"true"}]}}'
run_hook dod-gate.sh '{"stop_hook_active":false}' "$pre"
assert 'dod: satisfied precondition passes through' 0
set_config "$pre" '{"mode":"shadow","dod":{"fileGlobs":["*.ts"],"preconditions":[{"name":"docker","command":"exit 1"}],"checks":[{"name":"t","command":"true"}]}}'
run_hook dod-gate.sh '{"stop_hook_active":false}' "$pre"
assert 'dod: shadow reports precondition' 0 'SHADOW'

# jq missing must block, not silently pass: without it every config read fails
# soft and "tool absent" becomes indistinguishable from "nothing configured".
set_config "$pre" '{"dod":{"fileGlobs":["*.ts"],"checks":[{"name":"t","command":"true"}]}}'
# Uses the shared masking helper below, which proves the masked PATH works before
# any verdict rests on it. The hand-rolled version this replaces went green on a
# failed `source` instead of on the guard it claims to exercise.
run_nojq '{"stop_hook_active":false}' "$pre"
assert_nojq 'dod: jq missing blocks and says it is not a pass' 2 'not a pass'

# Jurisdiction before dependencies. Field report: on a session with no changed
# files, in a directory that was not a repo and had no config, this gate returned
# exit 2 seventeen turns running because the jq guard sat above every
# applicability check — and the stop-loop guard, read through jq, was unreachable
# in exactly the one failure mode that fired every turn.

# 1. not a repo at all -> the gate has no claim, and says nothing
notrepo=$(mktemp -d)
run_nojq '{"stop_hook_active":false}' "$notrepo"
if [ -n "$NOJQ_SKIP" ]; then echo "SKIP  dod: no jq + not a repo ($NOJQ_SKIP)"
elif [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then echo 'PASS  dod: no jq + not a repo -> silent pass'
else echo "FAIL  dod: no jq + not a repo (exit $RC): $OUT"; failed=$((failed+1)); fi

# 2. repo and config, but nothing changed -> nothing a fileGlob could match
clean=$(new_repo feature/clean)
set_config "$clean" '{"dod":{"fileGlobs":["*.ts"],"checks":[{"name":"t","command":"true"}]}}'
git -C "$clean" add -A && git -C "$clean" -c user.email=t@t.t -c user.name=t commit -q -m cfg
run_nojq '{"stop_hook_active":false}' "$clean"
assert_nojq 'dod: no jq + clean tree -> pass' 0

# 3. same setup, one uncommitted change under the glob -> the exit 2 is honest
echo 'const y=2' > "$clean/y.ts"
run_nojq '{"stop_hook_active":false}' "$clean"
assert_nojq 'dod: no jq + dirty tree -> blocks' 2 'not a pass'

# 4. regression on the dead loop guard: it must hold without a parser
run_nojq '{"stop_hook_active":true}' "$clean"
assert_nojq 'dod: no jq + stop_hook_active -> no stop loop' 0

# A missing dependency must not read as a working asset. Measured with jq absent:
# four of the five gates exited 0 and printed nothing, so a push to a protected
# branch and a literal secret both went through and the setup was
# indistinguishable from one where the rules allowed it.
dep=$(new_repo feature/dep)
set_config "$dep" '{"envelope":{"notes":["never touch the shared release branch"]}}'

run_nojq '{"hook_event_name":"SessionStart","source":"startup","session_id":"s"}' "$dep" session-envelope.sh
assert_nojq 'deps: session start names the inert hooks' 0 'DEPENDENCY MISSING'
if [ -z "$NOJQ_SKIP" ]; then
  for named in block-protected-branch secret-guard format-postcheck kb-first-reminder; do
    if printf '%s' "$OUT" | grep -q "$named"; then echo "PASS  deps: report names $named"
    else echo "FAIL  deps: report omits $named"; failed=$((failed+1)); fi
  done
fi

# PreCompact cannot save without jq; the one thing it must not do is save nothing
# quietly, because the next session reads a zero counter as "no compactions yet".
run_nojq '{"hook_event_name":"PreCompact","session_id":"s"}' "$dep" session-envelope.sh
assert_nojq 'deps: precompact says the envelope was not saved' 0 'NOT saved'
if [ -z "$NOJQ_SKIP" ]; then
  if printf '%s' "$OUT" | grep -q 'operational envelope'; then
    echo 'FAIL  deps: precompact printed the envelope instead of persisting'; failed=$((failed+1))
  else echo 'PASS  deps: precompact does not fall through to the print branch'; fi
  if [ -f "$dep/.claude/session-state.json" ]; then
    echo 'FAIL  deps: state file written without jq'; failed=$((failed+1))
  else echo 'PASS  deps: no state file, and it said so'; fi
fi

# With jq present the same event must still persist — the guard is for its absence.
# Skipped rather than assumed where jq is genuinely missing: the premise would be
# false, and a test that cannot hold its own premise reports nothing useful.
if command -v jq >/dev/null 2>&1; then
  run_hook session-envelope.sh '{"hook_event_name":"PreCompact","session_id":"s"}' "$dep"
  if [ -f "$dep/.claude/session-state.json" ]; then echo 'PASS  deps: with jq, precompact still persists'
  else echo 'FAIL  deps: precompact stopped persisting when jq is present'; failed=$((failed+1)); fi
else
  echo 'SKIP  deps: with jq, precompact still persists (jq not installed here; CI covers it)'
fi

# ---- CRLF from a Windows jq build must not disable a gate ----
# The Windows build of jq emits CRLF and a trailing \r survives every line-wise
# read, so `case b.cs in *.cs<CR>)` never matches. Measured before the fix: the
# whole DoD gate was a silent no-op, and with several protected branches only the
# LAST was enforced ($() strips the final \r and nothing strips the others).
# On Linux jq emits LF, so the defect cannot occur naturally here — it is injected
# with a shim, which makes the platform difference reproducible on every runner.
crlf_shim() { # -> echoes a PATH dir whose `jq` emits CRLF like the Windows build
  local d; d=$(mktemp -d); local real; real=$(command -v jq)
  cat > "$d/jq" <<SHIM
#!/usr/bin/env bash
"$real" "\$@" | tr -d '\r' | sed 's/\$/\r/'
SHIM
  chmod +x "$d/jq"; printf '%s' "$d"
}
if command -v jq >/dev/null 2>&1; then
  shim=$(crlf_shim)
  crlf=$(new_repo feature/crlfjq)
  set_config "$crlf" '{"protectedBranches":["main","master","develop"],"secrets":{"enabled":true,"extraPatterns":["INTERNAL_[A-Z]+_KEY"]},"dod":{"fileGlobs":["*.cs"],"checks":[{"name":"c","command":"echo boom; false"}]}}'
  echo 'class X {}' > "$crlf/a.cs"
  rc_of() { # hook payload -> RC, OUT   (with the CRLF-emitting jq first on PATH)
    OUT=$(printf '%s' "$2" | PATH="$shim:$PATH" CLAUDE_PROJECT_DIR="$crlf" bash "$hooks/$1" 2>&1); RC=$?
  }
  rc_of dod-gate.sh '{"stop_hook_active":false}'
  assert 'crlf: dod-gate still blocks (not a silent no-op)' 2 'boom'
  # first entry in the list: the one $() cannot rescue
  rc_of block-protected-branch.sh '{"tool_input":{"command":"git push origin main"}}'
  assert 'crlf: first protected branch is seen' 0 'pre-push'
  rc_of block-protected-branch.sh '{"tool_input":{"command":"git push origin develop"}}'
  assert 'crlf: last protected branch is seen' 0 'pre-push'
  rc_of block-protected-branch.sh '{"tool_input":{"command":"git push origin feature/crlfjq"}}'
  assert 'crlf: feature push still allowed' 0
  rc_of secret-guard.sh '{"tool_input":{"content":"INTERNAL_BILLING_KEY"}}'
  assert 'crlf: custom secret pattern still matches' 2
  rm -rf "$shim"
else
  echo 'SKIP  crlf: jq not installed, cannot build the CRLF shim'
fi

# ---- REDUCED mode: a gate that cannot read its config still guards defaults ----
# Neither of these is a Stop hook, so blocking on a missing parser would refuse
# every Bash call or every edit for the whole session — worse than what it reports.
# Vanishing silently is worse still: measured, a push to main went straight through.
red=$(new_repo feature/reduced)
set_config "$red" '{"protectedBranches":["release/x"],"secrets":{"extraPatterns":["INTERNAL_[A-Z]+_KEY"]}}'

run_nojq '{"tool_input":{"command":"git push origin main"}}' "$red" block-protected-branch.sh
assert_nojq 'reduced: built-in branch list still warns on main' 0 'REDUCED'
run_nojq '{"tool_input":{"command":"git push origin feature/reduced"}}' "$red" block-protected-branch.sh
assert_nojq 'reduced: feature push still allowed' 0
# the false intercept must not come back through the degraded path
run_nojq '{"tool_input":{"command":"git commit -m fix-push-main"}}' "$red" block-protected-branch.sh
assert_nojq 'reduced: a message mentioning push and main is not a push' 0

# Built to avoid writing a complete credential-shaped literal into this file: the
# gate cannot tell a fixture from the real thing, and blocked an earlier version of
# this very test.
awskey="AKIA""7QK4RZTBMN3PDQ2V"
run_nojq "{\"tool_input\":{\"content\":\"$awskey\"}}" "$red" secret-guard.sh
assert_nojq 'reduced: built-in secret detector still fires' 2 'REDUCED'
run_nojq '{"tool_input":{"content":"password: $ADMINPW"}}' "$red" secret-guard.sh
assert_nojq 'reduced: env-var reference is still not a leak' 0
run_nojq '{"tool_input":{"content":"INTERNAL_BILLING_KEY"}}' "$red" secret-guard.sh
assert_nojq 'reduced: custom pattern is lost, and that is allowed' 0

# An explicit off switch must survive reduced mode: the owner disabled the gate.
set_config "$red" '{"secrets":{"enabled":false}}'
run_nojq "{\"tool_input\":{\"content\":\"$awskey\"}}" "$red" secret-guard.sh
assert_nojq 'reduced: enabled=false is still honoured' 0

# The event log used to resolve to the project directory itself when the path
# could not be read, so every append failed with "Is a directory" on stderr.
set_config "$red" '{"protectedBranches":["main"]}'
run_nojq '{"tool_input":{"command":"git push origin main"}}' "$red" block-protected-branch.sh
if [ -z "$NOJQ_SKIP" ] && printf '%s' "$OUT" | grep -q 'Is a directory'; then
  echo 'FAIL  reduced: event log path degraded into a directory'; failed=$((failed+1))
else echo 'PASS  reduced: event log path has a working default'; fi

# ---- code-graph snapshot freshness ----
gs=$(new_repo feature/graphsnap)
node "$root/bin/discipline.mjs" init --target "$gs" --components hooks >/dev/null
mkdir -p "$gs/graph-out"
first=$(git -C "$gs" rev-parse HEAD)
set_config "$gs" '{"codeGraph":{"toolName":"g","snapshot":{"path":"graph-out/graph.json","commitField":"built_at_commit","staleAfterCommits":2,"refresh":"mytool update ."}}}'
printf '{"built_at_commit":"%s"}' "$first" > "$gs/graph-out/graph.json"
out=$(node "$root/bin/discipline.mjs" check --target "$gs" 2>&1)
if ! printf '%s' "$out" | grep -q 'commits behind'; then echo 'PASS  graph: fresh snapshot is quiet'
else echo "FAIL  graph: fresh snapshot warned: $out"; failed=$((failed+1)); fi
for i in 1 2 3 4; do echo "$i" > "$gs/f$i.txt"; git -C "$gs" add -A; git -C "$gs" -c user.email=t@t.t -c user.name=t commit -q -m "c$i"; done
out=$(node "$root/bin/discipline.mjs" check --target "$gs" 2>&1)
if printf '%s' "$out" | grep -q 'commits behind' && printf '%s' "$out" | grep -q 'mytool update'; then
  echo 'PASS  graph: stale snapshot warns with the refresh command'
else echo "FAIL  graph: stale snapshot not reported: $out"; failed=$((failed+1)); fi
rm -f "$gs/graph-out/graph.json"
out=$(node "$root/bin/discipline.mjs" check --target "$gs" 2>&1)
if printf '%s' "$out" | grep -q 'not built yet'; then echo 'PASS  graph: missing snapshot reported'
else echo "FAIL  graph: missing snapshot not reported: $out"; failed=$((failed+1)); fi
printf '{"built_at_commit":"0000000000000000000000000000000000000000"}' > "$gs/graph-out/graph.json"
out=$(node "$root/bin/discipline.mjs" check --target "$gs" 2>&1)
if printf '%s' "$out" | grep -q 'not in this history'; then echo 'PASS  graph: foreign build commit reported as dated'
else echo "FAIL  graph: foreign commit mishandled: $out"; failed=$((failed+1)); fi

# ---- secret-guard ----
sg=$(new_repo feature/secrets)
set_config "$sg" '{"secrets":{"extraPatterns":["ACME_[A-Z0-9]{12}"]}}'
SG() { run_hook secret-guard.sh "$1" "$sg"; }
SG '{"tool_input":{"content":"-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCA"}}'
assert 'secrets: private key blocked' 2
SG '{"tool_input":{"command":"aws configure set x AKIAZ7Q2LMN4RSTUVWXY"}}'
assert 'secrets: aws key blocked' 2
SG '{"tool_input":{"command":"aws configure set x AKIAIOSFODNN7EXAMPLE"}}'
assert 'secrets: canonical EXAMPLE key ignored' 0
SG '{"tool_input":{"command":"psql postgres://app:s3cretPassw0rd@db:5432/x"}}'
assert 'secrets: url password blocked' 2
SG '{"tool_input":{"content":"password: hunter2hunter2"}}'
assert 'secrets: assignment blocked' 2
SG '{"tool_input":{"content":"key ACME_A1B2C3D4E5F6"}}'
assert 'secrets: project pattern' 2
# placeholders and indirection must NOT fire — false intercepts kill trust in a gate
SG '{"tool_input":{"content":"password: ${DB_PASSWORD}"}}'
assert 'secrets: env var ref ok' 0
SG '{"tool_input":{"content":"password=%DB_PASS%"}}'
assert 'secrets: windows var ok' 0
SG '{"tool_input":{"content":"password: changeme-please"}}'
assert 'secrets: placeholder ok' 0
SG '{"tool_input":{"content":"api_key: xxxxxxxxxxxx"}}'
assert 'secrets: xxx ok' 0
SG '{"tool_input":{"content":"const t = process.env.AUTH_TOKEN"}}'
assert 'secrets: process.env ok' 0
# Ordinary code must not read as a credential. The C# shape below blocked every write
# to a file for a whole session, and the only way past it was rewriting valid code —
# the most expensive kind of false intercept there is. Two independent causes: no word
# boundary on the keyword, so it matched inside a longer identifier, and no guard on
# the value, so a call expression cleared the length check.
SG '{"tool_input":{"content":"public async Task RunAsync(CancellationToken cancellationToken = default(CancellationToken))"}}'
assert 'secrets: C# cancellation default is not a credential' 0
SG '{"tool_input":{"content":"var refreshToken = BuildTokenFromConfiguration(settings)"}}'
assert 'secrets: keyword inside a longer identifier is not a credential' 0
SG '{"tool_input":{"content":"var secret = GetSecret(configuration[\"KeyVaultName\"])"}}'
assert 'secrets: a getter call is not a credential' 0
# ...while the real prose detection survives. Assembled from a variable so this file
# does not itself carry a credential-shaped literal: the gate would block the write,
# and it would be right to.
pw_kw='pass'; pw_val='s3cretValue9'
SG "{\"tool_input\":{\"content\":\"the db ${pw_kw}word is ${pw_val}\"}}"
assert 'secrets: prose credential in tool input still blocks' 2
SG "{\"prompt\":\"the db ${pw_kw}word is ${pw_val}\"}"
assert 'secrets: prose credential in a prompt warns, not blocks' 0 'rotate it'
SG '{"tool_input":{"command":"npm run build"}}'
assert 'secrets: ordinary code ok' 0
# a pasted credential is warned about, never blocked: it is already on disk
SG '{"prompt":"the db password is s3cretPassw0rd, use it"}'
assert 'secrets: pasted -> warn not block' 0 'rotate it'
set_config "$sg" '{"mode":"shadow"}'
SG '{"tool_input":{"content":"password: hunter2hunter2"}}'
assert 'secrets: shadow allows' 0 'SHADOW'
set_config "$sg" '{"secrets":{"enabled":false}}'
SG '{"tool_input":{"content":"password: hunter2hunter2"}}'
assert 'secrets: disabled is inert' 0

# ---- kb-first-reminder ----
kb=$(new_repo feature/test)
set_config "$kb" '{"kb":{"toolName":"test-kb","projectTerms":["billing"]}}'
run_hook kb-first-reminder.sh '{"prompt":"How does the billing flow work?"}' "$kb"
assert 'kb: research question reminds' 0 'knowledge base'
run_hook kb-first-reminder.sh '{"prompt":"rename variable foo to bar"}' "$kb"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then echo 'PASS  kb: non-research stays silent'
else echo "FAIL  kb: non-research stays silent (exit $RC, output: $OUT)"; failed=$((failed + 1)); fi
set_config "$kb" '{"kb":{"toolName":"test-kb","projectTerms":["billing"],"triggerPattern":"\\bkak\\b"}}'
run_hook kb-first-reminder.sh '{"prompt":"kak rabotaet billing?"}' "$kb"
assert 'kb: custom trigger pattern' 0 'knowledge base'

rm -rf "$work"
if [ "$failed" -gt 0 ]; then echo; echo "$failed test(s) FAILED"; exit 1; fi
echo; echo "All tests passed."
