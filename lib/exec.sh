#!/usr/bin/env bash
set -euo pipefail

# Run a command inside a worktree with its execution context: the worktree
# directory as cwd, its .env exported, active strap dirs plus .venv/bin,
# vendor/bin, and node_modules/.bin prepended to PATH. The command resolves
# in this order:
#
#   1. a preset script `.wtbs/<name>` (worktree checkout first, then the main
#      repo) — run with bash, extra args as positional parameters, and the
#      template context exported as WTBS_* env vars (no template rendering,
#      so scripts may contain literal { braces);
#   2. an alias from the project config (`aliases.<name>`) — rendered with the
#      template context ({ports.serve}, {db_name}, {site}, ...), extra args
#      appended;
#   3. a raw command run verbatim (still template-rendered).

# Internal: echo the path of the preset script for a name, if one exists.
_find_preset() {
    local worktree_path="$1" main_root="$2" name="$3"
    if [[ -f "$worktree_path/.wtbs/$name" ]]; then
        echo "$worktree_path/.wtbs/$name"
    elif [[ -f "$main_root/.wtbs/$name" ]]; then
        echo "$main_root/.wtbs/$name"
    fi
}

# Internal: prepend the execution PATH entries inside the current shell.
_exec_path() {
    local worktree_path="$1" main_root="$2"
    local strap_path bindir
    strap_path="$(strap_path_prefix "$worktree_path" "$main_root")"
    [[ -n "$strap_path" ]] && PATH="$strap_path:$PATH"
    for bindir in .venv/bin vendor/bin node_modules/.bin; do
        [[ -d "$bindir" ]] && PATH="$worktree_path/$bindir:$PATH"
    done
    export PATH
}

# Internal: list available presets and aliases for a worktree.
_list_commands() {
    local ctx_name="$1" worktree_path="$2" main_root="$3"
    local -n list_ctx="$ctx_name"

    local -a straps=()
    declared_straps straps
    if [[ ${#straps[@]} -gt 0 ]]; then
        echo "straps (active):"
        local s
        for s in "${straps[@]}"; do
            printf '  %-16s %s\n' "$s" "$(resolve_strap "$s" "$worktree_path" "$main_root")"
        done
    fi

    local -A presets=()
    local dir f
    for dir in "$main_root/.wtbs" "$worktree_path/.wtbs"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*; do
            [[ -f "$f" ]] || continue
            # Worktree presets shadow main-repo presets of the same name.
            presets["$(basename "$f")"]="$f"
        done
    done
    if [[ ${#presets[@]} -gt 0 ]]; then
        echo "presets (.wtbs/):"
        local name
        while IFS= read -r name; do
            printf '  %-16s %s\n' "$name" "${presets[$name]}"
        done < <(printf '%s\n' "${!presets[@]}" | sort)
    fi

    local -a keys=()
    local k
    while IFS= read -r k; do
        keys+=("$k")
    done < <(printf '%s\n' "${!CONFIG[@]}" | grep -E '^aliases\.' | sort || true)
    if [[ ${#keys[@]} -gt 0 ]]; then
        echo "aliases (.wtbs.yml):"
        for k in "${keys[@]}"; do
            printf '  %-16s %s\n' "${k#aliases.}" "$(render_template "${CONFIG[$k]}" list_ctx)"
        done
    fi

    if [[ ${#straps[@]} -eq 0 && ${#presets[@]} -eq 0 && ${#keys[@]} -eq 0 ]]; then
        echo "no straps, presets (.wtbs/), or aliases (config) defined for this project"
    fi
}

cmd_exec() {
    local target="$1"
    shift

    local main_root worktree_path=""
    main_root="$(resolve_main_root "$MAIN_ROOT_OVERRIDE")"

    if _is_worktree_path "$target"; then
        worktree_path="$(cd "$target" && pwd)"
    else
        worktree_path="$(_worktree_path_for_branch "$target")"
        if [[ -z "$worktree_path" ]]; then
            local candidate
            candidate="$(default_worktree_path "$main_root" "$target")"
            [[ -d "$candidate" ]] && worktree_path="$candidate"
        fi
    fi
    [[ -n "$worktree_path" && -d "$worktree_path" ]] || fatal "no worktree found for: $target"

    load_project_config "$main_root" "$worktree_path"

    local branch branch_slug site env_file offset db_name
    branch="$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch="unknown"
    branch_slug="$(slugify "$branch")"
    site="$(basename "$worktree_path" | tr '[:upper:]' '[:lower:]')"
    env_file="$worktree_path/.env"

    # Branch state comes from the registry (single source of truth), with a
    # computed fallback for worktrees that were never bootstrapped.
    local registry_file
    registry_file="$(registry_path "$main_root")"
    offset="$(state_get "$registry_file" "$branch" offset)"
    db_name="$(state_get "$registry_file" "$branch" db)"
    [[ -z "$db_name" ]] && db_name="$(compute_db_name "$branch" "$branch_slug")"

    local -A base_ports ports
    collect_base_ports base_ports
    compute_ports "${offset:-0}" base_ports ports

    local -A ctx
    build_context ctx "$branch" "$branch_slug" "$site" "$db_name" "$worktree_path" "$main_root" ports
    load_state_into_ctx "$(state_file_path "$main_root" "$branch_slug")" ctx
    export WTBS_STATE_FILE="$(state_file_path "$main_root" "$branch_slug")"

    # No command: list what's available for this worktree.
    if [[ $# -eq 0 ]]; then
        echo "worktree: $worktree_path"
        _list_commands ctx "$worktree_path" "$main_root"
        return 0
    fi

    local preset
    preset="$(_find_preset "$worktree_path" "$main_root" "$1")"

    if [[ -n "$preset" ]]; then
        shift
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "[dry-run] worktree: $worktree_path"
            echo "[dry-run] would export: $env_file"
            echo "[dry-run] would run preset: bash $preset $*"
            return 0
        fi
        local status=0
        (
            cd "$worktree_path"
            _exec_path "$worktree_path" "$main_root"
            export_env_file "$env_file"
            export_context_vars ctx
            # WARNING: presets are project files executed as-is. Only run this
            # against repositories whose .wtbs/ scripts you trust.
            # Worktree checkouts may carry CRLF line endings (core.autocrlf),
            # which corrupts bash syntax; strip trailing CR before running.
            bash <(sed 's/\r$//' "$preset") "$@"
        ) || status=$?
        return "$status"
    fi

    # Alias match (extra args appended) or raw command pass-through.
    local cmd
    local alias_val="${CONFIG["aliases.$1"]:-}"
    if [[ -n "$alias_val" ]]; then
        shift
        cmd="$alias_val"
        [[ $# -gt 0 ]] && cmd="$cmd $*"
    else
        cmd="$*"
    fi
    cmd="$(render_env_refs "$cmd" "$env_file")"
    cmd="$(render_template "$cmd" ctx)"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] worktree: $worktree_path"
        echo "[dry-run] would export: $env_file"
        echo "[dry-run] would run: $cmd"
        return 0
    fi

    local status=0
    (
        cd "$worktree_path"
        _exec_path "$worktree_path" "$main_root"
        export_env_file "$env_file"
        export_context_vars ctx
        # WARNING: alias text comes from the project config and is executed
        # as-is. Only run this against repositories whose config you trust.
        bash -c "$cmd"
    ) || status=$?
    return "$status"
}
