# auto-ports strap — per-branch unique ports, only when a project asks

Ports were core machinery in early wtbs because dev sites were served
directly on ports. Under valet (hostnames, no app port) most projects need
none — so allocation is a strap, activated per project (docs/adr/0003).

## Usage

Declare the service set at activation, in `.wtbs.yml`:

```yaml
straps: ["auto-ports(serve:8000;db:33060)"]
```

Each arg is `name[:base]`. The strap allocates **one offset per branch**
(reusing the branch's previous offset, reclaiming a freed one, or taking
the next free), checks that every declared port is available, and
publishes the concrete values as state keys:

```yaml
# written to .wtbs/worktrees/<branch>.yml by the create lifecycle
auto_ports.serve: 8001
auto_ports.db: 33061
```

A name without a base (`auto-ports(weird)`) gets a deterministic
hash-derived base in the 20000–39999 range — stable across runs, so
offsets stay meaningful. Not activated → zero port machinery runs.

## Consuming the values

Project config renders them like any token (even on first create — the
strap's create lifecycle runs before `env:` rendering):

```yaml
env:
  SERVE_PORT: "{auto_ports.serve}"
  FORWARD_DB_PORT: "{auto_ports.db}"
aliases:
  serve: "python manage.py runserver {auto_ports.serve}"
```

Scripts and presets read the uniform env export:

```bash
exec php artisan serve --port "${WTBS_AUTO_PORTS_SERVE:-8000}"
```

Straps compose defensively — check before assuming another strap is
active:

```bash
[[ -n "${WTBS_AUTO_PORTS_DB:-}" ]] && sed -i -E "s|^FORWARD_DB_PORT=.*|FORWARD_DB_PORT=${WTBS_AUTO_PORTS_DB}|" ./.env
```

## State

The strap keeps its own registry at `.wtbs/auto-ports.tsv`
(branch, offset, date). `destroy` releases the offset; the published
`auto_ports.*` keys disappear with the per-branch state file.
