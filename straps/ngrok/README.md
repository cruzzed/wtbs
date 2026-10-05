# ngrok strap — the reference *singleton* strap

Some resources can't be provisioned per worktree because there's exactly one
of them: a paid ngrok reserved URL is the archetype. This strap doesn't
provision anything — it provides a **handoff verb**. Whichever checkout runs
`share` last owns the URL.

## Setup

In the main repo's `.env` (which `copy: [.env]` seeds into worktrees):

```dotenv
NGROK_SHARED_URL=your-reserved.ngrok.dev
# optional, port-swap strategy only:
NGROK_SHARE_PORT=8787
```

Activate the strap in `.wtbs.yml`:

```yaml
straps: [ngrok]
```

## Usage

```bash
wtbs feature/x share   # the URL now points at the worktree
wtbs . share           # ...and now back at the main repo
```

There is no registry entry, no PID file, no supervision — the state is the
running ngrok process itself. Check where the URL points by visiting it.

## Strategies

**Valet installed** — the tunnel is a dedicated, disposable process
retargeted with kill-and-respawn:

```bash
ngrok http --url="$NGROK_SHARED_URL" --host-header=rewrite "<site>.<tld>" 80
```

The `pkill` pattern includes your reserved URL, so only this tunnel is ever
killed — but the convention stands: run the shared tunnel as its own ngrok
process, not multiplexed with your other tunnels.

**No valet** — the tunnel targets a fixed *sacred port* and the swap happens
at the server: whatever listens on `$NGROK_SHARE_PORT` (default 8787) got
there through this strap, so killing it is always a legitimate handoff. The
strap then re-serves the project via its `serve` preset (`.wtbs/serve`),
spawned with `WTBS_PORT_SERVE=$NGROK_SHARE_PORT`. Write your preset to honor
that variable:

```bash
#!/usr/bin/env bash
exec php artisan serve --port "${WTBS_PORT_SERVE:-8000}" "$@"
```

The sacred port must be dedicated to sharing — never reuse an everyday dev
port, or the handoff would kill your normal server.

## Steal guard (default posture)

The shared URL is registered to **exactly one site by default: the main
repo**. A `share` from any other checkout is a *steal* and is rejected:

```text
ngrok-share: refusing to hand https://your-reserved.ngrok.dev to 'myapp-feat-x'
  the shared URL is registered to: main
```

Two ways to open it up, both deliberate acts:

1. **Register more sites** in the main repo `.env` — handoffs between
   registered sites become legal:

   ```dotenv
   NGROK_SITES="main,myapp-feat-x"
   ```

   Site names are the lowercased directory basenames (`{site}`); `main` is
   the main repo.

2. **Customize the strap** (`wtbs strap customize ngrok`) — a
   project-local strap owns its policy; the guard permits everything when it
   runs from `.wtbs/straps/`. Keep, tune, or delete the `ngrok-guard` call in
   your copy of `ngrok-share`.

The guard is footgun protection, not a security boundary: its job is that
taking the shared URL is always deliberate, never an accident. `--handback`
(returning the URL) is never guarded.

## Destroy handback

The destroy hook runs `ngrok-share --handback || true`: with valet, the
tunnel is retargeted to the main repo's site; without valet, the dying
worktree's listener on the sacred port is killed (re-run `share` from the
main repo to reclaim the URL). Best-effort by design — a dangling tunnel is
annoying, never fatal.
