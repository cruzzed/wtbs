#!/usr/bin/env bats

setup() {
    export TMP_ORIGIN="$(mktemp -d)"
    export SCRIPT="$BATS_TEST_DIRNAME/../../wtbs.sh"
    cd "$TMP_ORIGIN"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"
    # This machine sets core.autocrlf=true globally; committed scripts must
    # keep LF endings or their shebangs break in worktree checkouts.
    git config core.autocrlf false
    git commit --allow-empty -q -m "initial"
}

teardown() {
    if [[ -d "$TMP_ORIGIN" ]]; then
        local wt
        git -C "$TMP_ORIGIN" worktree list --porcelain 2>/dev/null \
            | awk '/^worktree / {print $2}' \
            | while read -r wt; do
                [[ "$wt" == "$TMP_ORIGIN" ]] && continue
                git -C "$TMP_ORIGIN" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
            done
    fi
    rm -rf "$TMP_ORIGIN" "$(dirname "$TMP_ORIGIN")/wt-customdir"
}

@test "create prints dry-run report without errors" {
    git branch feature/smoke
    echo 'DB_DATABASE=main' > .env
    run "$SCRIPT" create feature/smoke --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would create worktree"* ]]
    [[ "$output" == *"feature/smoke"* ]]
}

@test "create with no config bootstraps just the worktree" {
    run "$SCRIPT" create feature/plain
    [ "$status" -eq 0 ]
    [[ "$output" == *"ports ............... <none declared>"* ]]
    [[ "$output" == *"straps .............. <none>"* ]]
}

@test "bootstrap prints dry-run report from a worktree" {
    git branch feature/test
    git worktree add -q "$(dirname "$TMP_ORIGIN")/wt-dry" feature/test
    cd "$(dirname "$TMP_ORIGIN")/wt-dry"
    run "$SCRIPT" bootstrap --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"wtbs preflight"* ]]
}

@test "bootstrap applies env entries with branch, slug, site and port templates" {
    echo 'APP_URL=https://main.test' > .env
    cat > .wtbs.yml <<'EOF'
copy: [.env]
db_name: "myapp_{branch_slug}"
ports:
  app: 8080
  serve: 8000
env:
  APP_PORT: "{ports.app}"
  APP_URL: "https://{site}.test"
  SERVE_PORT: "{ports.serve}"
  DB_DATABASE: "{db_name}"
  BRANCH_COPY: "{branch}"
EOF
    run "$SCRIPT" create feature/templates
    [ "$status" -eq 0 ]
    local wt offset
    wt="$(git worktree list --porcelain | awk '/^worktree /{print $2}' | grep -v "^$TMP_ORIGIN$")"
    # The offset depends on which ports are actually free on this machine.
    offset="$(cut -f2 .wtbs/registry.tsv | head -n1)"
    grep -qx "APP_PORT=$((8080 + offset))" "$wt/.env"
    grep -qx "SERVE_PORT=$((8000 + offset))" "$wt/.env"
    grep -q "^APP_URL=https://.*\.test$" "$wt/.env"
    grep -qx "DB_DATABASE=myapp_feature_templates" "$wt/.env"
    grep -qx "BRANCH_COPY=feature/templates" "$wt/.env"
}

@test "env entries can preserve original values with {env.KEY}" {
    printf 'DATABASE_URL=postgres://main/db\n' > .env
    cat > .wtbs.yml <<'EOF'
copy: [.env]
env:
  PARENT_DATABASE_URL: "{env.DATABASE_URL}"
  DATABASE_URL: "postgres://localhost/{db_name}"
EOF
    run "$SCRIPT" create feature/envref
    [ "$status" -eq 0 ]
    local wt
    wt="$(git worktree list --porcelain | awk '/^worktree /{print $2}' | grep -v "^$TMP_ORIGIN$")"
    grep -qx "PARENT_DATABASE_URL=postgres://main/db" "$wt/.env"
    grep -qx "DATABASE_URL=postgres://localhost/wt_feature_envref" "$wt/.env"
}

@test "hooks run with the main repo .env exported even after env rewrites" {
    # Regression: the clone SOURCE must stay visible to hooks even though the
    # worktree .env gets DB_DATABASE rewritten to the target.
    printf 'DB_DATABASE=main_source\n' > .env
    cat > .wtbs.yml <<'EOF'
copy: [.env]
env:
  DB_DATABASE: "{db_name}"
hooks:
  create:
    - "echo $DB_DATABASE > hook-source.out"
EOF
    run "$SCRIPT" create feature/hookenv
    [ "$status" -eq 0 ]
    local wt
    wt="$(git worktree list --porcelain | awk '/^worktree /{print $2}' | grep -v "^$TMP_ORIGIN$")"
    grep -qx "main_source" "$wt/hook-source.out"
    grep -qx "DB_DATABASE=wt_feature_hookenv" "$wt/.env"
}

@test "destroy runs hooks.destroy before teardown" {
    cat > .wtbs.yml <<'EOF'
hooks:
  destroy:
    - "echo destroyed-hook {db_name} > {main_repo}/destroy.log"
EOF
    run "$SCRIPT" create feature/destr
    [ "$status" -eq 0 ]
    run "$SCRIPT" destroy feature/destr
    [ "$status" -eq 0 ]
    grep -qx "destroyed-hook wt_feature_destr" "$TMP_ORIGIN/destroy.log"
}

@test "destroy prints dry-run report without errors" {
    git branch feature/dry
    git worktree add -q "$(dirname "$TMP_ORIGIN")/wt-destroy-dry" feature/dry
    run "$SCRIPT" destroy feature/dry --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would destroy"* ]]
    [[ -d "$(dirname "$TMP_ORIGIN")/wt-destroy-dry" ]]
}

@test "destroy falls back to computed db name without a registry entry" {
    git branch feature/noreg
    git worktree add -q "$(dirname "$TMP_ORIGIN")/wt-noreg" feature/noreg
    run "$SCRIPT" destroy feature/noreg
    [ "$status" -eq 0 ]
    [[ ! -d "$(dirname "$TMP_ORIGIN")/wt-noreg" ]]
}

@test "global flags are accepted in any position" {
    git branch feature/flags
    echo 'DB_DATABASE=main' > .env
    run "$SCRIPT" --dry-run create feature/flags
    [ "$status" -eq 0 ]
    run "$SCRIPT" create feature/flags --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run"* ]]
}

@test "create --dry-run renders the full bootstrap plan" {
    echo 'DB_DATABASE=main' > .env
    cat > .wtbs.yml <<'EOF'
copy: [.env]
ports:
  app: 8080
env:
  APP_PORT: "{ports.app}"
hooks:
  create:
    - "echo setup {branch_slug}"
  destroy:
    - "echo teardown"
EOF
    run "$SCRIPT" create feature/plan --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would copy config files: .env"* ]]
    # The offset depends on which ports are actually free on this machine.
    [[ "$output" =~ env:\ APP_PORT=808[0-9] ]]
    [[ "$output" == *"would run: echo setup feature_plan"* ]]
    [[ "$output" == *"would run: echo teardown"* ]]
    [[ "$output" == *"ports.app"* ]]
}

@test "create registers branch state in the registry" {
    run "$SCRIPT" create feature/reg
    [ "$status" -eq 0 ]
    grep -q "^feature/reg" .wtbs/registry.tsv
}

@test "create --dry-run does not touch the registry" {
    run "$SCRIPT" create feature/noreg-dry --dry-run
    [ "$status" -eq 0 ]
    [ ! -f .wtbs/registry.tsv ]
}

@test "bootstrap fails fast when a hook script is missing from the worktree" {
    cat > .wtbs.yml <<'EOF'
hooks:
  create:
    - "scripts/missing-hook.sh {branch_slug}"
EOF
    run "$SCRIPT" create feature/missinghook
    [ "$status" -eq 1 ]
    [[ "$output" == *"hook script not found in worktree: scripts/missing-hook.sh"* ]]
}

@test "destroy prunes the worktree so the branch is immediately deletable" {
    run "$SCRIPT" create feature/prune
    [ "$status" -eq 0 ]
    run "$SCRIPT" destroy feature/prune
    [ "$status" -eq 0 ]
    run git branch -d feature/prune
    [ "$status" -eq 0 ]
}

@test "destroy --delete-branch removes the branch" {
    run "$SCRIPT" create feature/delbr
    [ "$status" -eq 0 ]
    run "$SCRIPT" destroy feature/delbr --delete-branch
    [ "$status" -eq 0 ]
    ! git show-ref --verify --quiet "refs/heads/feature/delbr"
}

@test "destroy removes the registry row" {
    run "$SCRIPT" create feature/regrow
    [ "$status" -eq 0 ]
    grep -q "^feature/regrow" .wtbs/registry.tsv
    run "$SCRIPT" destroy feature/regrow
    [ "$status" -eq 0 ]
    ! grep -q "^feature/regrow" .wtbs/registry.tsv
}

@test "v0.3 config keys are rejected with a migration pointer" {
    cat > .wtbs.yml <<'EOF'
database:
  driver: mysql
commands:
  install:
    - npm ci
EOF
    run "$SCRIPT" create feature/legacy
    [ "$status" -eq 1 ]
    [[ "$output" == *"v0.3 config keys"* ]]
    [[ "$output" == *"examples/"* ]]
}

@test "sqlite strap clones and drops the worktree database file" {
    echo 'DB_DATABASE=db.sqlite3' > .env
    echo "db-content" > db.sqlite3
    # Local strap copy: this environment may normalize the executable bits of
    # untracked repo files; bundled-resolution itself is covered in straps.bats.
    mkdir -p .wtbs/straps
    cp -R "$BATS_TEST_DIRNAME/../../straps/sqlite" .wtbs/straps/sqlite
    chmod 755 .wtbs/straps/sqlite/db-clone .wtbs/straps/sqlite/db-drop
    git add -A && git commit -q -m "add env, db and strap"
    cat > .wtbs.yml <<'EOF'
straps: [sqlite]
copy: [.env]
EOF
    git add .wtbs.yml && git commit -q -m "config"
    run "$SCRIPT" create feature/sqlstrap
    [ "$status" -eq 0 ]
    [[ "$output" == *"straps .............. sqlite"* ]]
    local wt
    wt="$(git worktree list --porcelain | awk '/^worktree /{print $2}' | grep -v "^$TMP_ORIGIN$")"
    [[ "$(cat "$wt/wt_feature_sqlstrap.sqlite")" == "db-content" ]]
    grep -qx "DB_DATABASE=$wt/wt_feature_sqlstrap.sqlite" "$wt/.env"
    run "$SCRIPT" destroy feature/sqlstrap
    [ "$status" -eq 0 ]
    [[ ! -e "$wt" ]]
}

@test "ngrok strap rejects a worktree share by default" {
    printf 'NGROK_SHARED_URL=test-reserved.ngrok.dev\n' > .env
    # Hermetic bundled dir: the strict steal guard only applies to bundled
    # straps, and this environment may normalize repo file modes.
    export WTBS_STRAPS_DIR="$(mktemp -d)"
    mkdir -p "$WTBS_STRAPS_DIR/ngrok"
    cp "$BATS_TEST_DIRNAME/../../straps/ngrok/"* "$WTBS_STRAPS_DIR/ngrok/"
    chmod 755 "$WTBS_STRAPS_DIR/ngrok/ngrok-share" "$WTBS_STRAPS_DIR/ngrok/ngrok-guard"
    cat > .wtbs.yml <<'EOF'
straps: [ngrok]
copy: [.env]
EOF
    run "$SCRIPT" create feature/steal
    [ "$status" -eq 0 ]
    run "$SCRIPT" exec feature/steal share
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing to hand https://test-reserved.ngrok.dev"* ]]
    rm -rf "$WTBS_STRAPS_DIR"
}

@test "create --dir uses a custom directory name" {
    run "$SCRIPT" create feature/custom --dir wt-customdir
    [ "$status" -eq 0 ]
    [[ -d "$(dirname "$TMP_ORIGIN")/wt-customdir" ]]
    [[ "$output" == *"wt-customdir"* ]]
}

@test "create --dir rejects traversal and slashes" {
    run "$SCRIPT" create feature/bad --dir "../escape"
    [ "$status" -eq 1 ]
    run "$SCRIPT" create feature/bad2 --dir "a/b"
    [ "$status" -eq 1 ]
}

@test "destroy resolves a --dir worktree by branch name" {
    run "$SCRIPT" create feature/customdir --dir wt-customdir
    [ "$status" -eq 0 ]
    run "$SCRIPT" destroy feature/customdir
    [ "$status" -eq 0 ]
    [[ ! -d "$(dirname "$TMP_ORIGIN")/wt-customdir" ]]
}

@test "destroy by branch name never resolves to the main repo" {
    run "$SCRIPT" destroy main --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" != *"would destroy $TMP_ORIGIN "* ]]
    [[ -d "$TMP_ORIGIN" ]]
}

@test "create --dry-run shortens every name segment to 4 chars" {
    run "$SCRIPT" create feature/shopify-oauth-space-selector --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"-feat-shop-oaut-spac-sele"* ]]
}
