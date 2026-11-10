# Agent guidance

## Beware: Bash and straps can be destructive

- Inspect inner scripts and expansions before running hooks, presets, straps, installers, or cleanup commands.
- Fail closed on empty variables and ambiguous targets; validate paths before deletion, database drops, or process kills.
- Test with dry-runs, temporary directories, and fake service binaries. Never target the real checkout, home directory, or user services for routine verification.

## Destructive-op discipline (enforced, not just encouraged)

- All deletions in core go through the guards in `lib/utils.sh`: `wtbs_remove_file`, `wtbs_remove_tree` (only recursive rm in the tool; requires a git-registered worktree), `wtbs_remove_branch` (refuses protected names: main/master/dev/develop). Never add a bare `rm` to `lib/` or `wtbs.sh` — `tests/bats/lint.bats` fails the build if you do.
- Hooks, strap lifecycle scripts, strap verbs, presets, and aliases are danger-scanned before wtbs runs them (`danger_scan` in `lib/utils.sh`): recursive delete, `sudo`, force-push, and disk destroyers are refused. Escape hatches: mark the specific line `# wtbs:danger-ok <reason>`, or set `WTBS_ALLOW_DANGEROUS=1` (warns loudly). The scan is a lint-layer guard against mistypes and careless patterns, not a sandbox against hostile code.
- Strap scripts needing the guards can `source "${WTBS_LIB_DIR}/utils.sh"` (WTBS_LIB_DIR is exported into hook/exec/strap contexts). Keep an inline fallback when the script must also work standalone.
- Before committing: `./node_modules/.bin/bats tests/bats` and `shellcheck -x lib/*.sh wtbs.sh install.sh straps/*/<script>` must both pass (`.shellcheckrc` documents the project-wide disables and why).
