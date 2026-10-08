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

The project env strap reads them straight from state (docs/adr/0007):

```bash
# .wtbs/straps/env/create
source "${WTBS_LIB_DIR:?}/strap-lib.sh"
wtbs_env_set SERVE_PORT "$(wtbs_state_get auto_ports.serve)"
wtbs_env_set FORWARD_DB_PORT "$(wtbs_state_get auto_ports.db)"
```

Hook commands and aliases render them as tokens:

```yaml
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
port="$(wtbs_state_get auto_ports.db)"
[[ -n "$port" ]] && wtbs_env_set FORWARD_DB_PORT "$port"
```

## State

The strap keeps its own registry at `.wtbs/auto-ports.tsv`
(branch, offset, date). `destroy` releases the offset; the published
`auto_ports.*` keys disappear with the per-branch state file.
