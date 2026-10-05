# ADR-0004: One-directional attachment — the boot attaches to the project, never vice versa

## Status
Accepted (v0.4)

## Context
Earlier iterations let straps write into the project's `.env` — first
`APP_URL` directly, then a generic `set-url VAR` mechanism. Both were
rejected on the same principle, sharpened by a concrete case: a Laravel
project whose `APP_URL` points at a **static ngrok tunnel** for webhooks.
A valet strap "helpfully" pointing `APP_URL` at the local valet URL breaks
exactly that — and since a reserved ngrok URL is constant across every
handoff, no bootstrap layer should ever rederive it.

## Decision
Attachment is one-directional: **wtbs keeps state about the project; the
project keeps nothing about wtbs.**

- **Project files are sacrosanct.** The project's `.env` is written only
  by `env:` entries the project itself declares. Straps never add,
  modify, or derive project keys (`APP_URL` is never acknowledged to be
  anything). Uninstalling wtbs leaves zero residue.
- **wtbs state lives in wtbs's own files**: the per-branch registry
  (`.wtbs/registry.tsv`), per-branch strap state
  (`.wtbs/worktrees/<branch>.yml`, exposed as `WTBS_STATE_FILE` and loaded
  as template tokens), and per-user settings (`~/.config/wtbs/
  settings.yml`, namespace→env export).
- **Consumption is opt-in.** A project that wants a strap-provided value
  asks for it explicitly: `SOME_KEY: "{auto_ports.serve}"`. Nothing
  appears in project files that the project didn't request.

## Consequences
- The valet strap records where it serves a worktree as `valet.url` in
  the state file; projects read `{valet.url}` if they care.
- Per-user strap settings (a reserved ngrok domain) moved out of project
  `.env` into `~/.config/wtbs/settings.yml` (ADR-0002 interface).
- Any future feature that writes a project file must name the project
  config entry that authorizes it — or it doesn't ship.
