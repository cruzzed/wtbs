#!/usr/bin/env bash
# strap-lib.sh — the pen the core lends straps (docs/adr/0007).
#
# Source this from strap lifecycle scripts, verbs, hooks, or presets:
#   source "${WTBS_LIB_DIR:?run inside wtbs}/strap-lib.sh"
#
# The core provides these mechanisms but never decides what gets written
# or when — that is strap policy. All helpers are dry-run aware: under
# WTBS_DRY_RUN=1 they echo what they would do instead of doing it.
set -euo pipefail

_STRAP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/env.sh
source "$_STRAP_LIB_DIR/env.sh"

# Write KEY=VALUE to the worktree's .env (update-or-append, never touches
# other lines). Creates the file when missing. Under dry-run, echoes the
# line instead of writing. Call with cwd = the worktree root, or set
# WTBS_ENV_FILE explicitly.
wtbs_env_set() {
    local key="$1" value="$2"
    local file="${WTBS_ENV_FILE:-./.env}"
    if [[ "${WTBS_DRY_RUN:-0}" == "1" ]]; then
        echo "[dry-run] env: ${key}=${value}"
        return 0
    fi
    update_env_key "$file" "$key" "$value"
}

# Publish a namespaced key to this branch's state file
# (wtbs_state_set valet.url https://…). Idempotent per key.
wtbs_state_set() {
    local key="$1" value="$2"
    local file="${WTBS_STATE_FILE:?WTBS_STATE_FILE is not set — state helpers run inside wtbs}"
    [[ "$key" =~ ^[a-z0-9_.]+$ ]] || { echo "wtbs_state_set: invalid key: '$key' (lowercase, digits, dots, underscores)" >&2; return 1; }
    if [[ "${WTBS_DRY_RUN:-0}" == "1" ]]; then
        echo "[dry-run] state: ${key}: ${value}"
        return 0
    fi
    mkdir -p "$(dirname "$file")"
    touch "$file"
    local tmp="$file.tmp"
    grep -vE "^${key}: " "$file" > "$tmp" 2>/dev/null || true
    echo "${key}: ${value}" >> "$tmp"
    mv "$tmp" "$file"
}

# Read a namespaced key from this branch's state file. Echoes the value,
# or nothing when unset.
wtbs_state_get() {
    local key="$1"
    local file="${WTBS_STATE_FILE:?WTBS_STATE_FILE is not set — state helpers run inside wtbs}"
    [[ -f "$file" ]] || return 0
    sed -nE "s|^${key}: (.*)\$|\1|p" "$file" | head -n1
}
