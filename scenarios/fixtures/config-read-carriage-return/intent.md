# Stated intent for this diff

## Task

On Git Bash the definition-of-done gate had silently become a no-op, and with
several protected branches configured only the last one was enforced. Cause
found by hand: the Windows build of jq emits CRLF, and a trailing `\r` survives
every line-wise read, so `.dod.fileGlobs[]?` came back as `*.cs\r` and
`case b.cs in *.cs<CR>)` never matched.

Fix the line-wise config reads across the bash hooks and add tests that
reproduce the platform difference on any runner.

## Constraints given

- No new dependencies; `jq` plus shell builtins.
- A hook that cannot read its config must not become a silent no-op. Failing
  loudly is acceptable, failing invisibly is not.
- The tests have to go red without the fix on the CI runner that executes them,
  not only on the maintainer's machine.
- The PowerShell twin is tracked separately in this change; the bash side is what
  this diff covers.

## Out of scope for this change

The PowerShell twin's own reads, and any change to what the gates decide — this
is about reading configuration correctly, not about the policy.
