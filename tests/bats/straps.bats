#!/usr/bin/env bats

setup() {
    export LIB_DIR="$BATS_TEST_DIRNAME/../../lib"
    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/env.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/ports.sh"
    source "$LIB_DIR/strap.sh"
    source "$LIB_DIR/bootstrap.sh"

    export TMP_MAIN="$(mktemp -d)"
    export TMP_WT="$(mktemp -d)"
    # Hermetic bundled dir, so tests never touch the repo's real straps/.
    export STRAPS_BUNDLED_DIR="$(mktemp -d)"

    # alpha: a strap with a create lifecycle + a verb
    mkdir -p "$STRAPS_BUNDLED_DIR/alpha"
    cat > "$STRAPS_BUNDLED_DIR/alpha/create" <<'EOF'
#!/usr/bin/env bash
echo "alpha-create:$WTBS_BRANCH_SLUG:$WTBS_STRAP_ARGS_ALPHA" > alpha.out
EOF
    chmod +x "$STRAPS_BUNDLED_DIR/alpha/create"
    cat > "$STRAPS_BUNDLED_DIR/alpha/myverb" <<'EOF'
#!/usr/bin/env bash
echo "alpha-verb:$1"
EOF
    chmod +x "$STRAPS_BUNDLED_DIR/alpha/myverb"

    # beta: a strap with args but no lifecycle
    mkdir -p "$STRAPS_BUNDLED_DIR/beta"
    cat > "$STRAPS_BUNDLED_DIR/beta/strap.yml" <<'EOF'
sites: "main,wt"
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

@test "parse_strap_ref splits name and args" {
    parse_strap_ref "auto-ports(serve:8000;db:33060)"
    [[ "$REF_NAME" == "auto-ports" ]]
    [[ "$REF_ARGS" == "serve:8000;db:33060" ]]
    parse_strap_ref "valet"
    [[ "$REF_NAME" == "valet" ]]
    [[ -z "$REF_ARGS" ]]
    run parse_strap_ref "bad(name"
    [ "$status" -eq 0 ]  # unbalanced parens degrade to a name; dir lookup fails later
}

@test "resolve_strap prefers worktree over main over bundled" {
    mkdir -p "$TMP_MAIN/.wtbs/straps/alpha" "$TMP_WT/.wtbs/straps/alpha"
    [[ "$(resolve_strap alpha "$TMP_WT" "$TMP_MAIN")" == "$TMP_WT/.wtbs/straps/alpha" ]]
    [[ "$(resolve_strap alpha "" "$TMP_MAIN")" == "$TMP_MAIN/.wtbs/straps/alpha" ]]
    [[ "$(resolve_strap beta "" "$TMP_MAIN")" == "$STRAPS_BUNDLED_DIR/beta" ]]
    [[ -z "$(resolve_strap gamma "" "$TMP_MAIN")" ]]
}

@test "resolved_straps fatals on an unknown strap" {
    declare_with gamma
    run resolved_straps "$TMP_WT" "$TMP_MAIN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"strap not found: 'gamma'"* ]]
}

@test "strap names with slashes or traversal are rejected" {
    run resolve_strap "../evil" "$TMP_WT" "$TMP_MAIN"
    [ "$status" -eq 1 ]
    run resolve_strap "a/b" "$TMP_WT" "$TMP_MAIN"
    [ "$status" -eq 1 ]
}

@test "export_strap_args exports args per strap name" {
    (
        unset WTBS_STRAP_ARGS_ALPHA 2>/dev/null || true
        export_strap_args "alpha(one;two)" "beta"
        [[ "$WTBS_STRAP_ARGS_ALPHA" == "one;two" ]]
        [[ "$WTBS_STRAP_ARGS_BETA" == "" ]]
    )
}

@test "strap_path_prefix lists resolved strap dirs" {
    declare_with alpha beta
    local prefix
    prefix="$(strap_path_prefix "$TMP_WT" "$TMP_MAIN")"
    [[ "$prefix" == "$STRAPS_BUNDLED_DIR/alpha:$STRAPS_BUNDLED_DIR/beta" ]]
}

@test "strap create lifecycles run with context and args env" {
    declare_with "alpha(one;two)"
    local -A ctx=(
        [branch]=feature/x [branch_slug]=feature_x [site]=wt
        [db_name]=wt_feature_x [worktree_root]="$TMP_WT" [main_repo]="$TMP_MAIN"
    )
    (
        cd "$TMP_WT"
        DRY_RUN=0 run_strap_lifecycles create ctx
    )
    grep -qx "alpha-create:feature_x:one;two" "$TMP_WT/alpha.out"
}
