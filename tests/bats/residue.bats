#!/usr/bin/env bats

# Tests for the residue mirror (docs/adr/0008, lib/worktree.sh): every
# untracked file in the main repo — including gitignored ones like .env —
# seeds the worktree, minus copy.ignore / .wtbsignore rules. Seed-only:
# existing destination files are never overwritten.

setup() {
    source "$BATS_TEST_DIRNAME/../../lib/utils.sh"
    source "$BATS_TEST_DIRNAME/../../lib/worktree.sh"
    export TMP_MAIN="$(mktemp -d)"
    export TMP_WT="$(mktemp -d)"
    cd "$TMP_MAIN"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"
    # This machine sets core.autocrlf=true globally; committed files must
    # keep LF endings.
    git config core.autocrlf false
    echo "tracked-content" > tracked.txt
    echo ".env" > .gitignore
    git add -A
    git commit -q -m "initial"
}

teardown() {
    if [[ -d "$TMP_MAIN" ]]; then
        local wt
        git -C "$TMP_MAIN" worktree list --porcelain 2>/dev/null \
            | awk '/^worktree / {print $2}' \
            | while read -r wt; do
                [[ "$wt" == "$TMP_MAIN" ]] && continue
                git -C "$TMP_MAIN" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
            done
    fi
    rm -rf "$TMP_MAIN" "$TMP_WT"
}

@test "residue_list includes untracked files" {
    echo "residue" > untracked.txt
    local list
    list="$(residue_list "$TMP_MAIN")"
    [[ "$list" == *"untracked.txt"* ]]
}

@test "residue_list includes gitignored-but-untracked files like .env" {
    echo "SECRET=1" > .env
    local list
    list="$(residue_list "$TMP_MAIN")"
    [[ "$list" == *".env"* ]]
}

@test "residue_list excludes tracked files" {
    echo "residue" > fresh.txt
    local list
    list="$(residue_list "$TMP_MAIN")"
    [[ "$list" == *"fresh.txt"* ]]
    ! grep -qx "tracked.txt" <<< "$list"
}

@test "residue_list never includes .git or .wtbs" {
    mkdir -p .wtbs/worktrees
    echo "state" > .wtbs/worktrees/feature_x.yml
    echo "residue" > untracked.txt
    local list
    list="$(residue_list "$TMP_MAIN")"
    [[ "$list" == *"untracked.txt"* ]]
    [[ "$list" != *"worktrees/feature_x.yml"* ]]
    [[ "$list" != *".git"* ]]
}

@test "residue_list honors gitignore-style exclude patterns" {
    mkdir -p node_modules/pkg vendor
    echo "residue" > untracked.txt
    echo "module" > node_modules/pkg/index.js
    echo "lib" > vendor/lib.php
    echo "log" > debug.log
    local list
    list="$(residue_list "$TMP_MAIN" "node_modules" "*.log")"
    [[ "$list" == *"untracked.txt"* ]]
    [[ "$list" == *"vendor/lib.php"* ]]
    [[ "$list" != *"node_modules"* ]]
    [[ "$list" != *"debug.log"* ]]
}

@test "copy_residue mirrors untracked files into the worktree" {
    echo "residue" > untracked.txt
    echo "SECRET=1" > .env
    local stats
    stats="$(copy_residue "$TMP_MAIN" "$TMP_WT")"
    [[ "$stats" == "copied=2 skipped=0" ]]
    [[ "$(cat "$TMP_WT/untracked.txt")" == "residue" ]]
    [[ "$(cat "$TMP_WT/.env")" == "SECRET=1" ]]
}

@test "copy_residue mirrors nested untracked files with their directories" {
    mkdir -p fixtures/seeds
    echo "seed" > fixtures/seeds/data.sql
    copy_residue "$TMP_MAIN" "$TMP_WT" >/dev/null
    [[ "$(cat "$TMP_WT/fixtures/seeds/data.sql")" == "seed" ]]
}

@test "copy_residue is seed-only and counts existing destinations as skipped" {
    echo "main version" > untracked.txt
    echo "worktree version" > "$TMP_WT/untracked.txt"
    local stats
    stats="$(copy_residue "$TMP_MAIN" "$TMP_WT")"
    [[ "$stats" == "copied=0 skipped=1" ]]
    [[ "$(cat "$TMP_WT/untracked.txt")" == "worktree version" ]]
}

@test "copy_residue honors exclude patterns" {
    mkdir -p node_modules
    echo "module" > node_modules/index.js
    echo "residue" > untracked.txt
    local stats
    stats="$(copy_residue "$TMP_MAIN" "$TMP_WT" "node_modules")"
    [[ "$stats" == "copied=1 skipped=0" ]]
    [[ ! -e "$TMP_WT/node_modules/index.js" ]]
}

@test "create honors .wtbsignore and copy.ignore as a union" {
    # End-to-end through the CLI: ignore rules from both entries apply.
    export SCRIPT="$BATS_TEST_DIRNAME/../../wtbs.sh"
    export WTBS_SETTINGS_FILE="/nonexistent/wtbs-settings.yml"
    mkdir -p node_modules vendor
    echo "module" > node_modules/index.js
    echo "lib" > vendor/lib.php
    printf '.env\nnode_modules/\nvendor/\n' > .gitignore
    printf '# local noise\nnode_modules\n' > .wtbsignore
    cat > .wtbs.yml <<'EOF'
copy:
  ignore:
    - vendor
EOF
    git add -A && git commit -q -m "fixture"
    # Created after the commit: untracked residue, mirrored into the worktree.
    echo "residue" > seed.txt
    echo "SECRET=1" > .env
    run "$SCRIPT" create feature/mirror
    [ "$status" -eq 0 ]
    local wt
    wt="$(dirname "$TMP_MAIN")/$(basename "$TMP_MAIN")-feature-mirror"
    [[ "$(cat "$wt/.env")" == "SECRET=1" ]]
    [[ "$(cat "$wt/seed.txt")" == "residue" ]]
    [[ ! -e "$wt/node_modules/index.js" ]]
    [[ ! -e "$wt/vendor/lib.php" ]]
    # .wtbsignore itself is tracked here, so the mirror is exactly .env + seed.
    [[ "$output" == *"mirrored untracked residue (copied=2 skipped=0; ignore rules: 2)"* ]]
    run "$SCRIPT" destroy feature/mirror
    [ "$status" -eq 0 ]
}
