#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${HOME}/.local/share/wtbs"
LEGACY_DIR="${HOME}/.local/share/worktree-bootstrap"
BIN_PATH="${HOME}/.local/bin/wtbs"
SHIM_PATH="${HOME}/.local/bin/worktree-bootstrap"

if [[ ! -d "${HOME}/.local/bin" ]]; then
    echo "FATAL: ${HOME}/.local/bin does not exist." >&2
    exit 1
fi

if [[ ! -d "${HOME}/.local/share" ]]; then
    echo "FATAL: ${HOME}/.local/share does not exist." >&2
    exit 1
fi

# Replace any previous install (including the pre-rename worktree-bootstrap
# directory).
rm -rf "$TARGET_DIR" "$LEGACY_DIR"
mkdir -p "$TARGET_DIR"
(
    shopt -s dotglob nullglob
    for item in "$SCRIPT_DIR/"*; do
        name="$(basename "$item")"
        [[ "$name" == ".git" || "$name" == ".superpowers" ]] && continue
        cp -R "$item" "$TARGET_DIR/"
    done
)
chmod +x "$TARGET_DIR/wtbs.sh"

cat > "$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
INSTALLED_DIR="${HOME}/.local/share/wtbs"
exec "$INSTALLED_DIR/wtbs.sh" "$@"
EOF
chmod +x "$BIN_PATH"

# Transitional shim for the pre-v0.4 name.
cat > "$SHIM_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "worktree-bootstrap is now called wtbs — this shim will be removed in a future release." >&2
exec "${HOME}/.local/share/wtbs/wtbs.sh" "$@"
EOF
chmod +x "$SHIM_PATH"

echo "Installed wtbs to $BIN_PATH (worktree-bootstrap shim kept for transition)"
