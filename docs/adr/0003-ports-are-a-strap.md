# ADR-0003: Ports are a strap (auto-ports), not a core feature

## Status
Accepted (v0.4)

## Context
Port auto-allocation existed because the genesis workflow had no valet:
dev sites were served directly on ports, so each worktree needed unique
ones. The offset registry, availability checks, `{ports.*}` tokens, and
`WTBS_PORT_*` variables were built into the core as if they were
mechanism. By v0.4 the real workflow serves via valet hostnames, and the
ideal project config carries no port machinery at all — proof that ports
were policy all along.

An earlier draft of the decoupling introduced a third lifecycle moment
(`prepare`) so allocation could finish before `env:` rendering. That was
wrong: it added core machinery to solve an ordering problem that better
structure eliminates.

## Decision
All port machinery moves into the bundled **`auto-ports` strap**:

- The service set is declared at activation: `straps:
  ["auto-ports(serve:8000;db:33060)"]` — per project, private arg schema.
- The strap owns its allocation logic, its own registry
  (`.wtbs/auto-ports.tsv`), and its availability checks (a sourceable
  `lib` so tests can fake the check).
- Results publish as state keys (`auto_ports.serve: 8001`); projects
  consume them as `{auto_ports.serve}` in `env:` or
  `WTBS_AUTO_PORTS_SERVE` in scripts.
- Bases come from the arg (`serve:8000`), the strap's private config, or
  a deterministic hash default.
- Not activated → zero port machinery exists.

**Ordering, not phases:** the bootstrap pipeline runs strap `create`
lifecycles *before* rendering the project's `env:` entries — straps
compute, then project config renders with full context. Two lifecycle
moments suffice; `prepare` was not built and remains a possibility only if
a future need cannot be expressed this way.

## Consequences
- Core tokens `{ports.*}` / `WTBS_PORT_*` are gone (breaking within
  unreleased v0.4); consumers use the strap-namespaced forms.
- The core registry drops its offset column (branch ↔ db_name only).
- Cross-cutting env like `FORWARD_DB_PORT` becomes explicit composition:
  the project activates `auto-ports(db:33060)` and maps
  `FORWARD_DB_PORT: "{auto_ports.db}"`. With valet, most projects won't.
