# wtbs

A technology-blind lifecycle runner for git worktrees. (Formerly
worktree-bootstrap; a `worktree-bootstrap` shim is installed for transition.)

The tool owns the **nouns** — worktree, branch, directory, names, state — and
your project owns the **verbs**. Given a branch, it materializes an isolated
environment and runs it at two lifecycle moments (`create`, `destroy`).
Everything that names a stack — MySQL, Valet, ngrok, ports — lives in
**straps**: opt-in, self-contained bundles of policy you can list, publish,
shadow, and edit. Straps also own all env writing: the core copies and
mirrors, straps decide what a worktree's `.env` says
(docs/adr/0007).

The design is recorded as ADRs in [`docs/adr/`](docs/adr/README.md) — read
them before changing the architecture.

The vision: **make working in a worktree as convenient as working in the
parent project.** Same commands, same tooling, no mental context switch.
One use case among many: **agentic development** — agents driving many
branches in parallel from the main repo (`wtbs feature/x test`).

## Install

```bash
./install.sh
```

Copies the project to `~/.local/share/wtbs/` and installs `wtbs` at
`~/.local/bin/wtbs`. Run again any time you update the repo.

## Requirements

- bash, git
- Python 3 + PyYAML (`pip3 install pyyaml`) to parse the config
- whatever your hooks and straps need (mysql/mysqldump for the mysql strap,
  valet for the valet strap, …)

## Quick start

1. Add `.wtbs.yml` to your project root (see `examples/`).
2. `wtbs create feature/my-branch` — create and bootstrap a worktree.
3. `wtbs destroy feature/my-branch` — tear everything down.

Always dry-run a new config first: `wtbs create --dry-run <branch>` renders
the full plan (publishing, residue mirror, strap lifecycles, every hook)
with zero side effects.

## Commands

```bash
wtbs create <branch>        # create + bootstrap a worktree (branch optional)
wtbs bootstrap              # bootstrap the current directory
wtbs destroy <branch|path>  # remove worktree, straps, and state
wtbs exec <branch|path> [cmd...]   # run a preset/alias/verb/command inside
wtbs <branch|path> [cmd...]        # shorthand for exec
wtbs straps                 # list available straps
wtbs strap customize <name> # copy a bundled strap into your repo to edit
wtbs strap init <name>      # scaffold a new project strap
wtbs --help
```

Global options (any position for create/bootstrap/destroy; before the
worktree name for exec/shorthand): `--dry-run`, `--main-repo <path>`,
`--config <path>`, `--base <ref>`, `--dir <name>` (default worktree dir is
`<repo>-<branch>` as a sibling, slashes → dashes, full length),
`--delete-branch`, `--no-publish`.

## Config file (`.wtbs.yml`)

Every key is optional; no config at all = a plain worktree.

```yaml
straps: [valet, mysql, "auto-ports(serve:8000)"]  # activation, with optional args

copy:
  ignore: [node_modules, vendor, storage]  # residue-mirror exclusions

db_name: "myapp_{branch_slug}"  # how {db_name} is computed (default wt_{branch_slug})

publish: false                  # skip strap publishing (default: publish on activation)

hooks:                          # the project's own shell, two moments
  create:
    - composer install
  destroy:
    - "echo bye {db_name}"

aliases:                        # one-liners for exec
  test: "php artisan test"
```

There is deliberately **no `env:` block**. Env writing is strap
responsibility (docs/adr/0007): bundled straps write their own documented
keys (the mysql strap writes `DB_DATABASE`, …), and the project's own keys
are written by the **project env strap** — `.wtbs/straps/env/` in the main
repo, scaffolded automatically on activation:

```bash
# .wtbs/straps/env/create — runs after every strap's create lifecycle
source "${WTBS_LIB_DIR:?}/strap-lib.sh"
wtbs_env_set DB_PORT "$(wtbs_state_get auto_ports.db)"
```

### Copy: the residue mirror

`git worktree add` checks out tracked files only. The copy noun mirrors the
**untracked residue** — everything git did not check out, `.env` included —
from the main repo into the worktree (docs/adr/0008). Exclusions come from
`copy.ignore:` in the yml and/or a `.wtbsignore` file at the repo root
(gitignore-style; both are honored). `.git` and `.wtbs/` are always skipped.
Copy is **seed-only**: a file the worktree already has is never overwritten,
so re-running `bootstrap` never clobbers what straps wrote into `.env`.

### Template tokens

Tokens render in `hooks`, `aliases`, and `db_name`:

- `{branch}`, `{branch_slug}`, `{site}`, `{db_name}`, `{worktree_root}`,
  `{main_repo}`
- `{env.KEY}` — value of KEY from the main repo's `.env` (the source of
  truth)
- `{strap.key}` — strap-published values from the per-branch state file
  (e.g. `{auto_ports.serve}`, `{valet.url}`)

### The lifecycle pipeline (create)

preflight → **publish straps** (activated bundled straps copied into the
project's `.wtbs/straps/`; project env strap scaffolded) → **mirror the
untracked residue** (seed-only, minus ignore rules) → **strap `create`
lifecycles** in declared order (straps compute and write env: allocate,
clone, secure) → **project env strap** (`env/create`, maps strap state to
the project's key names) → project `hooks.create` → report.

`destroy`: strap `destroy` lifecycles → env strap `destroy` → project
`hooks.destroy` → teardown (registry row, state file, worktree, optional
branch delete).

### The hook / lifecycle environment

Scripts run with: worktree as cwd · active strap dirs on PATH · the **main
repo's `.env` exported** (source credentials) · the context as `WTBS_*`
(every token: `WTBS_BRANCH`, `WTBS_SITE`, `WTBS_AUTO_PORTS_SERVE`, …) ·
`WTBS_STATE_FILE` (this branch's wtbs-owned state file) · `WTBS_LIB_DIR`
(`source "$WTBS_LIB_DIR/strap-lib.sh"` for `wtbs_env_set`, `wtbs_state_set`,
`wtbs_state_get` — all dry-run aware) · `WTBS_STRAP_ARGS_<NAME>` (activation
args, verbatim) · user settings.

Attachment is one-directional: wtbs keeps state *about* the project in
`.wtbs/`; the project keeps nothing about wtbs beyond the config and straps
it chose. The project's `.env` is written only by straps — bundled straps
document exactly which keys they write, and local-first shadowing is the
recourse. Uninstalling wtbs leaves no residue.

## Straps

A strap is a **directory**: scripts plus its own private `strap.yml` (read
by the strap, never by the core). The complete interface
(docs/adr/0002, docs/adr/0007):

- **Activation with parameters**: `straps: ["auto-ports(serve:8000;db)"]` —
  the core parses the name for resolution/PATH/lifecycle and exports the
  args verbatim as `WTBS_STRAP_ARGS_<NAME>`. Arg semantics are the strap's
  private schema.
- **Verbs are executable files**: `wtbs <branch> share` runs the strap's
  `share` script via PATH (exec's raw-command tier).
- **Lifecycle scripts**: `<strap>/create` and `<strap>/destroy`, invoked
  with the hook environment; straps run before the project's own hooks.
- **Env writing**: straps write the worktree's `.env` via `wtbs_env_set`
  (the core lends the pen, straps hold it). Bundled straps write their
  documented keys; your project's keys belong in the project env strap.
- **Publish/consume by state**: straps write namespaced keys to the state
  file (`valet.url`, `auto_ports.serve`) via `wtbs_state_set`; consumers
  read them via `wtbs_state_get` or as hook tokens.

Resolution is local-first: worktree `.wtbs/straps/<name>` → main repo →
bundled. On activation, activated bundled straps are **published** into the
project's `.wtbs/straps/` (skip with `--no-publish` or `publish: false`) —
the project owns its copies and bundled straps become seed material. `wtbs
straps` lists them; `strap customize` copies a bundled strap into your repo;
`strap init` scaffolds a new one.

### Bundled straps

| Strap | Shape | What it does |
|---|---|---|
| `mysql`, `postgres`, `sqlite` | per-worktree | clones the main DB into `{db_name}` on create (writes `DB_DATABASE` into the worktree `.env`), drops it on destroy |
| `valet` | setup | serves each worktree via valet; nginx-unsafe names are served under a deterministic short name (symlink); served URL published as `{valet.url}`; writes nothing to `.env` |
| `auto-ports` | per-worktree | allocates unique ports per branch for the services declared at activation (`"auto-ports(serve:8000)"`); publishes `{auto_ports.<name>}` — only when a project asks |
| `ngrok` | singleton | one shared reserved URL with a `share` handoff verb and a steal guard — see `straps/ngrok/README.md` |

> **Line endings:** hook scripts and strap scripts must keep LF endings in
> worktree checkouts (`core.autocrlf=true` breaks shebangs). Add
> `*.sh text eol=lf` (or a broader rule) to your project's `.gitattributes`.

> **Synced project trees:** if your projects directory is mirrored to another
> machine by a sync daemon, note that `destroy` removes wtbs's own state
> (`.wtbs/`) — but a sync that doesn't propagate deletions will resurrect
> those files from the other machine. Exclude the project (at least its
> `.wtbs/`) from the mirror; git already carries what needs to travel.

### User settings

Per-user strap settings (a reserved ngrok domain, an API key) live in
`~/.config/wtbs/settings.yml`, never in project files:

```yaml
ngrok:
  shared_url: your-reserved.ngrok.dev
  share_port: 8787
```

The core exports each `namespace.key` as a namespaced env var
(`ngrok.shared_url` → `NGROK_SHARED_URL`) into hook and exec environments,
after any `.env` export, so settings win. Override the path with
`WTBS_SETTINGS_FILE` (mainly for tests).

## Running commands in a worktree

`exec` runs something inside a worktree with its own context — cwd, `.env`
exported, strap dirs plus `.venv/bin`/`vendor/bin`/`node_modules/.bin` on
PATH, context as `WTBS_*`. Resolution order:

1. **Preset** — `.wtbs/<name>` (worktree shadows main); bash with args as
   positionals; CR-stripped; not template-rendered (use `WTBS_*`).
2. **Alias** — `aliases:` one-liner, template-rendered, args appended.
3. **Raw command** — verbatim, template-rendered; **this tier resolves strap
   verbs** (executable files in active strap dirs).

Exit codes propagate. Presets, aliases, and strap scripts are project files
executed as-is — only run them for repositories you trust.

## Migrating from v0.3 / v0.4

v0.4 broke with v0.3 keys; v0.5 breaks with v0.4 keys — both fail fast with
pointers, nothing is silently reinterpreted. The tool is renamed
(`worktree-bootstrap` → `wtbs`; config `.worktree-bootstrap.yml` →
`.wtbs.yml`; state `.worktree-bootstrap/` → `.wtbs/`).

v0.4 → v0.5:

- The `env:` block is gone — env writes live in straps (docs/adr/0007).
  Move each entry into `.wtbs/straps/env/create` as a `wtbs_env_set` line
  (scaffolded automatically on first activation).
- `copy: [file, …]` is gone — copy is now a residue mirror of all untracked
  files (docs/adr/0008). Remove the list; add `copy.ignore:` (or a
  `.wtbsignore`) for `node_modules`, `vendor`, … instead.
- Activated straps are now published into your repo's `.wtbs/straps/` on
  first activation; `--no-publish` / `publish: false` keeps bundled
  resolution.

v0.3 → v0.4:

- `{ports.*}` / `WTBS_PORT_*` are gone — activate `auto-ports` and use
  `{auto_ports.<name>}` / `WTBS_AUTO_PORTS_<NAME>` (or nothing, under valet).
- Straps no longer mount config fragments — they are directories with
  lifecycle scripts and verbs (docs/adr/0002).

## License

MIT
