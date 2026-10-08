# ADR-0008: Copy is a git-aware residue mirror with an ignore list

## Status
Accepted (v0.5)

## Context
`copy:` began as an explicit file list (`.env`, `auth.json`, …) because
`git worktree add` checks out tracked files only, and the untracked
residue (especially gitignored files like `.env`) had to be named one
by one. Naming files one by one is fine for three files and hopeless
for "my project keeps local fixtures, keys, and seeds outside git" —
the user wants the worktree to start as a mirror of the main worktree's
*living* state, with a way to say "not that".

## Decision
- **Copy mirrors the untracked residue**: `git worktree add` provides
  tracked files (commit state); the copy noun copies every untracked
  file from the main repo into the worktree, minus the ignore list.
  Git's own machinery decides what is residue — the core invents no
  file-walking logic.
- **Ignore rules come from two entries, combined as a union**:
  `copy.ignore:` in `.wtbs.yml` and a `.wtbsignore` file at the repo
  root (gitignore-style syntax). Both are honored; there is no
  precedence between them, no negation.
- **Built-in skips are mechanism, not policy**: `.git` (copying it would
  corrupt the worktree) and `.wtbs/` (the core's own state —
  registries, per-branch state, published straps — must never be
  mirrored). Everything else is the project's ignore responsibility.
  No technology-shaped default ignores.
- **Seed-only semantics**: a residue file is copied only when the
  destination does not exist. Copy never overwrites. First create seeds
  `.env`; re-running `bootstrap` never clobbers what straps have since
  written into it (see ADR-0007 — copy runs before strap lifecycles).
- The explicit v0.4 list form (`copy: [file, …]`) is rejected as a
  legacy key with a migration pointer: untracked files are mirrored by
  default now, so the list is redundant; use `copy.ignore:` to carve
  out.

## Consequences
- Typical Laravel project needs no `copy` config at all: `.env` mirrors
  automatically; `copy.ignore:` (or `.wtbsignore`) lists
  `node_modules`, `vendor`, `storage` — which are untracked and would
  otherwise be duplicated gigabyte-for-gigabyte.
- Dirty main checkout: uncommitted changes to *tracked* files do not
  cross over (the worktree gets the commit); untracked files mirror
  exactly as they are on disk.
- `--dry-run` reports the residue file count and the ignore rules
  applied, not a full file dump.
