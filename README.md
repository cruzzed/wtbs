# wtbs

A technology-blind lifecycle runner for git worktrees. (Formerly
worktree-bootstrap; a `worktree-bootstrap` shim is installed for transition.)

The tool owns the **nouns** — worktree, branch, directory, ports, names — and
your project owns the **verbs**. Given a branch, it materializes an isolated
environment (directory + ports + name), renders your declarative shell with
that context, and runs it at two lifecycle moments (`create`, `destroy`).
Everything that names a stack — MySQL, Valet, ngrok, Sail — lives in
**straps**: opt-in config fragments you can list, shadow, and edit.

The vision: **make working in a worktree as convenient as working in the
parent project.** Same commands, same tooling, no mental context switch — the
worktree just has its own database, ports, and environment.

One use case among many: **agentic development**. Coding agents can develop
many branches in parallel, each in its own fully-provisioned worktree, and
drive them from the main repo (`wtbs feature/x test`) without
ever leaving the parent project.

## Install

```bash
./install.sh
```

This copies the project to `~/.local/share/wtbs/` and installs a
launcher at `~/.local/bin/wtbs`. Run it again any time you update
the repo to replace the installed copy.

## Requirements

- bash, git
- Python 3 + PyYAML (`pip3 install pyyaml`) to parse the config
- whatever your hooks and straps need (e.g. `mysql`/`mysqldump` for the
  mysql strap, `psql`/`pg_dump` for postgres, `valet` for the valet strap)

## Quick start

1. Add `.wtbs.yml` to your project root (see `examples/`).
2. From the main repo, create and bootstrap a worktree:
   ```bash
   wtbs create feature/my-branch
   ```
3. When done, destroy it:
   ```bash
   wtbs destroy feature/my-branch
   ```

Always dry-run first when trying a config: `wtbs create
--dry-run <branch>` renders the full plan (merged straps, ports, env updates,
and every hook command) with zero side effects.

## Commands

```bash
wtbs create <branch>        # create + bootstrap a worktree
                                          # (creates the branch if it doesn't exist)
wtbs bootstrap              # bootstrap the current directory
wtbs destroy <branch|path>  # remove worktree, hooks, and state
wtbs exec <branch|path> [cmd...]
                                          # run a preset/alias/command inside
                                          # a worktree; no cmd = list what's available
wtbs <branch|path> [cmd...]        # shorthand for exec
wtbs straps                 # list available straps
wtbs strap customize <name> # copy a bundled strap into your repo
wtbs strap init <name>      # scaffold a new project strap
wtbs --help                 # show help
```

Global options (may appear in any position for `create`/`bootstrap`/`destroy`;
for `exec`/shorthand they must come **before** the worktree name, since
everything after the worktree name is passed to the command verbatim):

- `--dry-run` — preview without making changes
- `--main-repo <path>` — override main repo path
- `--config <path>` — override config file path
- `--base <ref>` — base ref for a new branch (create only; default: HEAD)
- `--dir <name>` — custom worktree directory name (create only). The default
  is `<repo>-<branch>` as a sibling directory, with slashes in the branch
  name becoming dashes (`MyRepo` + `feature/shopify-oauth-space-selector` →
  `MyRepo-feature-shopify-oauth-space-selector`). Names stay natural and
  full-length — the valet strap resolves nginx-unsafe names automatically
  (short site name + symlink; the served URL lands in wtbs's per-branch
  state as `{state.valet_url}`), so `--dir` is only needed when you want a
  specific name
- `--delete-branch` — also delete the branch after `destroy`

`destroy` always runs `git worktree prune` afterwards, so the branch is
deletable immediately.

## Config file

Each project adds `.wtbs.yml` at its root. Every key is
optional; with no config at all you get a plain worktree and nothing else.

```yaml
straps: [valet, mysql]      # opt-in policy bundles (see "Straps" below)

copy:                       # files to copy from the main repo into the worktree
  - .env

db_name: "myapp_{branch_slug}"   # how the {db_name} token is computed
                                 # (default: wt_{branch_slug}); the core only
                                 # computes the name — databases are strap business

ports:                      # free-form map of name: base port. The tool
  app: 8080                 # allocates one offset per branch and shifts every
  db: 33060                 # declared port by it, checking availability of all
                            # of them. Declare only what you use.

env:                        # rewrites applied to the worktree's .env after copying
  DB_DATABASE: "{db_name}"
  APP_PORT: "{ports.app}"

hooks:                      # the only lifecycle: two moments, each a list of
  create:                   # rendered shell lines
    - composer install
    - npm ci && npm run build
  destroy:
    - "echo bye {db_name}"

aliases:                    # one-liners for exec
  test: "php artisan test"
```

Template tokens available in `env`, `hooks`, `aliases`, and `db_name`:

- `{branch}` — raw branch name
- `{branch_slug}` — safe slug (`feature/x` → `feature_x`)
- `{site}` — lowercased worktree directory basename
- `{db_name}` — the computed database name
- `{worktree_root}`, `{main_repo}` — absolute paths
- `{ports.<name>}` — each declared port, shifted by the branch's offset
- `{state.<key>}` — strap-written per-branch state from wtbs's own state
  file (`.wtbs/worktrees/<branch-slug>.yml`); the opt-in channel through
  which a project may consume a strap-provided value — nothing is written
  into project files unless the project asks for it
- `{env.KEY}` — the current value of KEY from an env file. In `env:` entries
  this reads the file being rewritten (useful to preserve an original:
  `PARENT_DATABASE_URL: "{env.DATABASE_URL}"`). In `hooks` it reads the
  **main repo's** `.env` — the source of truth (see below).

### The hook environment

Hooks run with:

- the worktree as cwd
- active strap dirs prepended to PATH (so strap hooks call their scripts by
  bare name: `db-clone {db_name}`)
- the **main repo's `.env` exported** — so credentials a hook sees are always
  the *source* ones, even after the worktree's `.env` has been rewritten
  (e.g. a DB clone hook reads the source `DB_DATABASE` from the environment
  while the worktree file already points at the target)
- the template context exported as `WTBS_*` (`WTBS_BRANCH`, `WTBS_BRANCH_SLUG`,
  `WTBS_SITE`, `WTBS_DB_NAME`, `WTBS_WORKTREE_ROOT`, `WTBS_MAIN_REPO`,
  `WTBS_PORT_<NAME>`)
- `WTBS_STATE_FILE` — the path of this branch's wtbs-owned state file
  (`.wtbs/worktrees/<branch-slug>.yml`). Straps record their per-branch
  values there; the core loads them into the template context as
  `{state.<key>}`.

Attachment is one-directional: wtbs keeps its state *about* the project in
`.wtbs/`, but never leaves a trace in project files. The project's `.env`
is written only by the `env:` entries the project itself declares —
straps don't add keys to it, and uninstalling wtbs leaves no residue.

Before any work begins, bootstrap verifies that script paths referenced by
`hooks.*` exist in the worktree checkout and fails fast with a clear message
if any are missing (hook scripts must be committed to the branch being
bootstrapped). Hook failures abort the run — end best-effort destroy hooks
with `|| true`.

## Straps

A strap is a directory containing a `strap.yml` config fragment plus optional
scripts. Activating it (naming it in `straps:`) **merges the fragment into
your config** and **prepends the strap's directory to PATH** during hooks and
exec. That's the whole mechanism — the core never learns what a "mysql" or a
"valet" is.

```yaml
straps: [valet, mysql]
```

**Resolution** is local-first, one rule: worktree `.wtbs/straps/<name>` →
main repo `.wtbs/straps/<name>` → bundled `straps/<name>` shipped with the
tool. First hit wins.

**Merge rule**, one sentence: scalars and maps merge with the project config
winning (between straps, later-declared wins); lists (`hooks`, `copy`)
concatenate strap-then-project in declared order.

A strap fragment may contain `copy`, `db_name`, `ports`, `env`, `hooks`,
`aliases` — never `straps:` (no nesting, no dependency graph).

### Bundled straps

| Strap | Shape | What it does |
|---|---|---|
| `mysql` | per-worktree | clones the main DB into `{db_name}` on create, drops it on destroy; declares `ports.db` and rewrites `DB_DATABASE`/`FORWARD_DB_PORT` |
| `postgres` | per-worktree | same for Postgres |
| `sqlite` | per-worktree | copies the SQLite file to `{db_name}.sqlite`, rewrites `DB_DATABASE` |
| `valet` | setup | `valet secure`/`unsecure` hooks; when a name would break nginx it serves a deterministic short name via symlink instead — the served URL is recorded in wtbs's per-branch state (`{state.valet_url}`); the project's `.env` is never touched |
| `ngrok` | singleton | ONE reserved ngrok URL shared by all checkouts; `share` verb hands it over, with a steal guard (see `straps/ngrok/README.md`) |

Straps come in three resource shapes:

- **per-worktree** (mysql, sqlite): provision at create, drop at destroy
- **on-demand process** (a queue worker, a dev server): presets/aliases you
  invoke; the tool never supervises processes
- **singleton** (ngrok): one shared resource with a handoff verb; state lives
  in the external system, not in the tool

### Customizing and writing straps

```bash
wtbs straps                  # what's available, from where, what's active
wtbs strap customize valet   # copy bundled → .wtbs/straps/valet/
wtbs strap init mystrap      # scaffold an empty project strap
```

After `customize`, the local copy shadows the bundled one — edit it freely
(the bundled default stays convention-pure). Project straps live at
`.wtbs/straps/<name>/` and are committed to your repo, so a team can share
its own twist (a Neon branch-per-worktree strap is the classic example).
Strap settings that are per-user (like a reserved ngrok URL) belong in the
main repo's `.env` — it's copied to worktrees by `copy: [.env]` and exported
into hook and exec environments.

> **Note on line endings:** hook scripts and strap scripts must keep LF
> endings in worktree checkouts, or their shebangs break
> (`core.autocrlf=true` checks out CRLF). Add `*.sh text eol=lf` (or a
> broader rule) to your project's `.gitattributes`.

## Running commands in a worktree

`exec` runs something inside a worktree without leaving the main repo, with
the worktree's own execution context — cwd, `.env` exported, strap dirs plus
`.venv/bin`, `vendor/bin`, and `node_modules/.bin` on PATH (whichever exist),
and the template context exported as `WTBS_*`:

```bash
wtbs feature/x test              # shorthand
wtbs exec feature/x serve        # explicit form
wtbs exec feature/x              # list straps/presets/aliases
```

The command name resolves in this order:

1. **Preset script** — `.wtbs/<name>` in the worktree checkout, falling back
   to the main repo (a branch can carry its own commands, or override
   project-wide ones). Run with bash; extra args arrive as positional
   parameters. Presets are *not* template-rendered (real scripts may contain
   literal `{` braces); they use the `WTBS_*` env vars instead. Trailing CR
   is stripped before execution, so CRLF checkouts don't break presets.

   ```bash
   # .wtbs/serve
   #!/usr/bin/env bash
   exec php artisan serve --port "${WTBS_PORT_SERVE:-8000}" "$@"
   ```

2. **Alias** — a one-liner from `aliases:`, rendered with the template
   tokens; extra arguments are appended.

   ```yaml
   aliases:
     test: "uv run pytest"
   ```

   `wtbs feature/x test -k login` → `uv run pytest -k login`.

3. **Raw command** — anything else, run verbatim (still template-rendered).

The command's exit code propagates, so this composes with scripts and CI.
The same trust warning as `hooks` applies: presets, aliases, and strap
scripts are project files executed as-is — only run them for repositories
you trust.

## How ports are allocated

The tool keeps a registry at `<main-repo>/.wtbs/registry.tsv`
(branch, port offset, db name). One offset per branch: it reuses the same
offset for a branch, reclaims a free registered offset, or allocates a new one
above the highest registered offset. Every declared port shifts by the same
offset, so one worktree = one number. The registry is the single source of
truth for `destroy` and `exec` — nothing is written into your `.env` except
the keys you declare.

## Migrating from v0.3

v0.4 is a clean break, and the tool is renamed: `worktree-bootstrap` →
`wtbs` (a shim keeps the old command working), `.worktree-bootstrap.yml` →
`.wtbs.yml`, and per-branch state moves from `.worktree-bootstrap/` to
`.wtbs/registry.tsv` (delete the old directory; state regenerates on the
next bootstrap).

v0.3 config keys (`database.*`, `commands.*`, `env_updates`,
`copy_from_main`, `ports.base.*`) fail fast with a pointer here:

- `database.driver: mysql` + the `*_env_key` family → `straps: [mysql]`
  (per-project tweaks: `wtbs strap customize mysql`)
- `database.create`/`drop` command hooks → `hooks.create`/`hooks.destroy`
- `commands.install`/`build` → `hooks.create`; `commands.destroy` →
  `hooks.destroy`; `commands.serve` → an alias or `.wtbs/serve` preset
- `env_updates` → `env`; `copy_from_main` → `copy`; `ports.base.*` → `ports:`
- the Laravel/Sail defaults are gone — with no config you get a plain
  worktree; pick the opinions you want from `straps:` and `examples/`

## License

MIT
