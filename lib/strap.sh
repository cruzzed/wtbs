#!/usr/bin/env bash
set -euo pipefail

# Straps: named, opt-in bundles of policy. A strap is a directory containing
# a strap.yml config fragment plus optional scripts. Activating a strap
# merges its fragment into the project config (the project always wins) and
# puts the strap's directory on PATH during hooks and exec.
#
# Resolution is local-first: worktree .wtbs/straps/<name> shadows the main
# repo's, which shadows the bundled straps/<name> shipped with the tool.
# WTBS_STRAPS_DIR overrides the bundled dir (mainly for tests).

STRAPS_BUNDLED_DIR="${WTBS_STRAPS_DIR:-${LIB_DIR}/../straps}"

# Keys a strap fragment may not define.
_reject_strap_fragment_key() {
    local key="$1" strap_name="$2"
    case "$key" in
        straps|straps\[*)
            fatal "strap '$strap_name' may not declare straps itself (no nesting)" ;;
    esac
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

# List the strap names declared in the project config into the named array.
declared_straps() {
    local -n out_ref="$1"
    config_list straps out_ref
}

# Merge every declared strap's strap.yml into CONFIG.
#
# Merge rule: scalar/map keys merge with the project config winning; between
# straps, the later-declared strap wins. Lists (copy, hooks.create,
# hooks.destroy) concatenate strap-then-project, in declared order.
merge_straps() {
    local worktree_root="$1" main_root="$2"

    local -a names=()
    declared_straps names
    [[ ${#names[@]} -gt 0 ]] || return 0

    # Snapshot which keys the project itself defined; these are untouchable.
    local -A project_keys=()
    local k
    for k in "${!CONFIG[@]}"; do
        project_keys["$k"]=1
    done

    # Project list items are appended after all strap items.
    local -a project_copy=() project_create=() project_destroy=()
    config_list copy project_copy
    config_list hooks.create project_create
    config_list hooks.destroy project_destroy
    local -a merged_copy=() merged_create=() merged_destroy=()

    local name dir
    for name in "${names[@]}"; do
        dir="$(resolve_strap "$name" "$worktree_root" "$main_root")"
        [[ -n "$dir" ]] || fatal "strap not found: '$name' (looked in worktree/main .wtbs/straps/ and bundled straps/)"
        [[ -f "$dir/strap.yml" ]] || fatal "strap '$name' has no strap.yml in $dir"

        local -A frag=()
        _yaml_to_assoc "$dir/strap.yml" frag

        local key
        for key in "${!frag[@]}"; do
            _reject_strap_fragment_key "$key" "$name"
            case "$key" in
                copy\[*) ;;
                hooks.create\[*) ;;
                hooks.destroy\[*) ;;
                *)
                    # Scalar/map key: project wins; later strap beats earlier.
                    if [[ -z "${project_keys[$key]:-}" ]]; then
                        CONFIG["$key"]="${frag[$key]}"
                    fi
                    ;;
            esac
        done

        # Re-collect the fragment's list items in index order.
        local i val
        i=0
        while true; do
            val="${frag["copy[${i}]"]:-}"
            [[ -z "$val" ]] && break
            merged_copy+=("$val")
            i=$((i + 1))
        done
        i=0
        while true; do
            val="${frag["hooks.create[${i}]"]:-}"
            [[ -z "$val" ]] && break
            merged_create+=("$val")
            i=$((i + 1))
        done
        i=0
        while true; do
            val="${frag["hooks.destroy[${i}]"]:-}"
            [[ -z "$val" ]] && break
            merged_destroy+=("$val")
            i=$((i + 1))
        done
    done

    merged_copy+=(${project_copy[@]+"${project_copy[@]}"})
    merged_create+=(${project_create[@]+"${project_create[@]}"})
    merged_destroy+=(${project_destroy[@]+"${project_destroy[@]}"})

    # Write merged lists back, replacing whatever was there.
    local i
    for k in "${!CONFIG[@]}"; do
        case "$k" in
            copy\[*|hooks.create\[*|hooks.destroy\[*) unset 'CONFIG[$k]' ;;
        esac
    done
    for i in "${!merged_copy[@]}"; do CONFIG["copy[${i}]"]="${merged_copy[$i]}"; done
    for i in "${!merged_create[@]}"; do CONFIG["hooks.create[${i}]"]="${merged_create[$i]}"; done
    for i in "${!merged_destroy[@]}"; do CONFIG["hooks.destroy[${i}]"]="${merged_destroy[$i]}"; done
}

# Colon-joined directories of every active strap, for prepending to PATH.
strap_path_prefix() {
    local worktree_root="$1" main_root="$2"
    local -a names=()
    declared_straps names
    local prefix="" name dir
    for name in ${names[@]+"${names[@]}"}; do
        dir="$(resolve_strap "$name" "$worktree_root" "$main_root")"
        [[ -n "$dir" ]] || continue
        prefix="${prefix:+$prefix:}$dir"
    done
    echo "$prefix"
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
    local -a names=()
    declared_straps names
    local n
    for n in ${names[@]+"${names[@]}"}; do active["$n"]=1; done

    # First tier containing a strap wins resolution; later tiers are shadowed.
    local -A resolved_in=() shadowed_in=()
    local -a tiers=()
    [[ -n "$worktree_root" ]] && tiers+=("worktree:$worktree_root/.wtbs/straps")
    tiers+=("main repo:$main_root/.wtbs/straps" "bundled:$STRAPS_BUNDLED_DIR")
    local tier label dir s
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
    local name="$1"
    local main_root
    main_root="$(resolve_main_root "$MAIN_ROOT_OVERRIDE")"
    local src="$STRAPS_BUNDLED_DIR/$name"
    local dest="$main_root/.wtbs/straps/$name"
    [[ -d "$src" ]] || fatal "no bundled strap named '$name' (run: wtbs straps)"
    [[ ! -e "$dest" ]] || fatal "already exists: $dest — edit it directly"
    mkdir -p "$(dirname "$dest")"
    cp -R "$src" "$dest"
    info "copied bundled strap '$name' -> $dest"
    info "this local copy now shadows the bundled one; edit strap.yml and scripts to taste"
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
    cat > "$dest/strap.yml" <<'EOF'
# A strap is a config fragment merged into .wtbs.yml (the
# project config always wins) plus optional scripts in this directory, which
# is prepended to PATH during hooks and exec.
#
# ports: {db: 33060}
# env:
#   DB_DATABASE: "{db_name}"
# hooks:
#   create:
#     - "my-setup-script {db_name}"
#   destroy:
#     - "my-teardown-script {db_name} || true"
# aliases:
#   mycommand: "my-setup-script status"
EOF
    info "created $dest/strap.yml"
    info "activate with: straps: [$name] in .wtbs.yml"
}
