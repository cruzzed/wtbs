#!/usr/bin/env bats

setup() {
    export LIB_DIR="$BATS_TEST_DIRNAME/../../lib"
    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/env.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/strap.sh"

    export TMP_MAIN="$(mktemp -d)"
    export TMP_WT="$(mktemp -d)"
    # Hermetic bundled dir, so tests never touch the repo's real straps/.
    export STRAPS_BUNDLED_DIR="$(mktemp -d)"

    mkdir -p "$STRAPS_BUNDLED_DIR/alpha"
    cat > "$STRAPS_BUNDLED_DIR/alpha/strap.yml" <<'EOF'
ports:
  app: 8080
env:
  APP_PORT: "{ports.app}"
  FROM_STRAP: alpha
hooks:
  create:
    - "alpha-setup {branch_slug}"
aliases:
  alpha-cmd: "echo alpha"
EOF
    echo '#!/usr/bin/env bash' > "$STRAPS_BUNDLED_DIR/alpha/alpha-bin"

    mkdir -p "$STRAPS_BUNDLED_DIR/beta"
    cat > "$STRAPS_BUNDLED_DIR/beta/strap.yml" <<'EOF'
ports:
  app: 9999
  db: 33060
hooks:
  create:
    - "beta-setup"
  destroy:
    - "beta-teardown || true"
EOF
}

teardown() {
    rm -rf "$TMP_MAIN" "$TMP_WT" "$STRAPS_BUNDLED_DIR"
}

declare_with() {
    CONFIG=()
    local i=0 s
    for s in "$@"; do
        CONFIG["straps[$i]"]="$s"
        i=$((i + 1))
    done
}

@test "strap fragment merges ports, env, hooks and aliases into empty config" {
    declare_with alpha
    merge_straps "$TMP_WT" "$TMP_MAIN"
    [[ "$(get_config ports.app)" == "8080" ]]
    [[ "$(get_config env.FROM_STRAP)" == "alpha" ]]
    [[ "$(get_config hooks.create[0])" == 'alpha-setup {branch_slug}' ]]
    [[ "$(get_config aliases.alpha-cmd)" == "echo alpha" ]]
}

@test "project config wins over strap scalars and map entries" {
    declare_with alpha
    CONFIG["ports.app"]="1234"
    CONFIG["env.FROM_STRAP"]="project"
    merge_straps "$TMP_WT" "$TMP_MAIN"
    [[ "$(get_config ports.app)" == "1234" ]]
    [[ "$(get_config env.FROM_STRAP)" == "project" ]]
    # Untouched strap keys still merge.
    [[ "$(get_config env.APP_PORT)" == '{ports.app}' ]]
}

@test "later-declared strap wins over earlier for scalars" {
    declare_with alpha beta
    merge_straps "$TMP_WT" "$TMP_MAIN"
    [[ "$(get_config ports.app)" == "9999" ]]
    [[ "$(get_config ports.db)" == "33060" ]]
}

@test "hook lists concatenate straps in declared order, then the project" {
    declare_with alpha beta
    CONFIG["hooks.create[0]"]="project-setup"
    merge_straps "$TMP_WT" "$TMP_MAIN"
    [[ "$(get_config hooks.create[0])" == 'alpha-setup {branch_slug}' ]]
    [[ "$(get_config hooks.create[1])" == "beta-setup" ]]
    [[ "$(get_config hooks.create[2])" == "project-setup" ]]
    [[ "$(get_config hooks.destroy[0])" == 'beta-teardown || true' ]]
}

@test "resolve_strap prefers worktree over main over bundled" {
    mkdir -p "$TMP_MAIN/.wtbs/straps/alpha" "$TMP_WT/.wtbs/straps/alpha"
    [[ "$(resolve_strap alpha "$TMP_WT" "$TMP_MAIN")" == "$TMP_WT/.wtbs/straps/alpha" ]]
    [[ "$(resolve_strap alpha "" "$TMP_MAIN")" == "$TMP_MAIN/.wtbs/straps/alpha" ]]
    [[ "$(resolve_strap alpha "" "$TMP_MAIN/nope")" == "$STRAPS_BUNDLED_DIR/alpha" ]]
    [[ -z "$(resolve_strap gamma "" "$TMP_MAIN")" ]]
}

@test "merge_straps fatals on an unknown strap" {
    declare_with gamma
    run merge_straps "$TMP_WT" "$TMP_MAIN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"strap not found: 'gamma'"* ]]
}

@test "strap fragments may not declare straps themselves" {
    mkdir -p "$STRAPS_BUNDLED_DIR/evil"
    cat > "$STRAPS_BUNDLED_DIR/evil/strap.yml" <<'EOF'
straps:
  - alpha
EOF
    declare_with evil
    run merge_straps "$TMP_WT" "$TMP_MAIN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"may not declare straps"* ]]
}

@test "strap_path_prefix lists resolved strap dirs" {
    declare_with alpha beta
    local prefix
    prefix="$(strap_path_prefix "$TMP_WT" "$TMP_MAIN")"
    [[ "$prefix" == "$STRAPS_BUNDLED_DIR/alpha:$STRAPS_BUNDLED_DIR/beta" ]]
}

@test "strap names with slashes or traversal are rejected" {
    run resolve_strap "../evil" "$TMP_WT" "$TMP_MAIN"
    [ "$status" -eq 1 ]
    run resolve_strap "a/b" "$TMP_WT" "$TMP_MAIN"
    [ "$status" -eq 1 ]
}
