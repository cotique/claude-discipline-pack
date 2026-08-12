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

base_cfg='{"protectedBranches":["main","master","develop","release/*"]}'

# ---- block-protected-branch ----
feat=$(new_repo feature/test); set_config "$feat" "$base_cfg"
bp() { run_hook block-protected-branch.sh "{\"tool_input\":{\"command\":\"$1\"}}" "$feat"; }
bp 'git push origin main';                              assert 'block: push to main' 2
bp 'git push origin feature/test';                      assert 'block: push feature ok' 0
bp 'git push --force origin HEAD:refs/heads/develop';   assert 'block: force refspec develop' 2
bp 'git push origin :develop';                          assert 'block: delete develop' 2
bp 'git branch -D master';                              assert 'block: branch -D master' 2
bp 'npm test';                                          assert 'block: non-git ignored' 0

on_main=$(new_repo main); set_config "$on_main" "$base_cfg"
run_hook block-protected-branch.sh '{"tool_input":{"command":"git commit -m x"}}' "$on_main"
assert 'block: commit on main' 2

set_config "$feat" '{"protectedBranches":["main"],"blockAllPush":true}'
bp 'git push origin feature/test'; assert 'block: blockAllPush stops feature push' 2
bp 'git commit -m x';             assert 'block: blockAllPush allows commit' 0
set_config "$feat" "$base_cfg"

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
assert 'shadow: push to main allowed but logged' 0 'SHADOW'
log="$sh/.claude/discipline-events.jsonl"
if [ -f "$log" ] && head -1 "$log" | grep -q '"event":"would-block"' && head -1 "$log" | grep -q '"mode":"shadow"'; then
  echo 'PASS  shadow: event line has would-block/shadow'
else echo 'FAIL  shadow: event log missing or wrong'; failed=$((failed+1)); fi

set_config "$sh" '{"mode":"enforce","protectedBranches":["main"],"events":{"enabled":true}}'
run_hook block-protected-branch.sh '{"tool_input":{"command":"git push origin main"}}' "$sh"
assert 'enforce: push to main blocked' 2 'BLOCKED'
if tail -1 "$log" | grep -q '"event":"block"'; then echo 'PASS  enforce: block event appended'
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
# A PATH with nothing on it hides bash too, so build one that has what the hook
# needs and deliberately lacks jq.
jqless=$(mktemp -d)
for t in cat date sed grep basename tr wc git mkdir rm; do
  p=$(command -v "$t") && ln -sf "$p" "$jqless/$t"
done
bash_bin=$(command -v bash)
OUT=$(printf '%s' '{"stop_hook_active":false}' | PATH="$jqless" CLAUDE_PROJECT_DIR="$pre" "$bash_bin" "$hooks/dod-gate.sh" 2>&1); RC=$?
rm -rf "$jqless"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'not a pass'; then
  echo 'PASS  dod: jq missing blocks and says it is not a pass'
else echo "FAIL  dod: jq missing did not block (exit $RC): $OUT"; failed=$((failed+1)); fi

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
