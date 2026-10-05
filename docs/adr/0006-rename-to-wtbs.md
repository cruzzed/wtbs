# ADR-0006: Rename worktree-bootstrap to wtbs

## Status
Accepted (v0.4)

## Context
`worktree-bootstrap` was a mouthful, and the tool's internal namespace
already said otherwise: presets and straps live in `.wtbs/`, context
variables are `WTBS_*`. The name and the artifact disagreed.

## Decision
Rename to **wtbs** (worktree bootstrap): binary `wtbs`, config `.wtbs.yml`,
state `.wtbs/`, install `~/.local/share/wtbs`, env prefix `WTBS_`. A
transitional `worktree-bootstrap` shim (deprecation notice + exec) is
installed and will be removed in a future release. The GitHub repo is
`cruzzed/wtbs`.

Full-length directory naming (`<repo>-<branch>`, slashes → dashes) was
restored as the default; the v0.3-era 4-char segment truncation was a
valet-era workaround that violated the convention git worktrees and
surrounding tooling expect. The nginx risk it guarded now lives in the
valet strap (ADR-0002).

## Consequences
One token everywhere; `.wtbs/` is self-describing. Strap scripts and docs
use `wtbs` exclusively.
