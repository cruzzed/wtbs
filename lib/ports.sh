#!/usr/bin/env bash
set -euo pipefail

# ── Registry ────────────────────────────────────────────────────────────────
# The registry at <main-repo>/.wtbs/registry.tsv is the single source of
# truth for per-branch state: branch, db name, date. (Port offsets were
# removed from the core in v0.4 — see docs/adr/0003; the auto-ports strap
# keeps its own registry.)

registry_path() {
    local main_root="$1"
    echo "$main_root/.wtbs/registry.tsv"
}

# Per-branch strap state lives in wtbs's own files, never in the project's:
# <main-repo>/.wtbs/worktrees/<branch-slug>.yml. Straps write their
# namespaced keys here (via $WTBS_STATE_FILE in the hook environment); the
# core loads them into the template context verbatim (dotted keys become
# namespaced tokens like {auto_ports.serve}), so projects can opt in to
# strap-provided values explicitly (docs/adr/0004).
state_file_path() {
    local main_root="$1" branch_slug="$2"
    echo "$main_root/.wtbs/worktrees/${branch_slug}.yml"
}

# Load a state file's flat `key: value` entries into the template context.
# Keys may be dotted (strap namespace); they load verbatim.
load_state_into_ctx() {
    local state_file="$1" ctx_name="$2"
    [[ -f "$state_file" ]] || return 0
    local -n lsc_ctx="$ctx_name"
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([a-z0-9_.]+):\ (.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        lsc_ctx["$key"]="$value"
    done < "$state_file"
}

# Echo a field ("db") for a branch, empty when not registered.
state_get() {
    local registry_file="$1" branch="$2" field="$3"
    [[ -f "$registry_file" ]] || return 0
    local escaped_branch row
    escaped_branch="$(regex_escape "$branch")"
    row="$(grep -E "^${escaped_branch}"$'\t' "$registry_file" 2>/dev/null | head -n1)" || true
    [[ -n "$row" ]] || return 0
    case "$field" in
        db) cut -f2 <<< "$row" ;;
        *)  fatal "unknown state field: $field" ;;
    esac
}

# Register or update a branch's state. No-op in dry-run mode.
state_put() {
    local registry_file="$1" branch="$2" db_name="$3"
    local dry_run="${4:-0}"
    [[ "$dry_run" == "1" ]] && return 0

    mkdir -p "$(dirname "$registry_file")"
    touch "$registry_file"

    local escaped_branch tmp
    escaped_branch="$(regex_escape "$branch")"
    tmp="$(mktemp)"
    grep -vE "^${escaped_branch}"$'\t' "$registry_file" > "$tmp" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$branch" "$db_name" "$(date -Iseconds)" >> "$tmp"
    mv "$tmp" "$registry_file"
}

# Remove a branch's state. No-op when the registry or row is missing.
state_delete() {
    local registry_file="$1" branch="$2"
    [[ -f "$registry_file" ]] || return 0
    local escaped_branch tmp
    escaped_branch="$(regex_escape "$branch")"
    tmp="$(mktemp)"
    grep -vE "^${escaped_branch}"$'\t' "$registry_file" > "$tmp" || true
    mv "$tmp" "$registry_file"
}

# Escape a string for safe use in a POSIX extended regular expression.
regex_escape() {
    sed -E 's/[][\\^$.*+?{}|()]/\\&/g' <<< "$1"
}
