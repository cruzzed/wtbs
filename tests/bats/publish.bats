#!/usr/bin/env bats

# Tests for publish on activation (docs/adr/0007, lib/strap.sh:
# publish_straps / scaffold_env_strap): bundled straps activated by the
# project are copied into <main-repo>/.wtbs/straps/, and the project env
# strap is scaffolded when absent. Skipped with --no-publish or
# `publish: false`; dry-run reports without writing.

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

    # alpha: a bundled strap with a create lifecycle
    mkdir -p "$STRAPS_BUNDLED_DIR/alpha"
    printf '#!/usr/bin/env bash\necho alpha-create\n' > "$STRAPS_BUNDLED_DIR/alpha/create"
    chmod +x "$STRAPS_BUNDLED_DIR/alpha/create"

    DRY_RUN=0
    NO_PUBLISH=0
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

make_ctx() {
    local -n out_ref="$1"
    out_ref=()
    out_ref[branch]=feature/x
    out_ref[branch_slug]=feature_x
    out_ref[site]=wt
    out_ref[db_name]=wt_feature_x
    out_ref[worktree_root]="$TMP_WT"
    out_ref[main_repo]="$TMP_MAIN"
}

@test "publish_straps copies an activated bundled strap into the project" {
    declare_with alpha
    local -A ctx=()
    make_ctx ctx
    publish_straps ctx
    [[ -f "$TMP_MAIN/.wtbs/straps/alpha/create" ]]
    [[ -x "$TMP_MAIN/.wtbs/straps/alpha/create" ]]
}

@test "publish_straps scaffolds the project env strap with executable scripts" {
    declare_with alpha
    local -A ctx=()
    make_ctx ctx
    publish_straps ctx
    [[ -x "$TMP_MAIN/.wtbs/straps/env/create" ]]
    [[ -x "$TMP_MAIN/.wtbs/straps/env/destroy" ]]
    # The scaffold sources strap-lib so the project can start writing keys.
    grep -q 'strap-lib.sh' "$TMP_MAIN/.wtbs/straps/env/create"
}

@test "a second publish does not clobber edited local copies" {
    declare_with alpha
    local -A ctx=()
    make_ctx ctx
    publish_straps ctx
    echo "# project edit" >> "$TMP_MAIN/.wtbs/straps/alpha/create"
    echo "# env edit" >> "$TMP_MAIN/.wtbs/straps/env/create"
    publish_straps ctx
    grep -q "# project edit" "$TMP_MAIN/.wtbs/straps/alpha/create"
    grep -q "# env edit" "$TMP_MAIN/.wtbs/straps/env/create"
}

@test "locally-owned straps are not republished" {
    # A strap that already resolves to the project's own .wtbs/straps/ is
    # project-owned; publishing leaves it alone.
    mkdir -p "$TMP_MAIN/.wtbs/straps/alpha"
    echo "local version" > "$TMP_MAIN/.wtbs/straps/alpha/create"
    declare_with alpha
    local -A ctx=()
    make_ctx ctx
    publish_straps ctx
    [[ "$(cat "$TMP_MAIN/.wtbs/straps/alpha/create")" == "local version" ]]
}

@test "no declared straps means nothing is published or scaffolded" {
    declare_with
    local -A ctx=()
    make_ctx ctx
    publish_straps ctx
    [[ ! -e "$TMP_MAIN/.wtbs/straps" ]]
}

@test "--no-publish skips publishing and scaffolding" {
    declare_with alpha
    NO_PUBLISH=1
    local -A ctx=()
    make_ctx ctx
    run publish_straps ctx
    [ "$status" -eq 0 ]
    [[ "$output" == *"strap publishing disabled (--no-publish or publish: false)"* ]]
    [[ ! -e "$TMP_MAIN/.wtbs/straps" ]]
}

@test "publish: false skips publishing and scaffolding" {
    declare_with alpha
    CONFIG["publish"]="false"
    local -A ctx=()
    make_ctx ctx
    run publish_straps ctx
    [ "$status" -eq 0 ]
    [[ "$output" == *"strap publishing disabled (--no-publish or publish: false)"* ]]
    [[ ! -e "$TMP_MAIN/.wtbs/straps" ]]
}

@test "dry-run reports the publish plan without writing" {
    declare_with alpha
    DRY_RUN=1
    local -A ctx=()
    make_ctx ctx
    run publish_straps ctx
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run] would publish strap 'alpha' -> $TMP_MAIN/.wtbs/straps/alpha"* ]]
    [[ "$output" == *"[dry-run] would scaffold project env strap -> $TMP_MAIN/.wtbs/straps/env"* ]]
    [[ ! -e "$TMP_MAIN/.wtbs/straps" ]]
}
