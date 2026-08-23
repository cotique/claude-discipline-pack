# PostToolUse hook (matcher: Edit|Write) — when a dependency manifest changes, ask
# the ecosystem's own audit tool whether the tree it now describes has known
# vulnerabilities, and feed findings back to Claude (exit 2). PowerShell twin of
# hooks/bash/dep-vuln-guard.sh; the reasoning behind every branch is documented
# there.

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_events.ps1"

try { $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }
if ($payload.session_id) { $env:DISC_SESSION_ID = $payload.session_id }
$file = $payload.tool_input.file_path
if (-not $file) { exit 0 }

$proj = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { '.' }
$configPath = Join-Path $proj '.claude\discipline.json'
if (-not (Test-Path $configPath)) { exit 0 }
try { $cfg = Get-Content $configPath -Raw | ConvertFrom-Json } catch { exit 0 }
if (-not $cfg.depVuln -or -not $cfg.depVuln.manifests) { exit 0 }

# The registry being unreachable is not a verdict on your dependencies.
$unavail = if ($cfg.depVuln.unavailablePattern) { $cfg.depVuln.unavailablePattern }
           else { 'ENOTFOUND|ETIMEDOUT|ECONNREFUSED|EAI_AGAIN|ERR_SOCKET|network|offline|Unable to load the service index|Temporary failure in name resolution|could not resolve host|Connection refused|proxy' }

$tmo = 120
if ($cfg.depVuln.timeoutSeconds -as [int]) { $tmo = [int]$cfg.depVuln.timeoutSeconds }

$base = Split-Path $file -Leaf
foreach ($entry in $cfg.depVuln.manifests.PSObject.Properties) {
    if ($base -notlike $entry.Name) { continue }

    $command = if ($entry.Value -is [string]) { $entry.Value } else { $entry.Value.command }
    if (-not $command) { continue }
    $findings = if ($entry.Value -is [string]) { '' } else { [string]$entry.Value.findingsPattern }

    # PowerShell has no `timeout(1)`: run the audit as a job so a slow registry
    # cannot hang the session, and report the kill rather than a verdict.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $job = Start-Job -ScriptBlock {
        param($dir, $cmd)
        Set-Location $dir
        $out = Invoke-Expression $cmd 2>&1 | Out-String
        [pscustomobject]@{ Output = $out; Code = $LASTEXITCODE }
    } -ArgumentList $proj, $command

    $timedOut = -not (Wait-Job $job -Timeout $tmo)
    if ($timedOut) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Write-DiscEvent -Asset 'dep-vuln-guard' -Event 'unavailable' -Verdict 'unverified' `
            -Detail "$($entry.Name): timed out after ${tmo}s" -DurationMs $sw.ElapsedMilliseconds
        [Console]::Error.WriteLine("[dep-vuln-guard] '$($entry.Name)' audit timed out after ${tmo}s for ${file}.")
        [Console]::Error.WriteLine('This is not a verdict on your dependencies — the audit did not finish.')
        [Console]::Error.WriteLine('Run it yourself, or raise depVuln.timeoutSeconds.')
        exit 0
    }

    $result = Receive-Job $job
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    $out = if ($result) { [string]$result.Output } else { '' }
    $code = if ($result -and $null -ne $result.Code) { [int]$result.Code } else { 0 }
    $ms = $sw.ElapsedMilliseconds

    if ($out -match $unavail) {
        Write-DiscEvent -Asset 'dep-vuln-guard' -Event 'unavailable' -Verdict 'unverified' `
            -Detail "$($entry.Name): audit tool unavailable" -DurationMs $ms
        [Console]::Error.WriteLine("[dep-vuln-guard] '$($entry.Name)' audit could not run for ${file}:")
        ($out -split "`n" | Select-Object -Last 5) | ForEach-Object { [Console]::Error.WriteLine($_.TrimEnd()) }
        [Console]::Error.WriteLine('This is not a verdict on your dependencies — the audit did not run.')
        exit 0
    }

    # Some audit tools report findings on stdout and still exit 0. Where
    # findingsPattern is configured it decides and the exit code is ignored.
    if ($findings) {
        $hit = ($out -match $findings)
        $verdictSrc = 'pattern'
    } else {
        $hit = ($code -ne 0)
        $verdictSrc = "exit=$code"
    }
    if (-not $hit) { continue }

    if ((Get-DiscMode) -eq 'shadow') {
        Write-DiscEvent -Asset 'dep-vuln-guard' -Event 'would-block' -Verdict 'fail' `
            -Detail "$($entry.Name): vulnerable dependencies ($verdictSrc)" -DurationMs $ms
        [Console]::Error.WriteLine("[dep-vuln-guard] SHADOW (not enforced): '$($entry.Name)' audit reported vulnerabilities for ${file}")
        exit 0
    }
    Write-DiscEvent -Asset 'dep-vuln-guard' -Event 'block' -Verdict 'fail' `
        -Detail "$($entry.Name): vulnerable dependencies ($verdictSrc)" -DurationMs $ms
    [Console]::Error.WriteLine("[dep-vuln-guard] '$($entry.Name)' audit reported vulnerabilities after your change to ${file}:")
    ($out -split "`n" | Select-Object -Last 30) | ForEach-Object { [Console]::Error.WriteLine($_.TrimEnd()) }
    [Console]::Error.WriteLine('Pin or upgrade the affected package, or say why the advisory does not apply here.')
    exit 2
}
exit 0
