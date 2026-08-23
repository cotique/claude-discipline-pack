#!/usr/bin/env bash
# PostToolUse hook (matcher: Edit|Write) — when a dependency manifest changes,
# ask the ecosystem's own audit tool whether the tree it now describes has known
# vulnerabilities, and feed findings back to Claude (exit 2).
#
# Why PostToolUse and not a pre-write gate: a vulnerability is a property of the
# resolved tree, which does not exist until the manifest is written (and, for some
# ecosystems, installed). Before the write there is nothing to scan. Same
# reasoning as format-postcheck — the edit already happened, exit 2 is feedback.
#
# Why it shells out instead of matching CVEs itself: a bundled advisory database
# is stale the day it ships and wrong in a way nobody can see. `npm audit`,
# `dotnet list package --vulnerable` and `pip-audit` are maintained by the people
# who own the registry. Same reasoning as secret-guard not trying to be a secrets
# manager: gate around the real tool, do not reimplement it.
#
# stdin:  hook payload JSON ({ tool_input: { file_path: "..." } })
# config: .claude/discipline.json →
#   "depVuln": {
#     "manifests": {
#       "package.json": "npm audit --audit-level=high",
#       "*.csproj": { "command": "dotnet list package --vulnerable --include-transitive",
#                     "findingsPattern": "has the following vulnerable packages" }
#     },
#     "unavailablePattern": "ENOTFOUND|ETIMEDOUT|...",   # optional, overrides the default
#     "timeoutSeconds": 120                              # optional, needs `timeout` on PATH
#   }
# No defaults, and that is deliberate: every one of these commands does network
# I/O. A hook that fires an unrequested registry call on the first manifest edit
# of a session is a cost nobody agreed to, so a missing section no-ops like
# `format` rather than opting in like `secrets`.
# deps: jq

set -u
. "$(dirname "$0")/_events.sh"
payload=$(cat)
DISC_SESSION_ID=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r')
export DISC_SESSION_ID
file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null | tr -d '\r')
[ -z "$file" ] && exit 0

proj="${CLAUDE_PROJECT_DIR:-.}"
config="$proj/.claude/discipline.json"
[ -f "$config" ] || exit 0
disc_have_jq || exit 0   # no parser, no manifest map — nothing to run, and
                         # guessing the ecosystem from a filename is not a check

# The registry being unreachable is not a verdict on your dependencies. Reported
# as a finding it sends the reader hunting for a CVE that was never named, and
# gates that do that get switched off — the same distinction dod-gate draws
# between a stopped Docker daemon and a failing test.
unavail=$(jq -r '.depVuln.unavailablePattern // empty' "$config" 2>/dev/null | tr -d '\r')
[ -z "$unavail" ] && unavail='ENOTFOUND|ETIMEDOUT|ECONNREFUSED|EAI_AGAIN|ERR_SOCKET|network|offline|Unable to load the service index|Temporary failure in name resolution|could not resolve host|Connection refused|proxy'

tmo=$(jq -r '.depVuln.timeoutSeconds // empty' "$config" 2>/dev/null | tr -d '\r')
case "$tmo" in ''|*[!0-9]*) tmo=120 ;; esac

base=$(basename "$file")
start_ms=$(( $(date +%s) * 1000 ))

while IFS=$'\t' read -r glob cmd findings; do
  [ -z "$cmd" ] && continue
  # shellcheck disable=SC2254
  case "$base" in
    $glob) ;;
    *) continue ;;
  esac

  # `timeout` is not everywhere (notably not on stock macOS), and a hook that
  # hangs on a slow registry is worse than one with no clock. Run without it and
  # say so in the event, rather than pretending a bound was applied.
  if command -v timeout >/dev/null 2>&1; then
    out=$(cd "$proj" && timeout "$tmo" sh -c "$cmd" 2>&1); rc=$?
    bounded="timeout=${tmo}s"
  else
    out=$(cd "$proj" && sh -c "$cmd" 2>&1); rc=$?
    bounded='no-timeout'
  fi
  ms=$(( $(date +%s) * 1000 - start_ms ))

  # 124 is what `timeout` returns when it had to kill the command.
  if [ "$rc" -eq 124 ]; then
    disc_log dep-vuln-guard unavailable unverified "$glob: timed out after ${tmo}s" "$ms"
    {
      echo "[dep-vuln-guard] '$glob' audit timed out after ${tmo}s for $file."
      echo "This is not a verdict on your dependencies — the audit did not finish."
      echo "Run it yourself, or raise depVuln.timeoutSeconds."
    } >&2
    exit 0
  fi

  if printf '%s' "$out" | grep -Eqi -e "$unavail"; then
    disc_log dep-vuln-guard unavailable unverified "$glob: audit tool unavailable ($bounded)" "$ms"
    {
      echo "[dep-vuln-guard] '$glob' audit could not run for $file:"
      printf '%s\n' "$out" | tail -n 5
      echo "This is not a verdict on your dependencies — the audit did not run."
    } >&2
    exit 0
  fi

  # Some audit tools report findings on stdout and still exit 0 — `dotnet list
  # package --vulnerable` is the one that started this. Where findingsPattern is
  # configured it decides and the exit code is ignored, because trusting the exit
  # code there is a green signal that cannot go red.
  if [ -n "$findings" ]; then
    printf '%s' "$out" | grep -Eqi -e "$findings" && hit=1 || hit=0
    verdict_src="pattern"
  else
    [ "$rc" -ne 0 ] && hit=1 || hit=0
    verdict_src="exit=$rc"
  fi
  [ "$hit" -eq 0 ] && continue

  if [ "$(disc_mode)" = "shadow" ]; then
    disc_log dep-vuln-guard would-block fail "$glob: vulnerable dependencies ($verdict_src, $bounded)" "$ms"
    echo "[dep-vuln-guard] SHADOW (not enforced): '$glob' audit reported vulnerabilities for $file" >&2
    exit 0
  fi
  disc_log dep-vuln-guard block fail "$glob: vulnerable dependencies ($verdict_src, $bounded)" "$ms"
  {
    echo "[dep-vuln-guard] '$glob' audit reported vulnerabilities after your change to $file:"
    printf '%s\n' "$out" | tail -n 30
    echo "Pin or upgrade the affected package, or say why the advisory does not apply here."
  } >&2
  exit 2
done < <(disc_jq_lines '.depVuln.manifests // {} | to_entries[] | [.key, (if (.value|type) == "string" then .value else (.value.command // "") end), (if (.value|type) == "object" then (.value.findingsPattern // "") else "" end)] | @tsv' "$config")

exit 0
