#!/usr/bin/env bash
set -euo pipefail

port_in_use() {
    local port="$1"
    (echo > /dev/tcp/127.0.0.1/$port) 2>/dev/null
}

# Collect the declared ports (config keys ports.<name>) into the named
# associative array. The core knows no port names — the project (and its
# straps) declares exactly the ports it uses.
collect_base_ports() {
    local -n base_out="$1"
    base_out=()
    local k name
    for k in "${!CONFIG[@]}"; do
        case "$k" in
            ports.*)
                name="${k#ports.}"
                base_out["$name"]="${CONFIG[$k]}"
                ;;
        esac
    done
}

# Compute ports for an offset: every declared port shifts by the same offset,
# so one worktree = one number. base and result are associative array names.
compute_ports() {
    local offset="$1"
    local -n base_ref="$2"
    local -n result_ref="$3"
    result_ref=()
    local key
    for key in "${!base_ref[@]}"; do
        result_ref[$key]=$(( base_ref[$key] + offset ))
    done
}

# Return 0 if every declared port for an offset is free.
offset_ports_available() {
    local offset="$1"
    local -n avail_base_ref="$2"
    local -A ports
    compute_ports "$offset" avail_base_ref ports

    local key
    for key in "${!ports[@]}"; do
        if port_in_use "${ports[$key]}"; then
            return 1
        fi
    done
    return 0
}

# Escape a string for safe use in a POSIX extended regular expression.
regex_escape() {
    sed -E 's/[][\\^$.*+?{}|()]/\\&/g' <<< "$1"
}

# ── Registry ────────────────────────────────────────────────────────────────
# The registry at <main-repo>/.wtbs/registry.tsv is the single source of
# truth for per-branch state: branch, port offset, db name, date.

registry_path() {
    local main_root="$1"
    echo "$main_root/.wtbs/registry.tsv"
}

# Echo a field ("offset" or "db") for a branch, empty when not registered.
state_get() {
    local registry_file="$1" branch="$2" field="$3"
    [[ -f "$registry_file" ]] || return 0
    local escaped_branch row
    escaped_branch="$(regex_escape "$branch")"
    row="$(grep -E "^${escaped_branch}"$'\t' "$registry_file" 2>/dev/null | head -n1)" || true
    [[ -n "$row" ]] || return 0
    case "$field" in
        offset) cut -f2 <<< "$row" ;;
        db)     cut -f3 <<< "$row" ;;
        *)      fatal "unknown state field: $field" ;;
    esac
}

# Register or update a branch's state. No-op in dry-run mode.
state_put() {
    local registry_file="$1" branch="$2" offset="$3" db_name="$4"
    local dry_run="${5:-0}"
    [[ "$dry_run" == "1" ]] && return 0

    mkdir -p "$(dirname "$registry_file")"
    touch "$registry_file"

    local escaped_branch tmp
    escaped_branch="$(regex_escape "$branch")"
    tmp="$(mktemp)"
    grep -vE "^${escaped_branch}"$'\t' "$registry_file" > "$tmp" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\n' "$branch" "$offset" "$db_name" "$(date -Iseconds)" >> "$tmp"
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

# ── Allocation ──────────────────────────────────────────────────────────────

# Allocate an offset for a branch. Echoes the offset.
# When dry_run is "1", the registry is only read (never created or touched).
allocate_offset() {
    local registry_file="$1"
    local branch="$2"
    local -n alloc_base_ref="$3"
    local dry_run="${4:-0}"

    if [[ "$dry_run" != "1" ]]; then
        mkdir -p "$(dirname "$registry_file")"
        touch "$registry_file"
    fi

    if [[ ! -f "$registry_file" ]]; then
        # No registry yet: first free offset wins.
        local off=1
        while [[ $off -le 1000 ]]; do
            if offset_ports_available "$off" alloc_base_ref; then
                echo "$off"
                return 0
            fi
            off=$((off + 1))
        done
        fatal "could not find a free offset after 1000 attempts"
    fi

    # Reuse existing offset for this branch.
    local existing
    existing="$(state_get "$registry_file" "$branch" offset)"
    if [[ -n "$existing" && "$existing" =~ ^[0-9]+$ ]]; then
        echo "$existing"
        return 0
    fi

    # Collect all registered offsets.
    local offsets=()
    local line off
    while IFS=$'\t' read -r _ off _ _; do
        [[ "$off" =~ ^[0-9]+$ ]] && offsets+=("$off")
    done < "$registry_file"

    # Try to reclaim a free registered offset.
    while IFS= read -r off; do
        [[ -z "$off" ]] && continue
        if offset_ports_available "$off" alloc_base_ref; then
            echo "$off"
            return 0
        fi
    done < <(printf '%s\n' ${offsets[@]+"${offsets[@]}"} | sort -n -u)

    # Allocate new offset above the highest registered one.
    local max_offset=0
    for off in ${offsets[@]+"${offsets[@]}"}; do
        (( off > max_offset )) && max_offset=$off
    done

    off=$((max_offset + 1))
    while [[ $off -le 1000 ]]; do
        if offset_ports_available "$off" alloc_base_ref; then
            echo "$off"
            return 0
        fi
        off=$((off + 1))
    done

    fatal "could not find a free offset after 1000 attempts"
}
