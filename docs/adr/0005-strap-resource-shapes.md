# ADR-0005: Strap resource shapes and the singleton posture

## Status
Accepted (v0.4)

## Context
Straps provision or manage *resources*, and resources come in three
multiplicities. Treating them alike leads to wrong mechanics: a singleton
can't be "provisioned per worktree," and a long-running process doesn't
fit a one-shot lifecycle hook.

## Decision
Three resource shapes; the shape tells the strap what it may do:

1. **Per-worktree** (mysql, sqlite): provision at `create`, drop at
   `destroy`. Multiplicity N — one per branch.
2. **On-demand process** (a dev server, a queue worker): a verb the user
   invokes; the tool never supervises processes. Multiplicity N, but
   user-driven lifetime.
3. **Singleton** (the ngrok reserved URL): exactly one exists; the strap
   provides a **handoff verb** — explicit, idempotent retargeting;
   ownership is whoever asked last. State lives in the external system
   (the running tunnel), not in wtbs.

The singleton's default posture is protective (the **steal guard**): the
resource is registered to exactly one site — the main repo — and a
worktree taking it is rejected unless the project registers more sites
(its private strap config) or customizes the strap (ownership implies
intent). Returning the resource (`--handback`) is never guarded. The
guard is footgun protection, not security.

## Consequences
- The ngrok strap is the reference singleton: one `share` verb, two
   strategies (valet host-header retarget / sacred-port serve swap),
   destroy-time handback, documented in `straps/ngrok/README.md`.
- Future straps must name their resource shape before implementation —
  the shape determines the verbs and the state discipline.
