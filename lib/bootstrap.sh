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
NO_PUBLISH=0
WORKTREE_ROOT_OVERRIDE=""
BRANCH_OVERRIDE=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --delete-branch) DELETE_BRANCH=1 ;;
            --no-publish) NO_PUBLISH=1 ;;
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
    apply_defaults
    # Straps are NOT merged into this config (docs/adr/0002): activation
    # refs are read separately via declared_straps.
}

# Build the template context associative array. Core tokens: branch,
# branch_slug, site, db_name, worktree_root, main_repo. Strap-published
# tokens are loaded on top by load_state_into_ctx.
build_context() {
    local -n ctx_out="$1"
    local branch="$2" branch_slug="$3" site="$4" db_name="$5"
    local worktree_root="$6" main_root="$7"

    ctx_out[branch]="$branch"
    ctx_out[branch_slug]="$branch_slug"
    ctx_out[site]="$site"
    ctx_out[db_name]="$db_name"
    ctx_out[worktree_root]="$worktree_root"
    ctx_out[main_repo]="$main_root"
}

# Export the template context as WTBS_* env vars: every context key becomes
# WTBS_<KEY uppercased, non-alphanumerics -> _> (state tokens like
# auto_ports.serve become WTBS_AUTO_PORTS_SERVE). Used by hooks, exec
# presets, and strap scripts.
export_context_vars() {
    local -n ctx_ref="$1"
    local key pname
    for key in "${!ctx_ref[@]}"; do
        pname="WTBS_$(echo "$key" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9]+/_/g')"
        export "${pname}=${ctx_ref[$key]}"
    done
}

# Run the project's own hooks for a lifecycle step ("create" or "destroy"),
# rendered with the full template context plus {env.KEY} references. Strap
# lifecycle scripts have already run (run_strap_lifecycles). Hooks run with
# the worktree as cwd, active strap dirs on PATH, the MAIN repo's .env
# exported (the source of truth — e.g. DB credentials are the clone SOURCE),
# the context exported as WTBS_*, and WTBS_STATE_FILE pointing at this
# branch's wtbs-owned state file.
run_hooks() {
    local step="$1" ctx_name="$2"
    local -n hook_ctx="$ctx_name"
    local -a cmds=()
    config_list "hooks.$step" cmds
    [[ ${#cmds[@]} -gt 0 ]] || return 0

    local main_env="${hook_ctx[main_repo]}/.env"
    local strap_path
    strap_path="$(strap_path_prefix "${hook_ctx[worktree_root]}" "${hook_ctx[main_repo]}")"
    local state_file
    state_file="$(state_file_path "${hook_ctx[main_repo]}" "${hook_ctx[branch_slug]}")"
    local -a refs=()
    declared_straps refs

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
                export WTBS_STATE_FILE="$state_file"
                export WTBS_LIB_DIR="$LIB_DIR"
                export_user_settings
                export_strap_args ${refs[@]+"${refs[@]}"}
                # WARNING: hooks come from the project config and are
                # executed as-is. Only run this tool against repositories
                # whose bootstrap config you trust.
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
    local main_root worktree_root branch branch_slug db_name
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

    db_name="$(compute_db_name "$branch" "$branch_slug")"

    echo "── wtbs preflight ──────────────────────────"
    echo "  worktree : $worktree_root"
    echo "  main repo: $main_root"
    echo "  branch   : $branch"
    echo "  db name  : $db_name"

    # Template context: core tokens + strap-published tokens from previous
    # runs (hook commands may use them, e.g. {auto_ports.serve}).
    local site
    site="$(basename "$worktree_root" | tr '[:upper:]' '[:lower:]')"
    local -A ctx
    build_context ctx "$branch" "$branch_slug" "$site" "$db_name" "$worktree_root" "$main_root"
    load_state_into_ctx "$(state_file_path "$main_root" "$branch_slug")" ctx

    # Fail fast on missing hook scripts before changing anything. When the
    # worktree does not exist yet (create --dry-run), warn against the main
    # repo instead.
    if [[ -n "$WORKTREE_ROOT_OVERRIDE" ]]; then
        preflight_hook_scripts ctx "$main_root" warn
    else
        preflight_hook_scripts ctx "$worktree_root" fail
    fi

    # Publish on activation: bundled straps the project activated become
    # project-owned copies; the project env strap is scaffolded when absent.
    publish_straps ctx

    # Mirror the untracked residue (docs/adr/0008): everything git did not
    # check out (.env and friends), minus copy.ignore / .wtbsignore rules.
    # Seed-only — files the worktree already has are never overwritten.
    local -a ignores=()
    config_list copy.ignore ignores
    if [[ -f "$main_root/.wtbsignore" ]]; then
        local wl
        while IFS= read -r wl || [[ -n "$wl" ]]; do
            [[ "$wl" =~ ^[[:space:]]*# ]] && continue
            [[ "$wl" =~ ^[[:space:]]*$ ]] && continue
            ignores+=("$wl")
        done < "$main_root/.wtbsignore"
    fi
    if [[ $DRY_RUN -eq 0 ]]; then
        local copy_stats
        copy_stats="$(copy_residue "$main_root" "$worktree_root" ${ignores[@]+"${ignores[@]}"})"
        info "mirrored untracked residue ($copy_stats; ignore rules: ${#ignores[@]})"
    else
        local -a residue=()
        mapfile -t residue < <(residue_list "$main_root" ${ignores[@]+"${ignores[@]}"})
        echo "[dry-run] would mirror ${#residue[@]} untracked file(s) from main repo (seed-only; ignore rules: ${#ignores[@]})"
    fi

    # Straps compute and write (docs/adr/0007): allocate, clone, secure —
    # and write their own .env lines via wtbs_env_set. Then the project
    # env strap maps strap state to the project's own key names.
    run_strap_lifecycles create ctx
    run_env_strap create ctx
    # Hook commands may use strap tokens ({auto_ports.serve}); reload the
    # freshly published state into the render context.
    load_state_into_ctx "$(state_file_path "$main_root" "$branch_slug")" ctx

    # Register branch state (single source of truth for destroy/exec).
    local registry_file
    registry_file="$(registry_path "$main_root")"
    state_put "$registry_file" "$branch" "$db_name" "$DRY_RUN"

    # Project lifecycle hooks (strap lifecycles already ran above).
    run_hooks create ctx
    if [[ $DRY_RUN -eq 1 ]]; then
        run_strap_lifecycles destroy ctx
        run_env_strap destroy ctx
        run_hooks destroy ctx
    fi

    # Report: reflect what actually happened.
    local -a straps=()
    declared_straps straps

    echo ""
    echo "── wtbs report ─────────────────────────────"
    echo "  branch .............. $branch"
    echo "  db name ............. $db_name"
    echo "  straps .............. ${straps[*]:-<none>}"
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
    resolved_straps "$worktree_path" "$main_root" >/dev/null

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
    local main_root worktree_path branch branch_slug db_name
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
    db_name="$(state_get "$registry_file" "$branch" db)"
    [[ -z "$db_name" ]] && db_name="$(compute_db_name "$branch" "$branch_slug")"

    local site
    site="$(basename "$worktree_path" | tr '[:upper:]' '[:lower:]')"
    local -A ctx
    build_context ctx "$branch" "$branch_slug" "$site" "$db_name" "$worktree_path" "$main_root"
    load_state_into_ctx "$(state_file_path "$main_root" "$branch_slug")" ctx

    # Strap destroy lifecycles, then the project env strap, then project
    # destroy hooks — all before teardown. Failures abort teardown, so
    # best-effort commands should end with `|| true`.
    run_strap_lifecycles destroy ctx
    run_env_strap destroy ctx
    run_hooks destroy ctx

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] would destroy $worktree_path and unregister branch $branch"
        if [[ $DELETE_BRANCH -eq 1 && "$branch" != "unknown" ]]; then
            echo "[dry-run] would delete branch $branch"
        fi
        return 0
    fi

    state_delete "$registry_file" "$branch"
    rm -f "$(state_file_path "$main_root" "$branch_slug")"
    rmdir "$main_root/.wtbs/worktrees" 2>/dev/null || true
    remove_worktree "$worktree_path"
    # Prune immediately so the branch is deletable right away.
    git -C "$main_root" worktree prune
    if [[ $DELETE_BRANCH -eq 1 && "$branch" != "unknown" ]]; then
        git -C "$main_root" branch -D "$branch" 2>/dev/null \
            || warn "could not delete branch $branch (checked out elsewhere?)"
    fi
}
