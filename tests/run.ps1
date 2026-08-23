# Test suite for the PowerShell hooks. Replays simulated Claude Code payloads
# against each hook and asserts exit codes (and output, where it matters).
# Run: pwsh -NoProfile -File tests/run.ps1
$ErrorActionPreference = 'Continue'

$root  = Split-Path $PSScriptRoot -Parent
$hooks = Join-Path $root 'hooks\powershell'
$work  = Join-Path ([IO.Path]::GetTempPath()) ("discipline-tests-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null
$script:failed = 0

function New-TestRepo([string]$branch) {
    $dir = Join-Path $work ([IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    git init -q -b $branch $dir
    git -C $dir -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m init
    return $dir
}

function Set-Config([string]$proj, [string]$json) {
    $dir = Join-Path $proj '.claude'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -Path (Join-Path $dir 'discipline.json') -Value $json -NoNewline
}

function Invoke-Hook([string]$hook, [string]$payload, [string]$proj) {
    $env:CLAUDE_PROJECT_DIR = $proj
    $out = $payload | pwsh -NoProfile -File (Join-Path $hooks $hook) 2>&1
    return @{ rc = $LASTEXITCODE; out = ($out -join "`n") }
}

function Assert([string]$name, $result, [int]$expectRc, [string]$expectOut = $null) {
    $ok = ($result.rc -eq $expectRc)
    if ($ok -and $null -ne $expectOut -and $result.out -notmatch [regex]::Escape($expectOut)) { $ok = $false }
    if ($ok) {
        Write-Host "PASS  $name"
    } else {
        Write-Host "FAIL  $name (exit $($result.rc), expected $expectRc; output: $($result.out))"
        $script:failed++
    }
}

$baseCfg = '{"protectedBranches":["main","master","develop","release/*"]}'

# ---- block-protected-branch ----
$feat = New-TestRepo 'feature/test'
Set-Config $feat $baseCfg
function BP([string]$cmd) { Invoke-Hook 'block-protected-branch.ps1' ('{"tool_input":{"command":"' + $cmd + '"}}') $feat }
Assert 'warn: push to main advises, pre-push refuses' (BP 'git push origin main') 0 'pre-push'
Assert 'block: push feature ok'         (BP 'git push origin feature/test') 0
Assert 'warn: force refspec develop'    (BP 'git push --force origin HEAD:refs/heads/develop') 0 'pre-push'
Assert 'warn: delete develop'           (BP 'git push origin :develop') 0 'pre-push'
# Still exit 2, deliberately: neither of these reaches a remote, so git never
# offers a hook with authoritative data. Everything push-shaped is a warning here
# and a refusal in .githooks/pre-push. The pre-push hook itself is exercised with
# real pushes in tests/run.sh — git runs it through sh, so there is one
# implementation and one test location, not a per-platform pair.
Assert 'block: branch -D master'        (BP 'git branch -D master') 2
Assert 'block: non-git ignored'         (BP 'npm test') 0

$onMain = New-TestRepo 'main'
Set-Config $onMain $baseCfg
Assert 'block: commit on main' (Invoke-Hook 'block-protected-branch.ps1' '{"tool_input":{"command":"git commit -m x"}}' $onMain) 2

# A commit message is not a command. Measured in the field: the only intercept in
# a whole corpus was this false positive, and a gate that fires on legitimate work
# is how gates get switched off.
Assert 'block: "push" inside a commit message is not a push' (BP 'git commit -m \"push main fix\"') 0
Assert 'block: "main" inside a message is not a target'      (BP 'git commit -m \"block push to main\"') 0
Assert 'block: "branch -D main" inside a message'            (BP 'git commit -m \"branch -D main is bad\"') 0
Assert 'warn: git -C elsewhere push still seen'              (BP 'git -C /other push origin master') 0 'pre-push'
Assert 'warn: -c option before subcommand still parsed'      (BP 'git -c user.name=x push origin main') 0 'pre-push'

Set-Config $feat '{"protectedBranches":["main"],"blockAllPush":true}'
Assert 'warn: blockAllPush warns on a feature push' (BP 'git push origin feature/test') 0 'pre-push'
# Chaining. Deciding from the first git invocation in the string failed both ways,
# and both were observed on a live setup: the bypass pushed to a protected branch
# for real, and the false intercept blocked a legitimate push because a later
# segment merely mentioned a protected name.
Assert 'chain: push after another git command is still seen' (BP 'git remote set-url origin git@github.com:o/r.git && git push origin main') 0 'pre-push'
Assert 'chain: push in a later segment is seen'   (BP 'git status && git push origin main') 0 'pre-push'
Assert 'chain: semicolon separator is seen'       (BP 'echo hi; git push origin main') 0 'pre-push'
Assert 'chain: wrapper before git still parsed'   (BP 'timeout 90 git push origin main') 0 'pre-push'
Assert 'chain: --base main in another segment is not a push' (BP 'git push origin feature/test && gh pr create --base main') 0
Assert 'chain: a path under a wildcard in another segment is not a push' (BP 'git push origin feature/test && ls release/notes') 0
Assert 'chain: feature push with a trailing command is allowed' (BP 'git push origin feature/test; echo done') 0

Assert 'block: blockAllPush allows commit'      (BP 'git commit -m x') 0
Set-Config $feat $baseCfg

# ---- dod-gate ----
$dod = New-TestRepo 'feature/test'
Set-Content -Path (Join-Path $dod 'dirty.ts') -Value 'const x = 1'
Set-Config $dod '{"dod":{"fileGlobs":["*.ts"],"checks":[{"name":"pass","command":"cmd /c exit 0"}]}}'
Assert 'dod: green check allows stop'   (Invoke-Hook 'dod-gate.ps1' '{"stop_hook_active":false}' $dod) 0
Set-Config $dod '{"dod":{"fileGlobs":["*.ts"],"checks":[{"name":"fail","command":"cmd /c \"echo boom && exit 1\""}]}}'
Assert 'dod: red check blocks stop'     (Invoke-Hook 'dod-gate.ps1' '{"stop_hook_active":false}' $dod) 2 'boom'
Assert 'dod: stop_hook_active guard'    (Invoke-Hook 'dod-gate.ps1' '{"stop_hook_active":true}'  $dod) 0
Set-Config $dod '{"dod":{"fileGlobs":["*.cs"],"checks":[{"name":"fail","command":"cmd /c exit 1"}]}}'
Assert 'dod: no matching dirty files'   (Invoke-Hook 'dod-gate.ps1' '{"stop_hook_active":false}' $dod) 0

# ---- format-postcheck ----
$fmt = New-TestRepo 'feature/test'
Set-Config $fmt '{"format":{"*.ts":"cmd /c exit 1"}}'
Assert 'format: violation feeds back'   (Invoke-Hook 'format-postcheck.ps1' '{"tool_input":{"file_path":"C:/x/app.module.ts"}}' $fmt) 2
Set-Config $fmt '{"format":{"*.ts":"cmd /c exit 0"}}'
Assert 'format: clean file passes'      (Invoke-Hook 'format-postcheck.ps1' '{"tool_input":{"file_path":"C:/x/app.module.ts"}}' $fmt) 0
Assert 'format: non-matching ignored'   (Invoke-Hook 'format-postcheck.ps1' '{"tool_input":{"file_path":"C:/x/README.md"}}' $fmt) 0

# ---- dep-vuln-guard ----
# Mirror of the bash cases. The fourth is the one that matters: `dotnet list
# package --vulnerable` exits 0 while printing findings, so a hook that trusts
# the exit code alone is a green signal that cannot go red.
$dvg = New-TestRepo 'feature/test'
function DVG([string]$file) { Invoke-Hook 'dep-vuln-guard.ps1' ('{"tool_input":{"file_path":"' + $file + '"}}') $dvg }

Set-Config $dvg '{"depVuln":{"manifests":{"package.json":"cmd /c \"echo found 0 vulnerabilities\""}}}'
Assert 'depvuln: clean audit passes' (DVG 'package.json') 0
Set-Config $dvg '{"depVuln":{"manifests":{"package.json":"cmd /c \"echo 3 high severity vulnerabilities & exit 1\""}}}'
Assert 'depvuln: findings block' (DVG 'package.json') 2 'reported vulnerabilities'
Assert 'depvuln: non-manifest ignored' (DVG 'src/index.ts') 0
Set-Config $dvg '{"depVuln":{"manifests":{"*.csproj":{"command":"cmd /c \"echo Project X has the following vulnerable packages\"","findingsPattern":"has the following vulnerable packages"}}}}'
Assert 'depvuln: findingsPattern beats a lying exit 0' (DVG 'app.csproj') 2 'reported vulnerabilities'
Set-Config $dvg '{"depVuln":{"manifests":{"*.csproj":"cmd /c \"echo Project X has the following vulnerable packages\""}}}'
Assert 'depvuln: without the pattern the same exit 0 passes' (DVG 'app.csproj') 0
Set-Config $dvg '{"depVuln":{"manifests":{"package.json":"cmd /c \"echo npm ERR! code ENOTFOUND & exit 1\""}}}'
Assert 'depvuln: unreachable registry is not a verdict' (DVG 'package.json') 0 'did not run'
Set-Config $dvg '{"depVuln":{"timeoutSeconds":1,"manifests":{"package.json":"Start-Sleep -Seconds 15"}}}'
Assert 'depvuln: a hanging audit is killed, not believed' (DVG 'package.json') 0 'did not finish'
Set-Config $dvg '{"mode":"shadow","depVuln":{"manifests":{"package.json":"cmd /c \"echo vulns & exit 1\""}}}'
Assert 'depvuln: shadow reports and allows' (DVG 'package.json') 0 'SHADOW'
Set-Config $dvg '{"protectedBranches":["main"]}'
$r = DVG 'package.json'
if ($r.rc -eq 0 -and [string]::IsNullOrWhiteSpace($r.out)) { Write-Host 'PASS  depvuln: no config section, no-op and silent' }
else { Write-Host "FAIL  depvuln: no config section, no-op and silent (exit $($r.rc), output: $($r.out))"; $script:failed++ }

# ---- code-graph gate: any declaration form satisfies it ----
$cg = New-TestRepo 'feature/graph'
Set-Content -Path (Join-Path $cg 'big.ts') -Value (1..600 | ForEach-Object { "const x$_ = $_;" })
git -C $cg add -A; git -C $cg -c user.email=t@t.t -c user.name=t commit -q -m add
# check needs an initialised install, otherwise every case exits 1 for the wrong
# reason and the negative case passes by accident.
& node (Join-Path $root 'bin\discipline.mjs') init --target $cg --components hooks | Out-Null
foreach ($form in @('{"codeGraph":{"recommendAtLoc":100,"requireAtLoc":200}}',
                    '{"codeGraph":{"toolName":"g","recommendAtLoc":100,"requireAtLoc":200}}',
                    '{"codeGraph":{"skill":"code-graph","recommendAtLoc":100,"requireAtLoc":200}}',
                    '{"codeGraph":{"command":"npx depgraph","recommendAtLoc":100,"requireAtLoc":200}}')) {
    Set-Config $cg $form
    $out = & node (Join-Path $root 'bin\discipline.mjs') check --target $cg 2>&1
    $rc = $LASTEXITCODE
    $declared = $form -match 'toolName|skill|command'
    $name = if ($declared) { 'graph declared (' + ($form -replace '.*"(toolName|skill|command)".*', '$1') + ') -> gate satisfied' }
            else { 'no graph over threshold -> gate errors' }
    $want = if ($declared) { 0 } else { 1 }
    if ($rc -eq $want) { Write-Host "PASS  codeGraph: $name" }
    else { Write-Host "FAIL  codeGraph: $name (exit $rc, expected $want): $out"; $script:failed++ }
}

# ---- report: same CLI, but the paths are Windows paths ----
# The bash suite covers the counting rules. What is worth re-running here is
# everything path-shaped: the manifest records hook files with backslashes on
# this platform, and the silent-hook list is derived from those keys.
$rp = New-TestRepo 'feature/report'
node (Join-Path $root 'bin\discipline.mjs') init --target $rp --components hooks | Out-Null
node (Join-Path $root 'bin\discipline.mjs') apply --target $rp | Out-Null
Set-Config $rp '{"mode":"shadow","events":{"enabled":true,"path":".claude/discipline-events.jsonl"}}'

$rlog = Join-Path $rp '.claude\discipline-events.jsonl'
$lines = @()
1..3 | ForEach-Object {
    $lines += '{"ts":"2026-08-20T10:0' + $_ + ':00Z","asset":"dod-gate","event":"block","verdict":"fail","mode":"enforce","sessionId":"s-a","durationMs":4' + $_ + '000}'
}
1..12 | ForEach-Object {
    $lines += '{"ts":"2026-08-21T09:' + $_.ToString('00') + ':00Z","asset":"secret-guard","event":"would-block","verdict":"fail","mode":"shadow","sessionId":"s-' + ($_ % 4) + '"}'
}
$lines += '{"ts":"2026-08-23T08:01:00Z","asset":"dod-ga'   # a session killed mid-write
Set-Content -Path $rlog -Value $lines

$out = (node (Join-Path $root 'bin\discipline.mjs') report --target $rp 2>&1) -join "`n"
$rc = $LASTEXITCODE
function Assert-Report([string]$name, [string]$needle) {
    if ($out -match [regex]::Escape($needle)) { Write-Host "PASS  report: $name" }
    else { Write-Host "FAIL  report: $name (not in output: $out)"; $script:failed++ }
}
if ($rc -eq 0) { Write-Host 'PASS  report: exits 0 on a readable log' }
else { Write-Host "FAIL  report: exits 0 on a readable log (exit $rc)"; $script:failed++ }
Assert-Report 'applied but silent hooks are listed, from backslash manifest keys' 'silent in this window'
Assert-Report 'block-protected-branch is among them' 'block-protected-branch'
Assert-Report 'a truncated line is reported, not eaten' 'could not be parsed'
Assert-Report 'cost percentiles survive the path round-trip' 'p50 42000ms'
Assert-Report 'enough would-blocks to sample' 'secret-guard: 12 would-block'
Assert-Report 'says what the log cannot tell you' 'does not record whether firing'

# ---- CRLF must not read as drift ----
# A target repo with core.autocrlf=true rewrites vendored .sh copies to CRLF.
# Byte hashing called that drift forever; content hashing must not.
$crlf = New-TestRepo 'feature/crlf'
& node (Join-Path $root 'bin\discipline.mjs') init --target $crlf --components hooks | Out-Null
& node (Join-Path $root 'bin\discipline.mjs') apply --target $crlf | Out-Null
$victim = Join-Path $crlf '.claude\hooks\dod-gate.sh'
$raw = [IO.File]::ReadAllText($victim)
[IO.File]::WriteAllText($victim, ($raw -replace "`r`n", "`n") -replace "`n", "`r`n")
& node (Join-Path $root 'bin\discipline.mjs') check --target $crlf 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host 'PASS  drift: CRLF rewrite is not drift' }
else { Write-Host 'FAIL  drift: CRLF rewrite reported as drift'; $script:failed++ }
Add-Content -Path $victim -Value '# a real local edit'
& node (Join-Path $root 'bin\discipline.mjs') check --target $crlf 2>&1 | Out-Null
if ($LASTEXITCODE -eq 1) { Write-Host 'PASS  drift: a real edit is still caught' }
else { Write-Host 'FAIL  drift: real edit missed'; $script:failed++ }

# ---- shadow mode + event logging ----
$sh = New-TestRepo 'feature/shadow'
Set-Config $sh '{"mode":"shadow","protectedBranches":["main"],"events":{"enabled":true}}'
$r = Invoke-Hook 'block-protected-branch.ps1' '{"session_id":"s1","tool_input":{"command":"git push origin main"}}' $sh
Assert 'shadow: push to main warns and is logged' $r 0 'pre-push'
$log = Join-Path $sh '.claude\discipline-events.jsonl'
if (Test-Path $log) {
    $ev = Get-Content $log | Select-Object -First 1 | ConvertFrom-Json
    # `warn-push` regardless of mode: shadow suppresses blocking, and this layer has
    # no blocking left to suppress for pushes. The event must still be recorded.
    if ($ev.event -eq 'warn-push' -and $ev.mode -eq 'shadow' -and $ev.sessionId -eq 's1') {
        Write-Host 'PASS  shadow: event line has warn-push/shadow/sessionId'
    } else { Write-Host "FAIL  shadow: unexpected event $($ev | ConvertTo-Json -Compress)"; $script:failed++ }
} else { Write-Host 'FAIL  shadow: no event log written'; $script:failed++ }

Set-Config $sh '{"mode":"enforce","protectedBranches":["main"],"events":{"enabled":true}}'
Assert 'enforce: push to main warns, pre-push refuses' (Invoke-Hook 'block-protected-branch.ps1' '{"tool_input":{"command":"git push origin main"}}' $sh) 0 'pre-push'
$lines = @(Get-Content $log)
if ($lines.Count -ge 2 -and ($lines[-1] | ConvertFrom-Json).event -eq 'warn-push') {
    Write-Host 'PASS  enforce: warn-push event appended'
} else { Write-Host 'FAIL  enforce: warn-push event missing'; $script:failed++ }

Set-Config $sh '{"protectedBranches":["main"],"events":{"enabled":false}}'
$before = @(Get-Content $log).Count
Invoke-Hook 'block-protected-branch.ps1' '{"tool_input":{"command":"git push origin main"}}' $sh | Out-Null
if (@(Get-Content $log).Count -eq $before) { Write-Host 'PASS  events: disabled writes nothing' }
else { Write-Host 'FAIL  events: wrote while disabled'; $script:failed++ }

$dg = New-TestRepo 'feature/shadow-dod'
Set-Content -Path (Join-Path $dg 'x.ts') -Value 'const x=1'
Set-Config $dg '{"mode":"shadow","dod":{"fileGlobs":["*.ts"],"checks":[{"name":"f","command":"cmd /c exit 1"}]}}'
Assert 'shadow: dod-gate allows stop but logs' (Invoke-Hook 'dod-gate.ps1' '{"stop_hook_active":false}' $dg) 0 'SHADOW'

# ---- session-envelope ----
$env1 = New-TestRepo 'feature/envelope'
Set-Config $env1 '{"envelope":{"repos":["."],"notes":["never switch branches in the sibling repo"]}}'
$r = Invoke-Hook 'session-envelope.ps1' '{"source":"startup"}' $env1
Assert 'envelope: reports branch'      $r 0 'branch=feature/envelope'
Assert 'envelope: reports constraints' $r 0 'never switch branches'
$env2 = New-TestRepo 'feature/plain'
Assert 'envelope: no config still runs' (Invoke-Hook 'session-envelope.ps1' '{"source":"resume"}' $env2) 0 'operational envelope'
Set-Config $env2 '{"envelope":{"repos":[".","../nope"]}}'
Assert 'envelope: missing repo noted'  (Invoke-Hook 'session-envelope.ps1' '{"source":"startup"}' $env2) 0 'not a git worktree'

# ---- PreCompact persists state, SessionStart hands it back ----
$pc = New-TestRepo 'feature/compact'
Set-Config $pc '{"envelope":{"repos":["."],"notes":["deliverable is a patch"]}}'
1..3 | ForEach-Object {
    Invoke-Hook 'session-envelope.ps1' '{"hook_event_name":"PreCompact","session_id":"pet-1"}' $pc | Out-Null
}
$stateFile = Join-Path $pc '.claude\session-state.json'
if (Test-Path $stateFile) {
    $st = Get-Content $stateFile -Raw | ConvertFrom-Json
    if ($st.compactions -eq 3 -and $st.sessionId -eq 'pet-1' -and $st.envelope) {
        Write-Host 'PASS  compact: state persisted with count and envelope'
    } else { Write-Host "FAIL  compact: bad state $($st | ConvertTo-Json -Compress)"; $script:failed++ }
} else { Write-Host 'FAIL  compact: no state file written'; $script:failed++ }
$r = Invoke-Hook 'session-envelope.ps1' '{"hook_event_name":"SessionStart","source":"compact","session_id":"pet-1"}' $pc
Assert 'compact: count handed back'   $r 0 'compactions so far in this session: 3'
Assert 'compact: nudge past threshold' $r 0 'clean boundary'
$r2 = Invoke-Hook 'session-envelope.ps1' '{"hook_event_name":"SessionStart","source":"startup","session_id":"other"}' $pc
if ($r2.out -notmatch 'compactions so far') { Write-Host 'PASS  compact: count resets for a new session' }
else { Write-Host 'FAIL  compact: count leaked across sessions'; $script:failed++ }

# ---- dod preconditions: a missing environment is not a verdict ----
$pre = New-TestRepo 'feature/pre'
Set-Content -Path (Join-Path $pre 'x.ts') -Value 'const x=1'
$preCfg = '{"dod":{"fileGlobs":["*.ts"],"preconditions":[{"name":"docker daemon","command":"cmd /c exit 1","remedy":"Start Docker Desktop, then retry."}],"checks":[{"name":"t","command":"cmd /c exit 0"}]},"events":{"enabled":true}}'
Set-Config $pre $preCfg
$r = Invoke-Hook 'dod-gate.ps1' '{"stop_hook_active":false}' $pre
Assert 'dod: failed precondition blocks'        $r 2 'Cannot run the checks'
Assert 'dod: says it is not a verdict'          $r 2 'not a verdict on your changes'
Assert 'dod: prints the remedy'                 $r 2 'Start Docker Desktop'
$log = Join-Path $pre '.claude\discipline-events.jsonl'
if ((Get-Content $log | Select-Object -Last 1 | ConvertFrom-Json).event -eq 'precondition-failed') {
    Write-Host 'PASS  dod: precondition logged as its own event, not a check failure'
} else { Write-Host 'FAIL  dod: precondition event mislabelled'; $script:failed++ }
# a command that does not exist must count as unavailable, not as present
Set-Config $pre '{"dod":{"fileGlobs":["*.ts"],"preconditions":[{"name":"absent tool","command":"definitely-not-a-real-binary-xyz"}],"checks":[{"name":"t","command":"cmd /c exit 0"}]}}'
Assert 'dod: missing binary is unavailable'     (Invoke-Hook 'dod-gate.ps1' '{"stop_hook_active":false}' $pre) 2 'absent tool'
# preconditions satisfied -> normal check flow
Set-Config $pre '{"dod":{"fileGlobs":["*.ts"],"preconditions":[{"name":"ok","command":"cmd /c exit 0"}],"checks":[{"name":"t","command":"cmd /c exit 0"}]}}'
Assert 'dod: satisfied precondition passes through' (Invoke-Hook 'dod-gate.ps1' '{"stop_hook_active":false}' $pre) 0
# shadow records the precondition instead of blocking
Set-Config $pre '{"mode":"shadow","dod":{"fileGlobs":["*.ts"],"preconditions":[{"name":"docker","command":"cmd /c exit 1"}],"checks":[{"name":"t","command":"cmd /c exit 0"}]}}'
Assert 'dod: shadow reports precondition'       (Invoke-Hook 'dod-gate.ps1' '{"stop_hook_active":false}' $pre) 0 'SHADOW'

# ---- code-graph snapshot freshness ----
$gs = New-TestRepo 'feature/graphsnap'
& node (Join-Path $root 'bin\discipline.mjs') init --target $gs --components hooks | Out-Null
New-Item -ItemType Directory -Path (Join-Path $gs 'graph-out') -Force | Out-Null
$first = (git -C $gs rev-parse HEAD).Trim()
$snapCfg = '{"codeGraph":{"toolName":"g","snapshot":{"path":"graph-out/graph.json","commitField":"built_at_commit","staleAfterCommits":2,"refresh":"mytool update ."}}}'
Set-Config $gs $snapCfg
# graph built at HEAD -> quiet
Set-Content -Path (Join-Path $gs 'graph-out\graph.json') -Value ('{"built_at_commit":"' + $first + '"}')
$out = & node (Join-Path $root 'bin\discipline.mjs') check --target $gs 2>&1
if ($out -notmatch 'commits behind') { Write-Host 'PASS  graph: fresh snapshot is quiet' }
else { Write-Host "FAIL  graph: fresh snapshot warned: $out"; $script:failed++ }
# move HEAD past the threshold -> warn, and name the refresh command
1..4 | ForEach-Object {
    Set-Content -Path (Join-Path $gs "f$_.txt") -Value $_
    git -C $gs add -A; git -C $gs -c user.email=t@t.t -c user.name=t commit -q -m "c$_"
}
$out = & node (Join-Path $root 'bin\discipline.mjs') check --target $gs 2>&1
if ($out -match 'commits behind' -and $out -match 'mytool update') { Write-Host 'PASS  graph: stale snapshot warns with the refresh command' }
else { Write-Host "FAIL  graph: stale snapshot not reported: $out"; $script:failed++ }
# missing graph file -> says so instead of failing
Remove-Item (Join-Path $gs 'graph-out\graph.json')
$out = & node (Join-Path $root 'bin\discipline.mjs') check --target $gs 2>&1
if ($out -match 'not built yet') { Write-Host 'PASS  graph: missing snapshot reported' }
else { Write-Host "FAIL  graph: missing snapshot not reported: $out"; $script:failed++ }
# a commit from another history -> dated, not a crash
Set-Content -Path (Join-Path $gs 'graph-out\graph.json') -Value '{"built_at_commit":"0000000000000000000000000000000000000000"}'
$out = & node (Join-Path $root 'bin\discipline.mjs') check --target $gs 2>&1
if ($out -match 'not in this history') { Write-Host 'PASS  graph: foreign build commit reported as dated' }
else { Write-Host "FAIL  graph: foreign commit mishandled: $out"; $script:failed++ }

# ---- secret-guard ----
$sg = New-TestRepo 'feature/secrets'
Set-Config $sg '{"secrets":{"extraPatterns":["ACME_[A-Z0-9]{12}"]}}'
function SG([string]$json) { Invoke-Hook 'secret-guard.ps1' $json $sg }
# real credential material in a tool input -> blocked
Assert 'secrets: private key blocked'  (SG '{"tool_input":{"content":"-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCA"}}') 2
Assert 'secrets: aws key blocked'      (SG '{"tool_input":{"command":"aws configure set x AKIAZ7Q2LMN4RSTUVWXY"}}') 2
Assert 'secrets: canonical EXAMPLE key ignored' (SG '{"tool_input":{"command":"aws configure set x AKIAIOSFODNN7EXAMPLE"}}') 0
Assert 'secrets: url password blocked' (SG '{"tool_input":{"command":"psql postgres://app:s3cretPassw0rd@db:5432/x"}}') 2
Assert 'secrets: assignment blocked'   (SG '{"tool_input":{"content":"password: hunter2hunter2"}}') 2
Assert 'secrets: project pattern'      (SG '{"tool_input":{"content":"key ACME_A1B2C3D4E5F6"}}') 2
# placeholders and indirection must NOT fire — false intercepts kill trust in a gate
Assert 'secrets: env var ref ok'       (SG '{"tool_input":{"content":"password: ${DB_PASSWORD}"}}') 0
Assert 'secrets: windows var ok'       (SG '{"tool_input":{"content":"password=%DB_PASS%"}}') 0
Assert 'secrets: placeholder ok'       (SG '{"tool_input":{"content":"password: changeme-please"}}') 0
Assert 'secrets: xxx ok'               (SG '{"tool_input":{"content":"api_key: xxxxxxxxxxxx"}}') 0
Assert 'secrets: process.env ok'       (SG '{"tool_input":{"content":"const t = process.env.AUTH_TOKEN"}}') 0
# Ordinary code must not read as a credential. The C# shape below blocked every write
# to a file for a whole session, and the only way past it was rewriting valid code.
Assert 'secrets: C# cancellation default is not a credential' (SG '{"tool_input":{"content":"public async Task RunAsync(CancellationToken cancellationToken = default(CancellationToken))"}}') 0
Assert 'secrets: keyword inside a longer identifier is not a credential' (SG '{"tool_input":{"content":"var refreshToken = BuildTokenFromConfiguration(settings)"}}') 0
Assert 'secrets: a getter call is not a credential' (SG '{"tool_input":{"content":"var secret = GetSecret(configuration[\"KeyVaultName\"])"}}') 0
Assert 'secrets: ordinary code ok'     (SG '{"tool_input":{"command":"npm run build"}}') 0
# a pasted credential is warned about, never blocked: it is already on disk
$r = SG '{"prompt":"the db password is s3cretPassw0rd, use it"}'
Assert 'secrets: pasted -> warn not block' $r 0 'rotate it'
# shadow mode records instead of blocking
Set-Config $sg '{"mode":"shadow"}'
Assert 'secrets: shadow allows'        (SG '{"tool_input":{"content":"password: hunter2hunter2"}}') 0 'SHADOW'
Set-Config $sg '{"secrets":{"enabled":false}}'
Assert 'secrets: disabled is inert'    (SG '{"tool_input":{"content":"password: hunter2hunter2"}}') 0

# ---- kb-first-reminder ----
$kb = New-TestRepo 'feature/test'
Set-Config $kb '{"kb":{"toolName":"test-kb","projectTerms":["billing"]}}'
Assert 'kb: research question reminds'  (Invoke-Hook 'kb-first-reminder.ps1' '{"prompt":"How does the billing flow work?"}' $kb) 0 'knowledge base'
$r = Invoke-Hook 'kb-first-reminder.ps1' '{"prompt":"rename variable foo to bar"}' $kb
if ($r.rc -eq 0 -and -not $r.out) { Write-Host 'PASS  kb: non-research stays silent' }
else { Write-Host "FAIL  kb: non-research stays silent (exit $($r.rc), output: $($r.out))"; $script:failed++ }
Set-Config $kb '{"kb":{"toolName":"test-kb","projectTerms":["billing"],"triggerPattern":"\\bkak\\b"}}'
Assert 'kb: custom trigger pattern'     (Invoke-Hook 'kb-first-reminder.ps1' '{"prompt":"kak rabotaet billing?"}' $kb) 0 'knowledge base'

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
if ($script:failed -gt 0) { Write-Host "`n$($script:failed) test(s) FAILED"; exit 1 }
Write-Host "`nAll tests passed."
exit 0
