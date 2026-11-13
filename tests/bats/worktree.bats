#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../../lib/utils.sh"
    source "$BATS_TEST_DIRNAME/../../lib/worktree.sh"
    export TMP_ORIGIN="$(mktemp -d)"
    export TMP_WT="$(mktemp -d)"
    cd "$TMP_ORIGIN"
    git init -q
    git commit --allow-empty -q -m "initial"
    git branch feature/test
    git branch feature/new
}

teardown() {
    rm -rf "$TMP_ORIGIN" "$TMP_WT"
}

@test "resolve_main_root auto-detects main repo from worktree" {
    cd "$TMP_ORIGIN"
    git worktree add -q "$TMP_WT/wt" feature/test
    cd "$TMP_WT/wt"
    local main
    main="$(resolve_main_root "")"
    [[ "$main" == "$TMP_ORIGIN" ]]
}

@test "create_worktree creates a worktree directory" {
    cd "$TMP_ORIGIN"
    create_worktree "feature/new" "$TMP_WT/new"
    [[ -e "$TMP_WT/new/.git" ]]
}

@test "create_worktree creates the branch when it does not exist" {
    cd "$TMP_ORIGIN"
    run create_worktree "feature/brand-new" "$TMP_WT/brand-new"
    [ "$status" -eq 0 ]
    [[ "$output" == *"does not exist; creating from HEAD"* ]]
    [[ -e "$TMP_WT/brand-new/.git" ]]
    git show-ref --verify --quiet "refs/heads/feature/brand-new"
}

@test "create_worktree creates the branch from a custom base ref" {
    cd "$TMP_ORIGIN"
    git branch base-ref
    run create_worktree "feature/from-base" "$TMP_WT/from-base" "base-ref"
    [ "$status" -eq 0 ]
    [[ "$output" == *"does not exist; creating from base-ref"* ]]
    [[ -e "$TMP_WT/from-base/.git" ]]
    [[ "$(git rev-parse feature/from-base)" == "$(git rev-parse base-ref)" ]]
}

@test "create_worktree checks out existing branch without recreating it" {
    cd "$TMP_ORIGIN"
    run create_worktree "feature/new" "$TMP_WT/existing"
    [ "$status" -eq 0 ]
    [[ "$output" != *"does not exist"* ]]
    [[ -e "$TMP_WT/existing/.git" ]]
}

@test "require_not_main_root passes outside main repo root" {
    cd "$TMP_ORIGIN"
    git worktree add -q "$TMP_WT/wt" feature/test
    cd "$TMP_WT/wt"
    require_not_main_root "$TMP_ORIGIN"
}

@test "require_not_main_root fails at main repo root" {
    cd "$TMP_ORIGIN"
    run bash -c 'source "$0/../../lib/utils.sh"; source "$0/../../lib/worktree.sh"; require_not_main_root "$TMP_ORIGIN"' "$BATS_TEST_DIRNAME"
    [ "$status" -eq 1 ]
    [[ "$output" == *"main repo root"* ]]
}

@test "list_worktrees returns registered worktree paths" {
    cd "$TMP_ORIGIN"
    git worktree add -q "$TMP_WT/wt" feature/test
    local paths
    paths="$(list_worktrees)"
    [[ "$paths" == *"$TMP_WT/wt"* ]]
}

@test "destroy_worktree removes worktree by path" {
    cd "$TMP_ORIGIN"
    git worktree add -q "$TMP_WT/by-path" feature/test
    destroy_worktree "$TMP_WT/by-path"
    [[ ! -d "$TMP_WT/by-path" ]]
}

@test "destroy_worktree removes worktree by branch name" {
    cd "$TMP_ORIGIN"
    git worktree add -q "$TMP_WT/by-branch" feature/test
    destroy_worktree "feature/test"
    [[ ! -d "$TMP_WT/by-branch" ]]
}

@test "remove_worktree dry-run prints and preserves worktree" {
    cd "$TMP_ORIGIN"
    git worktree add -q "$TMP_WT/dry" feature/test
    run remove_worktree "$TMP_WT/dry" "1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"would remove worktree"* ]]
    [[ -d "$TMP_WT/dry" ]]
}

@test "destroy_worktree dry-run prints and preserves worktree" {
    cd "$TMP_ORIGIN"
    git worktree add -q "$TMP_WT/dry2" feature/test
    run destroy_worktree "feature/test" "true"
    [ "$status" -eq 0 ]
    [[ "$output" == *"would remove worktree"* ]]
    [[ -d "$TMP_WT/dry2" ]]
}

@test "remove_worktree refuses unsafe removal of non-worktree path" {
    mkdir -p "$TMP_WT/not-a-worktree"
    run remove_worktree "$TMP_WT/not-a-worktree"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing unsafe removal"* ]]
    [[ -d "$TMP_WT/not-a-worktree" ]]
}

@test "destroy_worktree refuses a plain directory that is not a worktree" {
    mkdir -p "$TMP_WT/plain-dir"
    run destroy_worktree "$TMP_WT/plain-dir"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no worktree found"* ]]
    [[ -d "$TMP_WT/plain-dir" ]]
}

@test "remove_worktree safely falls back to wtbs_remove_tree for registered worktree" {
    cd "$TMP_ORIGIN"
    git worktree add -q "$TMP_WT/fallback" feature/test
    echo "dirty" > "$TMP_WT/fallback/dirty.txt"
    remove_worktree "$TMP_WT/fallback"
    [[ ! -d "$TMP_WT/fallback" ]]
}
