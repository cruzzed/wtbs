#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../../lib/utils.sh"
}

@test "slugify converts branch names to safe slugs" {
    [[ "$(slugify 'feature/shopify-credit')" == "feature_shopify_credit" ]]
    [[ "$(slugify 'HOTFIX/ABC-123')" == "hotfix_abc_123" ]]
    [[ "$(slugify '---trim---')" == "trim" ]]
}

@test "command_exists finds existing commands" {
    command_exists bash
    ! command_exists this_command_definitely_does_not_exist_12345
}

@test "fatal prints to stderr and exits" {
    run bash -c 'source "$0/../../lib/utils.sh"; fatal "boom"' "$BATS_TEST_DIRNAME"
    [ "$status" -eq 1 ]
    [[ "$output" == *"boom"* ]]
}
@test "require_nonempty dies on empty or unset variables" {
    run bash -c 'source "$0/../../lib/utils.sh"; empty=""; require_nonempty empty' "$BATS_TEST_DIRNAME"
    [ "$status" -eq 1 ]
    [[ "$output" == *"empty"* ]]
    run bash -c 'source "$0/../../lib/utils.sh"; require_nonempty never_set_xyz' "$BATS_TEST_DIRNAME"
    [ "$status" -eq 1 ]
}

@test "wtbs_remove_file refuses empty, root, HOME, and directories" {
    local tmp_home
    tmp_home="$(mktemp -d)"
    # Empty path.
    run bash -c 'source "$0/../../lib/utils.sh"; wtbs_remove_file ""' "$BATS_TEST_DIRNAME"
    [ "$status" -eq 1 ]
    # Root.
    run bash -c 'source "$0/../../lib/utils.sh"; wtbs_remove_file /' "$BATS_TEST_DIRNAME"
    [ "$status" -eq 1 ]
    # HOME (overridden to a temp dir so the test can never touch the real one).
    run env HOME="$tmp_home" bash -c 'source "$0/../../lib/utils.sh"; wtbs_remove_file "$HOME"' "$BATS_TEST_DIRNAME"
    [ "$status" -eq 1 ]
    [ -d "$tmp_home" ]
    # Directory.
    run bash -c 'source "$0/../../lib/utils.sh"; wtbs_remove_file "$1"' "$BATS_TEST_DIRNAME" "$tmp_home"
    [ "$status" -eq 1 ]
    [ -d "$tmp_home" ]
    rm -rf "$tmp_home"
}

@test "wtbs_remove_file removes a regular file and a symlink" {
    local tmp_dir target
    tmp_dir="$(mktemp -d)"
    target="$tmp_dir/db.sqlite"
    touch "$target"
    wtbs_remove_file "$target"
    [ ! -e "$target" ]
    touch "$tmp_dir/real"
    ln -s "$tmp_dir/real" "$tmp_dir/link"
    wtbs_remove_file "$tmp_dir/link"
    [ ! -e "$tmp_dir/link" ]
    [ -e "$tmp_dir/real" ]
    rm -rf "$tmp_dir"
}

@test "wtbs_remove_tree refuses non-worktree directories and unsafe paths" {
    local tmp_dir plain
    tmp_dir="$(mktemp -d)"
    plain="$tmp_dir/plain"
    mkdir "$plain"
    # Not a worktree, no .git entry.
    run bash -c 'source "$0/../../lib/utils.sh"; wtbs_remove_tree "$1"' "$BATS_TEST_DIRNAME" "$plain"
    [ "$status" -eq 1 ]
    [ -d "$plain" ]
    # Empty and root.
    run bash -c 'source "$0/../../lib/utils.sh"; wtbs_remove_tree ""' "$BATS_TEST_DIRNAME"
    [ "$status" -eq 1 ]
    run bash -c 'source "$0/../../lib/utils.sh"; wtbs_remove_tree /' "$BATS_TEST_DIRNAME"
    [ "$status" -eq 1 ]
    rm -rf "$tmp_dir"
}

@test "wtbs_remove_tree refuses HOME" {
    local tmp_home
    tmp_home="$(mktemp -d)"
    run env HOME="$tmp_home" bash -c 'source "$0/../../lib/utils.sh"; wtbs_remove_tree "$HOME"' "$BATS_TEST_DIRNAME"
    [ "$status" -eq 1 ]
    [ -d "$tmp_home" ]
    rm -rf "$tmp_home"
}

@test "wtbs_remove_tree removes a registered worktree" {
    local tmp_repo tmp_wt
    tmp_repo="$(mktemp -d)"
    tmp_wt="$(mktemp -d)"
    (
        cd "$tmp_repo"
        git init -q
        git commit --allow-empty -q -m "initial"
        git branch feature/rm-tree
        git worktree add -q "$tmp_wt/wt" feature/rm-tree
    )
    wtbs_remove_tree "$tmp_wt/wt"
    [ ! -e "$tmp_wt/wt" ]
    rm -rf "$tmp_repo" "$tmp_wt"
}

@test "wtbs_remove_branch refuses protected and nonexistent branches" {
    local tmp_repo
    tmp_repo="$(mktemp -d)"
    (
        cd "$tmp_repo"
        git init -q
        git commit --allow-empty -q -m "initial"
    )
    for protected in main master dev develop HEAD; do
        run bash -c 'source "$0/../../lib/utils.sh"; wtbs_remove_branch "$1" "$2"' \
            "$BATS_TEST_DIRNAME" "$tmp_repo" "$protected"
        [ "$status" -eq 1 ]
    done
    run bash -c 'source "$0/../../lib/utils.sh"; wtbs_remove_branch "$1" nope-missing' \
        "$BATS_TEST_DIRNAME" "$tmp_repo"
    [ "$status" -eq 1 ]
    rm -rf "$tmp_repo"
}

@test "wtbs_remove_branch deletes an existing ordinary branch" {
    local tmp_repo
    tmp_repo="$(mktemp -d)"
    (
        cd "$tmp_repo"
        git init -q
        git commit --allow-empty -q -m "initial"
        git branch feature/gone
    )
    wtbs_remove_branch "$tmp_repo" "feature/gone"
    (
        cd "$tmp_repo"
        ! git show-ref --verify --quiet refs/heads/feature/gone
    )
    rm -rf "$tmp_repo"
}
