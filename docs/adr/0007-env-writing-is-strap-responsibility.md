# ADR-0007: Env writing is strap responsibility — the core only copies

## Status
Accepted (v0.5)

## Context
From v0.3 through v0.4 the core contained an env writer: the config
declared an `env:` block, the core rendered templates (`{db_name}`,
`{auto_ports.*}`, `{env.KEY}`) and applied lines to the worktree's
`.env` with update-or-append semantics. The renderer existed so the core
could transport values from straps into `.env` while remaining
technology-blind — the core was a messenger carrying a letter it could
not read.

The challenge that overturned it: values do a three-hop relay (strap →
state file → token → core → `.env`) for no benefit to the core's
blindness. The core never needed to be on that path at all. Only straps
know their values (Locality of Behavior: the code that produces a value
lives next to the code that writes it), and env writing is almost
exclusively wanted by straps — they are the setup machinery beyond the
simple mirroring that is the core's actual job (see ADR-0008 for the
mirroring half of this same insight).

A secondary question was what guardrail should replace the lost hard
guarantee "nothing enters `.env` except lines the project declared"
(the rule that kept straps off sacred keys like `APP_URL`). Ruling: no
mechanical guardrail. Bundled straps document exactly which keys they
write; local-first shadowing (ADR-0002) is the recourse. Strap behavior
is the user's management responsibility.

## Decision
- **`env:` is deleted from the core config surface.** Every env write is
  performed by a strap. Legacy `env.*` keys are rejected with a
  migration pointer.
- **The core provides the pen, not the policy**: a sourceable helper
  library (`lib/strap-lib.sh`, exported to strap/hook/exec environments
  as `$WTBS_LIB_DIR/strap-lib.sh`) with:
  - `wtbs_env_set KEY VALUE` — update-or-append on the worktree's
    `.env`, dry-run aware (echoes instead of writing under
    `WTBS_DRY_RUN=1`).
  - `wtbs_state_set NS.KEY VALUE` / `wtbs_state_get NS.KEY` — the
    publish/consume bus, now strap-callable instead of core-loaded.
- **Bundled straps write their own keys directly** (e.g. the mysql
  strap writes `DB_DATABASE`). Bundled straps are opinionated defaults;
  agnosticism lives in the core, not in every default strap.
- **Project-native keys belong to a project strap**: on activation the
  core scaffolds `.wtbs/straps/env/` in the main repo — a strap whose
  `create` script maps state to the project's key names in plain bash
  (`wtbs_env_set DB_PORT "$(wtbs_state_get auto_ports.db)"`). The old
  yaml line becomes bash living next to the project's other machinery.
- **Pipeline order**: copy → strap create lifecycles (which now include
  env writes) → project hooks. Hook command token rendering
  (`{branch}`, `{db_name}`, strap-published tokens) is retained — it is
  command interpolation, not env writing.
- **Publish on activation**: the first create/bootstrap copies each
  activated bundled strap into the project's `.wtbs/straps/` so the
  project owns its copies (skippable with `--no-publish` or
  `publish: false`). Bundled straps become seed material.

## Consequences
- The core sheds the entire env renderer and writer (~the whole env
  application block); config shrinks to `straps`, `copy`, `db_name`,
  `hooks`, `aliases`.
- `--dry-run` still shows concrete env writes: `wtbs_env_set` checks
  `WTBS_DRY_RUN`.
- Re-running `bootstrap` re-asserts the writes declared in strap
  scripts (same overwrite-by-declaration drift model as before, now
  owned by straps).
- v0.4's "straps never touch project keys" rule is rescinded: straps are
  the only writers of env. The one-directional attachment (ADR-0004)
  survives in its deeper form: the boot attaches to the project only
  through straps; the project attaches to the boot only by naming
  straps.
- The state file remains the strap-to-strap bus and the source of hook
  tokens; the core loads it into the hook context but never renders it
  into `.env`.
