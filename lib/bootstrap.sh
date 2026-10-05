#!/usr/bin/env bash
set -euo pipefail

# Source all modules.
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/env.sh"
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/strap.sh"
source "${LIB_DIR}/ports.sh"
source "${LIB_DIR}/worktree.sh"
source "${LIB_DIR}/exec.sh"

# Globals set by argument parsing.
DRY_RUN=0
MAIN_ROOT_OVERRIDE=""
CONFIG_PATH_OVERRIDE=""
BASE_REF=""
DELETE_BRANCH=0
DIR_OVERRIDE=""
WORKTREE_ROOT_OVERRIDE=""
BRANCH_OVERRIDE=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --delete-branch) DELETE_BRANCH=1 ;;
            --main-repo) shift; MAIN_ROOT_OVERRIDE="$1" ;;
            --config) shift; CONFIG_PATH_OVERRIDE="$1" ;;
            --base) shift; BASE_REF="$1" ;;
            *) fatal "unknown option: $1" ;;
        esac
        shift
    done
}

load_project_config() {
    local main_root="$1" worktree_root="${2:-}"
    local config_path="${CONFIG_PATH_OVERRIDE:-$main_root/.wtbs.yml}"
    load_config "$config_path"
    reject_legacy_keys
    merge_straps "$worktree_root" "$main_root"
    apply_defaults
}

# Build the template context associative array. Keys: branch, branch_slug,
# site, db_name, worktree_root, main_repo, and ports.<name>.
build_context() {
    local -n ctx_out="$1"
    local branch="$2" branch_slug="$3" site="$4" db_name="$5"
    local worktree_root="$6" main_root="$7"
    local -n ctx_ports="$8"

    ctx_out[branch]="$branch"
    ctx_out[branch_slug]="$branch_slug"
    ctx_out[site]="$site"
    ctx_out[db_name]="$db_name"
    ctx_out[worktree_root]="$worktree_root"
    ctx_out[main_repo]="$main_root"
    local k
    for k in "${!ctx_ports[@]}"; do
        ctx_out["ports.$k"]="${ctx_ports[$k]}"
    done
}

# Export the template context as WTBS_* env vars (used by hooks, exec
# presets, and anything a strap script needs without template rendering).
export_context_vars() {
    local -n ctx_ref="$1"
    export WTBS_BRANCH="${ctx_ref[branch]}"
    export WTBS_BRANCH_SLUG="${ctx_ref[branch_slug]}"
    export WTBS_SITE="${ctx_ref[site]}"
    export WTBS_DB_NAME="${ctx_ref[db_name]}"
    export WTBS_WORKTREE_ROOT="${ctx_ref[worktree_root]}"
    export WTBS_MAIN_REPO="${ctx_ref[main_repo]}"
    local key pname
    for key in "${!ctx_ref[@]}"; do
        [[ "$key" == ports.* ]] || continue
        pname="WTBS_PORT_${key#ports.}"
        export "${pname^^}=${ctx_ref[$key]}"
    done
}

# Run every hook for a lifecycle step ("create" or "destroy"), rendered with
# the full template context plus {env.KEY} references. Hooks run with the
# worktree as cwd, active strap dirs on PATH, the MAIN repo's .env exported
# (the source of truth — e.g. DB credentials are the clone SOURCE), and the
# context exported as WTBS_*. Values written into the worktree .env are
# available via the template context ({ports.*}, {db_name}, ...).
run_hooks() {
    local step="$1" ctx_name="$2"
    local -n hook_ctx="$ctx_name"
    local -a cmds=()
    config_list "hooks.$step" cmds
    [[ ${#cmds[@]} -gt 0 ]] || return 0

    local main_env="${hook_ctx[main_repo]}/.env"
    local strap_path
    strap_path="$(strap_path_prefix "${hook_ctx[worktree_root]}" "${hook_ctx[main_repo]}")"

    local cmd rendered_cmd
    for cmd in "${cmds[@]}"; do
        rendered_cmd="$(render_env_refs "$cmd" "$main_env")"
        rendered_cmd="$(render_template "$rendered_cmd" "$ctx_name")"
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "[dry-run] would run: $rendered_cmd"
        else
            info "running: $rendered_cmd"
            (
                cd "${hook_ctx[worktree_root]}"
                [[ -n "$strap_path" ]] && export PATH="$strap_path:$PATH"
                export_env_file "$main_env"
                export_context_vars "$ctx_name"
                # WARNING: hooks come from the project config and active
                # straps and are executed as-is. Only run this tool against
                # repositories whose bootstrap config you trust.
                eval "$rendered_cmd"
            ) || fatal "command failed: $rendered_cmd"
        fi
    done
}

# Fail fast when hook scripts referenced in hooks.* are missing from the
# checkout. Only tokens that look like paths (contain a "/") are checked;
# plain command names are assumed to resolve via PATH (e.g. strap scripts).
# Mode "fail" aborts; mode "warn" only prints (create --dry-run, where the
# worktree does not exist yet).
preflight_hook_scripts() {
    local ctx_name="$1" check_root="$2" mode="$3"

    local -a entries=()
    local -a step_cmds=()
    config_list hooks.create step_cmds
    entries+=(${step_cmds[@]+"${step_cmds[@]}"})
    config_list hooks.destroy step_cmds
    entries+=(${step_cmds[@]+"${step_cmds[@]}"})

    local -a missing=()
    local entry rendered token path
    for entry in ${entries[@]+"${entries[@]}"}; do
        [[ -z "$entry" ]] && continue
        rendered="$(render_template "$entry" "$ctx_name")"
        token="${rendered%%[[:space:]]*}"
        [[ "$token" == */* ]] || continue
        if [[ "$token" == /* ]]; then
            path="$token"
        else
            path="$check_root/$token"
        fi
        [[ -e "$path" ]] || missing+=("$token")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        if [[ "$mode" == "warn" ]]; then
            warn "hook scripts not found in $check_root: ${missing[*]}"
        else
            printf 'FATAL: hook script not found in worktree: %s\n' "${missing[@]}" >&2
            fatal "commit the missing scripts to the branch, or fix hooks in .wtbs.yml"
        fi
    fi
}

cmd_bootstrap() {
    local main_root worktree_root branch branch_slug env_file db_name
    main_root="$(resolve_main_root "$MAIN_ROOT_OVERRIDE")"
    if [[ -n "$WORKTREE_ROOT_OVERRIDE" ]]; then
        worktree_root="$WORKTREE_ROOT_OVERRIDE"
    else
        worktree_root="$(pwd)"
        require_not_main_root "$main_root"
    fi

    load_project_config "$main_root" "$worktree_root"

    branch="${BRANCH_OVERRIDE:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"
    branch_slug="$(slugify "$branch")"

    env_file="$worktree_root/.env"
    # On a fresh create (and in dry-run) the worktree .env does not exist yet
    # — copy seeds it later in the run. Resolve {env.KEY} references and hook
    # environments against the main repo's .env in that case, which is what
    # copy would seed the worktree with.
    local env_refs_file="$env_file"
    if [[ ! -f "$env_file" ]]; then
        env_refs_file="$main_root/.env"
    fi

    db_name="$(compute_db_name "$branch" "$branch_slug")"

    echo "── wtbs preflight ──────────────────────────"
    echo "  worktree : $worktree_root"
    echo "  main repo: $main_root"
    echo "  branch   : $branch"
    echo "  db name  : $db_name"

    # Ports: allocate one offset for the declared set, if any.
    local -A base_ports ports
    collect_base_ports base_ports
    local registry_file offset=0
    registry_file="$(registry_path "$main_root")"
    if [[ ${#base_ports[@]} -gt 0 ]]; then
        offset="$(allocate_offset "$registry_file" "$branch" base_ports "$DRY_RUN")"
    fi
    compute_ports "$offset" base_ports ports

    # Template context for hooks and env.
    local site
    site="$(basename "$worktree_root" | tr '[:upper:]' '[:lower:]')"
    local -A ctx
    build_context ctx "$branch" "$branch_slug" "$site" "$db_name" "$worktree_root" "$main_root" ports

    # Fail fast on missing hook scripts before changing anything. When the
    # worktree does not exist yet (create --dry-run), warn against the main
    # repo instead.
    if [[ -n "$WORKTREE_ROOT_OVERRIDE" ]]; then
        preflight_hook_scripts ctx "$main_root" warn
    else
        preflight_hook_scripts ctx "$worktree_root" fail
    fi

    # Copy files.
    local -a files=()
    config_list copy files
    if [[ $DRY_RUN -eq 0 ]]; then
        copy_files "$main_root" "$worktree_root" ${files[@]+"${files[@]}"}
        info "copied config files"
    else
        echo "[dry-run] would copy config files: ${files[*]:-<none>}"
    fi

    # Apply every env entry from the config, rendered through the full
    # template context plus {env.KEY} references to existing values. The core
    # writes nothing on its own — DB names, URLs, and ports are all policy
    # declared by the project or its straps.
    local -A env_entries=()
    local cfg_key env_key
    for cfg_key in "${!CONFIG[@]}"; do
        [[ "$cfg_key" == env.* ]] || continue
        env_entries["${cfg_key#env.}"]="${CONFIG[$cfg_key]}"
    done
    if [[ $DRY_RUN -eq 0 ]]; then
        local rendered
        for env_key in "${!env_entries[@]}"; do
            rendered="$(render_env_refs "${env_entries[$env_key]}" "$env_refs_file")"
            rendered="$(render_template "$rendered" ctx)"
            update_env_key "$env_file" "$env_key" "$rendered"
        done
        [[ ${#env_entries[@]} -gt 0 ]] && info "updated .env"
    else
        local rendered
        for env_key in "${!env_entries[@]}"; do
            rendered="$(render_env_refs "${env_entries[$env_key]}" "$env_refs_file")"
            rendered="$(render_template "$rendered" ctx)"
            echo "[dry-run] env: $env_key=$rendered"
        done
    fi

    # Register branch state (single source of truth for destroy/exec).
    state_put "$registry_file" "$branch" "$offset" "$db_name" "$DRY_RUN"

    # Lifecycle hooks.
    run_hooks create ctx
    if [[ $DRY_RUN -eq 1 ]]; then
        run_hooks destroy ctx
    fi

    # Report: reflect what actually happened; only the ports the project
    # actually declared exist as far as the core is concerned.
    local -a straps=()
    declared_straps straps

    echo ""
    echo "── wtbs report ─────────────────────────────"
    echo "  branch .............. $branch"
    echo "  db name ............. $db_name"
    echo "  straps .............. ${straps[*]:-<none>}"
    if [[ ${#ports[@]} -gt 0 ]]; then
        local pkey
        while IFS= read -r pkey; do
            printf '  %s %s\n' "$(printf '%-20s' "ports.$pkey" | tr ' ' '.')" "${ports[$pkey]}"
        done < <(printf '%s\n' "${!ports[@]}" | sort)
    else
        echo "  ports ............... <none declared>"
    fi
    echo "──────────────────────────────────────────────────────────"
}

cmd_create() {
    local branch="$1"
    local main_root worktree_path
    main_root="$(resolve_main_root "$MAIN_ROOT_OVERRIDE")"
    if [[ -n "$DIR_OVERRIDE" ]]; then
        case "$DIR_OVERRIDE" in
            /*|*..*|*/*) fatal "--dir must be a plain directory name (no slashes, no '..'): $DIR_OVERRIDE" ;;
        esac
        worktree_path="$(dirname "$main_root")/$DIR_OVERRIDE"
    else
        worktree_path="$(default_worktree_path "$main_root" "$branch")"
    fi

    # Validate the config (legacy keys, unknown straps) before creating
    # anything; cmd_bootstrap loads it again for the real run.
    load_project_config "$main_root" "$worktree_path"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] would create worktree $worktree_path for branch $branch"
        if ! git -C "$main_root" show-ref --verify --quiet "refs/heads/$branch"; then
            echo "[dry-run] branch '$branch' does not exist; would create from ${BASE_REF:-HEAD}"
        fi
        # Render the full bootstrap plan without creating anything.
        WORKTREE_ROOT_OVERRIDE="$worktree_path"
        BRANCH_OVERRIDE="$branch"
        cmd_bootstrap
        return 0
    fi

    create_worktree "$branch" "$worktree_path" "$BASE_REF"

    (
        cd "$worktree_path"
        cmd_bootstrap
    )
}

cmd_destroy() {
    local target="$1"
    local main_root worktree_path branch branch_slug offset db_name
    main_root="$(resolve_main_root "$MAIN_ROOT_OVERRIDE")"

    # Resolve path from branch name if needed. The registered-worktree lookup
    # (which knows about custom --dir names) wins over the naming convention,
    # but never resolves to the main repo itself.
    if [[ -d "$target" ]]; then
        worktree_path="$target"
    else
        worktree_path="$(_worktree_path_for_branch "$target")"
        if [[ -z "$worktree_path" || "$worktree_path" == "$main_root" ]]; then
            worktree_path="$(default_worktree_path "$main_root" "$target")"
        fi
    fi

    branch="$(cd "$worktree_path" && git rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch="unknown"
    branch_slug="$(slugify "$branch")"

    load_project_config "$main_root" "$worktree_path"

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

    local site
    site="$(basename "$worktree_path" | tr '[:upper:]' '[:lower:]')"
    local -A ctx
    build_context ctx "$branch" "$branch_slug" "$site" "$db_name" "$worktree_path" "$main_root" ports

    # Destroy hooks run before teardown. Hook failures abort teardown, so
    # best-effort commands should end with `|| true`.
    run_hooks destroy ctx

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] would destroy $worktree_path and unregister branch $branch"
        if [[ $DELETE_BRANCH -eq 1 && "$branch" != "unknown" ]]; then
            echo "[dry-run] would delete branch $branch"
        fi
        return 0
    fi

    state_delete "$registry_file" "$branch"
    remove_worktree "$worktree_path"
    # Prune immediately so the branch is deletable right away.
    git -C "$main_root" worktree prune
    if [[ $DELETE_BRANCH -eq 1 && "$branch" != "unknown" ]]; then
        git -C "$main_root" branch -D "$branch" 2>/dev/null \
            || warn "could not delete branch $branch (checked out elsewhere?)"
    fi
}
