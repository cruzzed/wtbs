# Contributing to wtbs

Thanks for looking under the hood. wtbs is small on purpose — the code is
the easy part. The design is the contribution. Read
[`docs/adr/`](docs/adr/README.md) first; it records *why* the architecture
is the way it is, and architectural changes arrive as new ADRs, not as code.

## Design principles

These are not preferences; each has a name in the literature, so you can
recognize the shape without our history.

1. **Mechanism, not policy** (Parnas 1972; Ports & Adapters, Cockburn 2005).
   The core owns nouns — worktree, branch, names, state — and never verbs.
   Anything that names a technology (mysql, valet, ngrok, a port) belongs in
   a strap. Enforced mechanically: grep `lib/` for technology names; any hit
   is a bug. When in doubt about where something goes, it goes in a strap.
2. **Name things; never contain them** (Open/Closed, Meyer 1988). The config
   names straps (`straps: [valet, mysql]`); it never contains them. Straps
   are self-contained directories; we removed a config-fragment merge once
   and would remove it again. Extension happens by adding a directory, with
   local copies shadowing bundled ones.
3. **Locality of Behavior** (Gross/htmx 2023; cohesion, Yourdon &
   Constantine 1979). Write values where they're born. The core once relayed
   strap values into `.env` as a blind messenger; the fix was deleting the
   relay (ADR-0007). If your change needs an indirection that understands
   nothing, the responsibility is misplaced.
4. **Prefer structure over lifecycle**. Two lifecycle moments exist —
   `create` and `destroy`. A design that wants a third moment is a design
   conversation, not a PR. Fix ordering by reordering the pipeline, not by
   adding phases.
5. **One-directional attachment**. The boot attaches to the project; the
   project never learns the boot exists. We deliberately enforce this by
   convention and shadowing rather than guardrails — ownership beats
   control. Do not add validation fences without a demonstrated need.
6. **Defaults are seeds**. Bundled straps are opinionated defaults, vendored
   into the project's `.wtbs/straps/` on activation; the project owns its
   copies from then on. Keep bundled straps well-behaved and documented;
   customization belongs in the project's copy.
7. **Single writer, upsert, never clobber**. Each actor owns its declared
   keys; everything else survives. `copy` is seed-only, `wtbs_env_set` is
   update-or-append. No merge engines, no silent overwrites.
8. **Use the platform's machinery**. `git ls-files` decides what the residue
   mirror copies; git pathspec applies the ignore rules. Ask the host
   system's model instead of reimplementing it.
9. **Clean breaks with migration pointers**. Removed config surface fails
   fast with a pointer to its replacement — never silently reinterpreted.
   Breaking changes bump the minor version (0.x line) and get release notes.
10. **Render the plan before running it**. `--dry-run` is a first-class
    output, not a debug flag. New pipeline stages must be visible in
    dry-run, and the run report says what was skipped and why.
11. **Bug reports falsify the design.** Treat every issue as a challenge to
    the doctrine: a fix either ratifies it or amends it (as an ADR), it
    never just patches a symptom.

## Practical rules

- **Suite must be green**: `npx bats tests/bats`. Add or update tests with
  every change — the suite is the specification of the pipeline order and
  the strap contract.
- **Examples never name real projects.** Use generic names (`myapp`,
  `laravel.yml`, `django.yml`).
- **Scripts keep LF endings** (the shebang breaks under CRLF checkouts);
  `straps/**` is covered by `.gitattributes`, but anything new and
  executable needs attention, and so does the executable bit itself.
- **Strap scripts are project files executed as-is** — keep bundled straps
  conservative; document exactly which keys they write and which commands
  they call.
- **One use case per commit**, honestly labeled. Work-in-progress says so
  in the message.

## Releasing

`package.json` version, git tag `v<version>`, `gh release create
<version> --latest`, then `./install.sh` refreshes the installed copy.
Release notes carry migration pointers for every break.
