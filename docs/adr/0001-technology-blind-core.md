# ADR-0001: The core is technology-blind (mechanism, not policy)

## Status
Accepted (v0.4)

## Context
`worktree-bootstrap` v0.3 embedded framework policy in its core: six
hardcoded Laravel/Sail port names, built-in MySQL/Postgres/SQLite drivers,
a valet/nginx name-length guard, and Laravel defaults applied when no
config existed. The tool claimed to be framework-agnostic but its core
named mysql, composer, npm, vite, redis, mailhog, valet, nginx — every one
a leakage of one stack's conventions into the mechanism.

## Decision
The core owns only technology-blind **nouns** — worktree, branch,
directory, names, state — and the machinery that renders project-declared
shell with a per-branch context at lifecycle moments. Everything that
names a stack is **policy**, expressed in opt-in straps, examples, or user
settings.

The test: **grep the core for technology names — any hit is a bug.**
The opinion budget is spent only where the opinion is technology-blind:
sibling-directory naming (`<repo>-<branch>`), branch↔path resolution via
`git worktree list`, template rendering, dry-run everywhere, fail-fast
preflight.

## Consequences
- Defaults were evicted: no config means a plain worktree and nothing
  else. Opinionated flows live in `examples/` and bundled straps.
- Anything framework-shaped that still lives in the core is treated as a
  defect (ports were the last holdout — see ADR-0003).
- New core features must pass the grep test; new stack behavior ships as
  a strap or an example, never as core code.
