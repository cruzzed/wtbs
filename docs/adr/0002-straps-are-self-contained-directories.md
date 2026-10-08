# ADR-0002: Straps are self-contained directories, not config fragments

## Status
Accepted (v0.4)

## Context
The first v0.4 implementation "mounted" straps: each strap's `strap.yml`
(`env:`, `ports:`, `hooks:`, `aliases:`) was merged into the project
config, and the core processed it with project-config semantics. That made
the core the owner of the strap schema (what fragments may contain, merge
precedence, nesting rules), let straps reach into the project's `.env` and
hook list through the project's own config, and gave straps no place for
private configuration — anything strap-specific had to be smuggled through
the core's key space.

The design agreed at genesis: a strap is **its own directory** — scripts
plus its own config file that the strap itself reads.

## Decision
A strap is a directory. The complete core↔strap interface:

1. **Activation with optional parameters**: `straps: [valet,
   "auto-ports(serve:8000)"]` in `.wtbs.yml`. The core parses the bare
   name for resolution/PATH/lifecycle and exports the args verbatim as
   `WTBS_STRAP_ARGS_<NAME>`. What args mean is the strap's private schema.
2. **Verbs are executable files**: `wtbs <branch> share` resolves a strap
   script through the raw-command tier (PATH). No alias merging.
3. **Lifecycle scripts**: `<strap>/create` and `<strap>/destroy`, invoked
   with the hook environment (worktree cwd, main `.env` exported, `WTBS_*`
   context, `WTBS_STATE_FILE`, user settings). Strap lifecycles run before
   the project's own `hooks.*` (strap-then-project ordering).
4. **Private config**: `<strap>/strap.yml` is read by the strap (via
   `BASH_SOURCE`), never by the core. Customized copies in a project hold
   project-level policy and win over user settings.
5. **Publish/consume by token**: straps write namespaced keys to the
   per-branch state file (`valet.url`, `auto_ports.serve`); the core loads
   them into the template context verbatim; projects consume them as
   `{auto_ports.serve}` — explicit opt-in, no injection.

The core never reads strap config, never merges it, and defines no strap
schema beyond the interface above.

## Consequences
- Straps and core evolve independently: a strap schema change cannot break
  the core, and a core config change cannot break straps.
- `.wtbs.yml` names straps; it never contains them.
- Straps compose through the state file, defensively
  (`[[ -n "${WTBS_AUTO_PORTS_DB:-}" ]]`), never by assuming another strap
  is active.
