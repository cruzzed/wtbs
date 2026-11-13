# ADR-0009: Destructive-op guards and the danger scan

## Status
Accepted (v0.6)

## Context

wtbs executes project-owned code by design — hooks, strap lifecycle
scripts, strap verbs, presets, aliases — and deletes things by design:
worktrees, databases, branches, state files. All of it is bash, where a
single unquoted or empty variable next to `rm -rf` is a catastrophe, and
where the most dangerous scripts are the ones the project author wrote
themselves and wtbs runs on their behalf.

The failure mode is not malice; it is the mistype and the careless
pattern — the hook with `rm -rf "$DIR/"$name`, the strap that reaches for
`sudo` (which on this machine's valet setup has a history of taking all
sites down mid-run), the `git push --force` buried in a preset.

## Decision

Two layers, both mechanism, both in the core:

1. **Guards** (`lib/utils.sh`): every core deletion goes through
   `wtbs_remove_file` / `wtbs_remove_tree` / `wtbs_remove_branch`. They
   fail closed — empty, `/`, and `$HOME` are never deletion targets;
   recursive removal requires a git-registered worktree; branch deletion
   refuses protected names. Exactly one `rm -rf` exists in the tool,
   inside `wtbs_remove_tree`.

2. **Danger scan** (`danger_scan`, same file): before the core executes
   any hook, strap lifecycle script, verb, preset, or alias, the script
   is scanned for a fixed pattern list (recursive delete, `sudo`,
   force-push, disk destroyers). A hit is a refusal that names the
   file, line, and pattern, with two escape hatches: a per-line
   `# wtbs:danger-ok <reason>` directive (preferred — justification lives
   in the code) and a global `WTBS_ALLOW_DANGEROUS=1` (warns loudly).

3. **Mechanical enforcement**: `tests/bats/lint.bats` pins the invariants
   (no bare `rm`/`branch -D` outside the guards, no `eval` outside the
   hook executor, `set -euo pipefail` everywhere), so the discipline
   cannot erode silently.

4. **Sandboxed execution for the suite** (`tests/landrun.sh`): tests and
   experiments run under Landlock — repo read-only, one scratch dir
   writable, no network — so the project rule "never target the real
   checkout, home directory, or user services" is enforced by the kernel,
   not by good intentions.

## Doctrine instantiated

- **Mechanism, not policy** (#1): the guards are execution mechanism in
  the core; what counts as "dangerous" is the one place policy lives, in
  a single declared list, and straps are given the blessed path
  (`wtbs_remove_*`, `WTBS_LIB_DIR`) instead of being forbidden to act.
- **Prefer structure over lifecycle** (#4): scanning hooks into the
  existing execution points (preflight, `run_hooks`, `_run_strap_script`,
  `exec`) rather than adding a new "scan phase" to the pipeline.
- **Render the plan before running it** (#10): refusals name
  file:line:pattern and the way forward; `--dry-run` remains the
  first-class preview, now also covered by the scan.
- **Honesty about limits**: the scan is explicitly a lint layer, not a
  security boundary — the sandbox is the boundary. Naming the limit is
  part of the design; overselling a linter as a sandbox would be worse
  than either alone.

## Consequences

- A project hook containing a flagged pattern fails at `create`
  preflight with an actionable message; the directive is the documented
  way to say "yes, really" per line.
- Published (project-owned) strap copies predate the guards; they keep
  their old behavior until re-published, and the execution-time scan is
  their protection in the meantime.
- `WTBS_ALLOW_DANGEROUS=1` is deliberately loud (a warning on stderr)
  so its use in scripts is visible in run logs.
