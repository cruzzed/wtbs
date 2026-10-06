#!/usr/bin/env bats

setup() {
    export TMP_ORIGIN="$(mktemp -d)"
    export SCRIPT="$BATS_TEST_DIRNAME/../../wtbs.sh"
    # Hermetic: no user settings (~/.config/wtbs/settings.yml) during tests.
    export WTBS_SETTINGS_FILE="/nonexistent/wtbs-settings.yml"
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

# Commits .wtbs/straps/env/create with the given body (a file, written by the
# test with a quoted heredoc) — the project's voice for its own .env keys
# (docs/adr/0007). Runs after every declared strap's create lifecycle.
commit_env_strap() {
    local body_file="$1"
    mkdir -p .wtbs/straps/env
    {
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'set -euo pipefail' \
            'source "${WTBS_LIB_DIR:?run inside wtbs}/strap-lib.sh"'
        cat "$body_file"
    } > .wtbs/straps/env/create
    chmod 755 .wtbs/straps/env/create
    git add .wtbs/straps/env/create
    git commit -q -m "project env strap"
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

@test "project env strap applies entries with branch, slug, site and db values" {
    # docs/adr/0007: env writes are strap responsibility. The project env strap
    # renders the same core tokens (exported as WTBS_*) the old env: block did.
    echo 'APP_URL=https://main.test' > .env
    cat > "$BATS_TEST_TMPDIR/env-body" <<'EOF'
wtbs_env_set APP_URL "https://${WTBS_SITE}.test"
wtbs_env_set DB_DATABASE "${WTBS_DB_NAME}"
wtbs_env_set BRANCH_COPY "${WTBS_BRANCH}"
EOF
    commit_env_strap "$BATS_TEST_TMPDIR/env-body"
    cat > .wtbs.yml <<'EOF'
db_name: "myapp_{branch_slug}"
EOF
    git add .wtbs.yml && git commit -q -m "config"
    run "$SCRIPT" create feature/templates
    [ "$status" -eq 0 ]
    local wt
    wt="$(git worktree list --porcelain | awk '/^worktree /{print $2}' | grep -v "^$TMP_ORIGIN$")"
    grep -q "^APP_URL=https://.*\.test$" "$wt/.env"
    grep -qx "DB_DATABASE=myapp_feature_templates" "$wt/.env"
    grep -qx "BRANCH_COPY=feature/templates" "$wt/.env"
}

@test "env strap can preserve original values from the main repo .env" {
    # The strap environment exports the MAIN repo's .env (the source of
    # truth), so values can be relayed before being rewritten.
    printf 'DATABASE_URL=postgres://main/db\n' > .env
    cat > "$BATS_TEST_TMPDIR/env-body" <<'EOF'
wtbs_env_set PARENT_DATABASE_URL "${DATABASE_URL:-}"
wtbs_env_set DATABASE_URL "postgres://localhost/${WTBS_DB_NAME}"
EOF
    commit_env_strap "$BATS_TEST_TMPDIR/env-body"
    cat > .wtbs.yml <<'EOF'
db_name: "wt_{branch_slug}"
EOF
    git add .wtbs.yml && git commit -q -m "config"
    run "$SCRIPT" create feature/envref
    [ "$status" -eq 0 ]
    local wt
    wt="$(git worktree list --porcelain | awk '/^worktree /{print $2}' | grep -v "^$TMP_ORIGIN$")"
    grep -qx "PARENT_DATABASE_URL=postgres://main/db" "$wt/.env"
    grep -qx "DATABASE_URL=postgres://localhost/wt_feature_envref" "$wt/.env"
}

@test "hooks run with the main repo .env exported even after env strap rewrites" {
    # Regression: the clone SOURCE must stay visible to hooks even though the
    # env strap rewrote DB_DATABASE in the worktree's .env.
    printf 'DB_DATABASE=main_source\n' > .env
    cat > "$BATS_TEST_TMPDIR/env-body" <<'EOF'
wtbs_env_set DB_DATABASE "${WTBS_DB_NAME}"
EOF
    commit_env_strap "$BATS_TEST_TMPDIR/env-body"
    cat > .wtbs.yml <<'EOF'
hooks:
  create:
    - "echo $DB_DATABASE > hook-source.out"
EOF
    git add .wtbs.yml && git commit -q -m "config"
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
    cat > "$BATS_TEST_TMPDIR/env-body" <<'EOF'
wtbs_env_set DB_DATABASE "${WTBS_DB_NAME}"
EOF
    commit_env_strap "$BATS_TEST_TMPDIR/env-body"
    cat > .wtbs.yml <<'EOF'
hooks:
  create:
    - "echo setup {branch_slug}"
  destroy:
    - "echo teardown"
EOF
    git add .wtbs.yml && git commit -q -m "config"
    run "$SCRIPT" create feature/plan --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would create worktree"* ]]
    # Residue mirror (docs/adr/0008) replaces the old copy: list form.
    [[ "$output" == *"would mirror 1 untracked file(s) from main repo (seed-only; ignore rules: 0)"* ]]
    # Strap lifecycles are announced, not executed, in dry-run.
    [[ "$output" == *"would run strap 'env' create:"* ]]
    [[ "$output" == *"would run: echo setup feature_plan"* ]]
    [[ "$output" == *"would run: echo teardown"* ]]
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

@test "destroy removes the registry row and the strap state file" {
    cat > .wtbs.yml <<'EOF'
hooks:
  create:
    - 'mkdir -p "$(dirname "$WTBS_STATE_FILE")" && echo "probe: hello-{branch_slug}" >> "$WTBS_STATE_FILE"'
EOF
    run "$SCRIPT" create feature/regrow
    [ "$status" -eq 0 ]
    grep -q "^feature/regrow" .wtbs/registry.tsv
    [[ -f .wtbs/worktrees/feature_regrow.yml ]]
    run "$SCRIPT" destroy feature/regrow
    [ "$status" -eq 0 ]
    ! grep -q "^feature/regrow" .wtbs/registry.tsv
    [[ ! -e .wtbs/worktrees/feature_regrow.yml ]]
}

@test "strap state round-trips through hooks and exec templates" {
    cat > .wtbs.yml <<'EOF'
hooks:
  create:
    - 'mkdir -p "$(dirname "$WTBS_STATE_FILE")" && echo "probe: hello-{branch_slug}" >> "$WTBS_STATE_FILE"'
aliases:
  probetest: "echo state says {probe}"
EOF
    run "$SCRIPT" create feature/state
    [ "$status" -eq 0 ]
    grep -qx "probe: hello-feature_state" .wtbs/worktrees/feature_state.yml
    run "$SCRIPT" exec feature/state probetest
    [ "$status" -eq 0 ]
    [[ "$output" == *"state says hello-feature_state"* ]]
    run "$SCRIPT" destroy feature/state
    [ "$status" -eq 0 ]
    [ ! -e .wtbs/worktrees/feature_state.yml ]
}

@test "auto-ports strap publishes ports that the env strap writes on first create" {
    # docs/adr/0003+0007: straps compute before the env strap runs — the
    # allocated port is readable via wtbs_state_get on the first create.
    cat > "$BATS_TEST_TMPDIR/env-body" <<'EOF'
wtbs_env_set SERVE_PORT "$(wtbs_state_get auto_ports.serve)"
EOF
    commit_env_strap "$BATS_TEST_TMPDIR/env-body"
    cat > .wtbs.yml <<'EOF'
straps: ["auto-ports(serve:48000)"]
EOF
    git add .wtbs.yml && git commit -q -m "config"
    run "$SCRIPT" create feature/ports
    [ "$status" -eq 0 ]
    local wt
    wt="$(git worktree list --porcelain | awk '/^worktree /{print $2}' | grep -v "^$TMP_ORIGIN$")"
    grep -qE "^SERVE_PORT=480[0-9]+$" "$wt/.env"
    [[ -f .wtbs/auto-ports.tsv ]]
    run "$SCRIPT" destroy feature/ports
    [ "$status" -eq 0 ]
    ! grep -q "^feature/ports" .wtbs/auto-ports.tsv
}

@test "project env strap runs after declared straps and reads their state" {
    # Pipeline order (docs/adr/0007): declared straps' create lifecycles run
    # first, then the env strap — which reads their published state.
    mkdir -p .wtbs/straps/probe
    cat > .wtbs/straps/probe/create <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${WTBS_LIB_DIR:?run inside wtbs}/strap-lib.sh"
wtbs_state_set probe.greeting "hello-${WTBS_BRANCH_SLUG}"
EOF
    chmod 755 .wtbs/straps/probe/create
    cat > "$BATS_TEST_TMPDIR/env-body" <<'EOF'
wtbs_env_set PROBE_GREETING "$(wtbs_state_get probe.greeting)"
EOF
    commit_env_strap "$BATS_TEST_TMPDIR/env-body"
    git add .wtbs/straps/probe/create && git commit -q -m "probe strap"
    cat > .wtbs.yml <<'EOF'
straps: [probe]
EOF
    git add .wtbs.yml && git commit -q -m "config"
    run "$SCRIPT" create feature/envstrap
    [ "$status" -eq 0 ]
    local wt
    wt="$(git worktree list --porcelain | awk '/^worktree /{print $2}' | grep -v "^$TMP_ORIGIN$")"
    grep -qx "PROBE_GREETING=hello-feature_envstrap" "$wt/.env"
    grep -qx "probe.greeting: hello-feature_envstrap" .wtbs/worktrees/feature_envstrap.yml
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
    [[ "$output" == *"v0.5 config surface"* ]]
    [[ "$output" == *"examples/"* ]]
}

@test "v0.4 env and copy list keys are rejected with a migration pointer" {
    cat > .wtbs.yml <<'EOF'
copy: [.env]
env:
  DB_DATABASE: "{db_name}"
EOF
    run "$SCRIPT" create feature/legacy2
    [ "$status" -eq 1 ]
    [[ "$output" == *"v0.5 config surface"* ]]
    [[ "$output" == *"docs/adr/0007"* ]]
    [[ "$output" == *"docs/adr/0008"* ]]
}

@test "sqlite strap clones and drops the worktree database file" {
    echo 'DB_DATABASE=db.sqlite3' > .env
    echo "db-content" > db.sqlite3
    # Local strap copy: this environment may normalize the executable bits of
    # untracked repo files; bundled-resolution itself is covered in straps.bats.
    mkdir -p .wtbs/straps
    cp -R "$BATS_TEST_DIRNAME/../../straps/sqlite" .wtbs/straps/sqlite
    chmod 755 .wtbs/straps/sqlite/db-clone .wtbs/straps/sqlite/db-drop \
        .wtbs/straps/sqlite/create .wtbs/straps/sqlite/destroy
    git add -A && git commit -q -m "add env, db and strap"
    cat > .wtbs.yml <<'EOF'
straps: [sqlite]
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
    chmod 755 "$WTBS_STRAPS_DIR/ngrok/share" "$WTBS_STRAPS_DIR/ngrok/ngrok-guard"
    cat > .wtbs.yml <<'EOF'
straps: [ngrok]
EOF
    # --no-publish keeps the bundled (hermetic) strap: publishing would copy
    # it into .wtbs/straps/, where the guard permits everything (customized
    # straps own their own policy).
    run "$SCRIPT" create feature/steal --no-publish
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

@test "create --dry-run keeps the full branch name, sanitizing slashes" {
    run "$SCRIPT" create feature/shopify-oauth-space-selector --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(basename "$TMP_ORIGIN")-feature-shopify-oauth-space-selector"* ]]
}
