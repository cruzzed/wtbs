# Architecture Decision Records

The design of wtbs, recorded so it doesn't have to be re-derived.

| ADR | Decision |
|---|---|
| [0001](0001-technology-blind-core.md) | The core is technology-blind (mechanism, not policy) |
| [0002](0002-straps-are-self-contained-directories.md) | Straps are self-contained directories, not config fragments |
| [0003](0003-ports-are-a-strap.md) | Ports are a strap (auto-ports), not a core feature |
| [0004](0004-one-directional-attachment.md) | One-directional attachment: the boot attaches to the project, never vice versa |
| [0005](0005-strap-resource-shapes.md) | Strap resource shapes (per-worktree / process / singleton) and the steal-guard posture |
| [0006](0006-rename-to-wtbs.md) | Rename worktree-bootstrap to wtbs; full-length directory naming |

New decisions get the next number, `Accepted` status, and the same
Context / Decision / Consequences shape. Superseded decisions are marked,
not deleted.
