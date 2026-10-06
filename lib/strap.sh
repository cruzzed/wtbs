#!/usr/bin/env bash
set -euo pipefail

# Straps: self-contained bundles of policy (docs/adr/0002). A strap is a
# directory of scripts plus its own private config (strap.yml, read by the
# strap itself — the core never parses it). The complete core↔strap
# interface:
#
#   1. Activation, with optional parameters:
#        straps: [valet, "auto-ports(serve:8000;db:33060)"]
#      The core parses the bare name for resolution/PATH/lifecycle and
#      exports the args verbatim as WTBS_STRAP_ARGS_<NAME>. Arg semantics
#      are the strap's private schema.
#   2. Verbs: executable files in the strap dir, reachable through exec's
#      raw-command tier (`wtbs <branch> share`).
#   3. Lifecycle scripts: <strap>/create and <strap>/destroy, invoked with
#      the hook environment; strap lifecycles run before the project's own
#      hooks.* (strap-then-project ordering).
#   4. Publish/consume: straps write namespaced keys to the per-branch
#      state file; the core loads them as template tokens.
#
# Resolution is local-first: worktree .wtbs/straps/<name> shadows the main
# repo's, which shadows the bundled straps/<name> shipped with the tool.
# WTBS_STRAPS_DIR overrides the bundled dir (mainly for tests).

STRAPS_BUNDLED_DIR="${WTBS_STRAPS_DIR:-${LIB_DIR}/../straps}"

# Split an activation ref into bare name + args: "auto-ports(a;b)" sets
# REF_NAME=auto-ports, REF_ARGS="a;b". A plain name leaves REF_ARGS empty.
parse_strap_ref() {
    local ref="$1"
    REF_NAME="$ref"
    REF_ARGS=""
    if [[ "$ref" == *"("* ]]; then
        REF_NAME="${ref%%\(*}"
        REF_ARGS="${ref#*\(}"
        REF_ARGS="${REF_ARGS%\)*}"
    fi
    case "$REF_NAME" in
        *..*|*/*|"") fatal "invalid strap name: '$ref'" ;;
    esac
}

# Export WTBS_STRAP_ARGS_<NAME> for every declared activation ref.
export_strap_args() {
    local ref name args env_name
    for ref in "$@"; do
        parse_strap_ref "$ref"
        env_name="WTBS_STRAP_ARGS_$(echo "$REF_NAME" | tr '[:lower:]-' '[:upper:]_' | sed -E 's/[^A-Z0-9_]+/_/g')"
        export "${env_name}=${REF_ARGS}"
    done
}

# Export activation args for the straps declared in the currently loaded
# config (used by exec, where config is loaded in-process).
export_strap_args_env_for() {
    local -a refs=()
    declared_straps refs
    export_strap_args ${refs[@]+"${refs[@]}"}
}

# Echo the resolved directory for a strap name, or nothing when not found.
resolve_strap() {
    local name="$1" worktree_root="$2" main_root="$3"
    case "$name" in
        *..*|*/*|"")
            fatal "invalid strap name: '$name'" ;;
    esac
    if [[ -n "$worktree_root" && -d "$worktree_root/.wtbs/straps/$name" ]]; then
        echo "$worktree_root/.wtbs/straps/$name"
    elif [[ -d "$main_root/.wtbs/straps/$name" ]]; then
        echo "$main_root/.wtbs/straps/$name"
    elif [[ -d "$STRAPS_BUNDLED_DIR/$name" ]]; then
        echo "$STRAPS_BUNDLED_DIR/$name"
    fi
}

# List the raw activation refs (names with optional args) from the config.
declared_straps() {
    local -n out_ref="$1"
    config_list straps out_ref
}

# List resolved strap dirs for every declared ref (echoes "name<TAB>dir").
resolved_straps() {
    local worktree_root="$1" main_root="$2"
    local -a refs=()
    declared_straps refs
    local ref
    for ref in ${refs[@]+"${refs[@]}"}; do
        local name dir
        parse_strap_ref "$ref"
        name="$REF_NAME"
        dir="$(resolve_strap "$name" "$worktree_root" "$main_root")"
        [[ -n "$dir" ]] || fatal "strap not found: '$name' (looked in worktree/main .wtbs/straps/ and bundled straps/)"
        printf '%s\t%s\n' "$name" "$dir"
    done
}

# Colon-joined directories of every active strap, for prepending to PATH.
strap_path_prefix() {
    local worktree_root="$1" main_root="$2"
    local prefix="" entry name dir
    while IFS=$'\t' read -r name dir; do
        [[ -n "$dir" ]] || continue
        prefix="${prefix:+$prefix:}$dir"
    done < <(resolved_straps "$worktree_root" "$main_root")
    echo "$prefix"
}

# Run a single strap script (lifecycle or project env strap) in the
# standard strap subshell: worktree as cwd, active strap dirs on PATH, the
# MAIN repo's .env exported (source of truth for clone credentials), the
# context as WTBS_*, WTBS_STATE_FILE, WTBS_LIB_DIR (strap-lib.sh), user
# settings, and activation args.
_run_strap_script() {
    local script="$1" name="$2" ctx_name="$3"
    local -n rss_ctx="$ctx_name"

    local main_env="${rss_ctx[main_repo]}/.env"
    local strap_path
    strap_path="$(strap_path_prefix "${rss_ctx[worktree_root]}" "${rss_ctx[main_repo]}")"
    local state_file
    state_file="$(state_file_path "${rss_ctx[main_repo]}" "${rss_ctx[branch_slug]}")"
    local -a refs=()
    declared_straps refs

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] would run strap '$name' $(basename "$script"): $script"
        return 0
    fi
    info "running strap '$name' $(basename "$script"): $script"
    (
        cd "${rss_ctx[worktree_root]}"
        [[ -n "$strap_path" ]] && export PATH="$strap_path:$PATH"
        export_env_file "$main_env"
        export_context_vars "$ctx_name"
        export WTBS_STATE_FILE="$state_file"
        export WTBS_LIB_DIR="$LIB_DIR"
        export_user_settings
        export_strap_args ${refs[@]+"${refs[@]}"}
        # WARNING: strap lifecycle scripts are project files executed
        # as-is. Only run them for repositories you trust.
        bash "$script"
    ) || fatal "strap '$name' $(basename "$script") failed: $script"
}

# Run the <strap>/create or <strap>/destroy lifecycle of every active
# strap, in declared order. Project hooks run after this
# (strap-then-project).
run_strap_lifecycles() {
    local step="$1" ctx_name="$2"
    local -n sl_ctx="$ctx_name"
    local entry name dir
    while IFS=$'\t' read -r name dir; do
        [[ -n "$dir" ]] || continue
        local script="$dir/$step"
        [[ -f "$script" ]] || continue
        _run_strap_script "$script" "$name" "$ctx_name"
    done < <(resolved_straps "${sl_ctx[worktree_root]}" "${sl_ctx[main_repo]}")
}

# The project env strap (<main-repo>/.wtbs/straps/env) is the project's
# voice for its own .env keys (docs/adr/0007). It is not declared in the
# config; the core runs its lifecycles after all declared straps'
# lifecycles so every strap state key is already published.
run_env_strap() {
    local step="$1" ctx_name="$2"
    local -n es_ctx="$ctx_name"
    local script="${es_ctx[main_repo]}/.wtbs/straps/env/$step"
    [[ -f "$script" ]] || return 0
    _run_strap_script "$script" "env" "$ctx_name"
}

# Write a fresh project env strap scaffold (see run_env_strap).
scaffold_env_strap() {
    local dest="$1"
    mkdir -p "$dest"
    cat > "$dest/create" <<'EOF'
#!/usr/bin/env bash
# Project env strap — the project's voice for its own .env keys
# (docs/adr/0007). Runs after every declared strap's create lifecycle, so
# all strap state is published and readable via wtbs_state_get. Uncomment
# and adapt; nothing here runs until it says something.
set -euo pipefail
source "${WTBS_LIB_DIR:?run inside wtbs}/strap-lib.sh"

# Point the project at auto-ports' allocated ports:
# wtbs_env_set DB_PORT "$(wtbs_state_get auto_ports.db)"
#
# Surface valet's served URL to the app under a boot-owned key
# (never APP_URL — the project owns that):
# wtbs_env_set WTBS_VALET_URL "$(wtbs_state_get valet.url)"
EOF
    chmod +x "$dest/create"
    cat > "$dest/destroy" <<'EOF'
#!/usr/bin/env bash
# Runs at the destroy lifecycle moment, before the worktree is removed.
# Nothing to undo by default: the worktree (and its .env) is deleted whole.
set -euo pipefail
EOF
    chmod +x "$dest/destroy"
}

# Publish on activation (docs/adr/0007): copy each activated strap that
# resolved to the bundled dir into the project's .wtbs/straps/ so the
# project owns its copies, and scaffold the project env strap when absent.
# Skipped with --no-publish or `publish: false`. Local-first resolution
# picks up the copies for the rest of the run.
publish_straps() {
    local ctx_name="$1"
    local -n ps_ctx="$ctx_name"
    local main_root="${ps_ctx[main_repo]}"

    local -a refs=()
    declared_straps refs
    [[ ${#refs[@]} -gt 0 ]] || return 0

    if [[ "${NO_PUBLISH:-0}" == "1" || "$(get_config publish)" == "false" ]]; then
        info "strap publishing disabled (--no-publish or publish: false)"
        return 0
    fi

    local name dir dest
    while IFS=$'\t' read -r name dir; do
        [[ -n "$dir" ]] || continue
        # Only bundled straps get published; local copies are already owned.
        [[ "$dir" == "$STRAPS_BUNDLED_DIR/$name" ]] || continue
        dest="$main_root/.wtbs/straps/$name"
        if [[ -e "$dest" ]]; then
            continue
        elif [[ $DRY_RUN -eq 1 ]]; then
            echo "[dry-run] would publish strap '$name' -> $dest"
        else
            mkdir -p "$(dirname "$dest")"
            cp -R "$dir" "$dest"
            info "published strap '$name' -> $dest"
        fi
    done < <(resolved_straps "${ps_ctx[worktree_root]}" "$main_root")

    local env_strap="$main_root/.wtbs/straps/env"
    if [[ ! -e "$env_strap" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "[dry-run] would scaffold project env strap -> $env_strap"
        else
            scaffold_env_strap "$env_strap"
            info "scaffolded project env strap -> $env_strap"
        fi
    fi
}

cmd_straps() {
    local main_root
    main_root="$(resolve_main_root "$MAIN_ROOT_OVERRIDE")"
    local worktree_root=""
    if [[ "$(pwd)" != "$main_root" ]]; then
        worktree_root="$(pwd)"
    fi
    load_project_config "$main_root" "$worktree_root"

    local -A active=()
    local -a refs=()
    declared_straps refs
    local r
    for r in ${refs[@]+"${refs[@]}"}; do
        parse_strap_ref "$r"
        active["$REF_NAME"]="($REF_ARGS)"
    done

    # First tier containing a strap wins resolution; later tiers are shadowed.
    local -A resolved_in=() shadowed_in=()
    local -a tiers=()
    [[ -n "$worktree_root" ]] && tiers+=("worktree:$worktree_root/.wtbs/straps")
    tiers+=("main repo:$main_root/.wtbs/straps" "bundled:$STRAPS_BUNDLED_DIR")
    local tier label dir s n
    for tier in ${tiers[@]+"${tiers[@]}"}; do
        label="${tier%%:*}"
        dir="${tier#*:}"
        [[ -d "$dir" ]] || continue
        for s in "$dir"/*; do
            [[ -d "$s" ]] || continue
            n="$(basename "$s")"
            if [[ -z "${resolved_in[$n]:-}" ]]; then
                resolved_in["$n"]="$label"
            else
                shadowed_in["$n"]+="${shadowed_in[$n]:+, }$label"
            fi
        done
    done

    if [[ ${#resolved_in[@]} -eq 0 ]]; then
        echo "no straps found (bundled dir: $STRAPS_BUNDLED_DIR)"
        return 0
    fi
    echo "straps (resolution: worktree > main repo > bundled):"
    while IFS= read -r n; do
        local mark=" " note="${resolved_in[$n]}"
        [[ -n "${active[$n]:-}" ]] && mark="*"
        [[ -n "${shadowed_in[$n]:-}" ]] && note+=" (shadows ${shadowed_in[$n]})"
        printf '  %s %-16s %s\n' "$mark" "$n" "$note"
    done < <(printf '%s\n' "${!resolved_in[@]}" | sort)
    [[ ${#active[@]} -gt 0 ]] && echo "(* = active in .wtbs.yml)"
}

cmd_strap_customize() {
    local ref="$1"
    parse_strap_ref "$ref"
    local name="$REF_NAME"
    local main_root
    main_root="$(resolve_main_root "$MAIN_ROOT_OVERRIDE")"
    local src="$STRAPS_BUNDLED_DIR/$name"
    local dest="$main_root/.wtbs/straps/$name"
    [[ -d "$src" ]] || fatal "no bundled strap named '$name' (run: wtbs straps)"
    [[ ! -e "$dest" ]] || fatal "already exists: $dest — edit it directly"
    mkdir -p "$(dirname "$dest")"
    cp -R "$src" "$dest"
    info "copied bundled strap '$name' -> $dest"
    info "this local copy now shadows the bundled one; edit scripts and strap.yml to taste"
}

cmd_strap_init() {
    local name="$1"
    case "$name" in
        *..*|*/*|"") fatal "invalid strap name: '$name'" ;;
    esac
    local main_root
    main_root="$(resolve_main_root "$MAIN_ROOT_OVERRIDE")"
    local dest="$main_root/.wtbs/straps/$name"
    [[ ! -e "$dest" ]] || fatal "already exists: $dest"
    mkdir -p "$dest"
    cat > "$dest/create" <<'EOF'
#!/usr/bin/env bash
# Runs at the create lifecycle moment, before the project's hooks.create,
# with the worktree as cwd and the context exported: WTBS_BRANCH,
# WTBS_BRANCH_SLUG, WTBS_SITE, WTBS_DB_NAME, WTBS_WORKTREE_ROOT,
# WTBS_MAIN_REPO, WTBS_STATE_FILE (per-branch state file), WTBS_LIB_DIR
# (source $WTBS_LIB_DIR/strap-lib.sh for wtbs_env_set / wtbs_state_set /
# wtbs_state_get), plus any WTBS_STRAP_ARGS_<NAME> activation params and
# user settings.
set -euo pipefail
EOF
    chmod +x "$dest/create"
    cat > "$dest/destroy" <<'EOF'
#!/usr/bin/env bash
# Runs at the destroy lifecycle moment, before the project's hooks.destroy
# and before the worktree is removed. Same environment as create.
set -euo pipefail
EOF
    chmod +x "$dest/destroy"
    cat > "$dest/strap.yml" <<'EOF'
# Private strap config — read by the strap's own scripts (next to them via
# BASH_SOURCE), never by the core. Holds project-level policy when this
# strap is customized into a project; wins over user settings.
EOF
    info "created $dest/ (create, destroy, strap.yml)"
    info "activate with: straps: [$name] in .wtbs.yml — add executable files for verbs"
}
