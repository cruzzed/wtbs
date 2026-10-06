#!/usr/bin/env bats

# Tests for the bundled strap scripts (straps/*). The scripts are standalone:
# they run with fake client binaries on PATH and DB_* / WTBS_* env vars set,
# exactly as the hook environment provides them.

setup() {
    # Hermetic copy of the bundled straps: this environment may normalize the
    # executable bits of untracked repo files, and the scripts must be
    # executable to run.
    export STRAPS="$(mktemp -d)"
    cp -R "$BATS_TEST_DIRNAME/../../straps/." "$STRAPS/"
    chmod 755 "$STRAPS"/*/create "$STRAPS"/*/destroy \
        "$STRAPS"/*/db-clone "$STRAPS"/*/db-drop \
        "$STRAPS"/valet/valet-site \
        "$STRAPS"/ngrok/share "$STRAPS"/ngrok/ngrok-guard
    export TMP_BIN="$(mktemp -d)"
    export TMP_TEST_DIR="$(mktemp -d)"
    export PATH="$TMP_BIN:$PATH"
    # The bundled straps source strap-lib.sh via the core-exported WTBS_LIB_DIR
    # (docs/adr/0007); tests calling the scripts directly must provide it.
    export WTBS_LIB_DIR="$BATS_TEST_DIRNAME/../../lib"
    export DB_HOST=127.0.0.1 DB_PORT=3306 DB_USERNAME=root DB_PASSWORD=secret
    export DB_DATABASE=source_db
    export WTBS_MAIN_REPO="$TMP_TEST_DIR/main"
    export WTBS_WORKTREE_ROOT="$TMP_TEST_DIR/wt"
    export WTBS_SITE=wt
    export WTBS_BRANCH=feature/x
    export WTBS_BRANCH_SLUG=feature_x
    export WTBS_DB_NAME=wt_feature_x
    mkdir -p "$WTBS_MAIN_REPO" "$WTBS_WORKTREE_ROOT"
}

teardown() {
    rm -rf "$STRAPS" "$TMP_BIN" "$TMP_TEST_DIR"
}

# ── sqlite strap ────────────────────────────────────────────────────────────

@test "sqlite db-clone copies the source file" {
    echo "data" > "$WTBS_MAIN_REPO/db.sqlite3"
    run "$STRAPS/sqlite/db-clone" db.sqlite3 "$WTBS_WORKTREE_ROOT/wt_branch.sqlite"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cloned"* ]]
    [[ "$(cat "$WTBS_WORKTREE_ROOT/wt_branch.sqlite")" == "data" ]]
}

@test "sqlite db-clone skips an existing target" {
    echo "data" > "$WTBS_MAIN_REPO/db.sqlite3"
    echo "existing" > "$WTBS_WORKTREE_ROOT/wt_branch.sqlite"
    run "$STRAPS/sqlite/db-clone" db.sqlite3 "$WTBS_WORKTREE_ROOT/wt_branch.sqlite"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already exists; skipping"* ]]
    [[ "$(cat "$WTBS_WORKTREE_ROOT/wt_branch.sqlite")" == "existing" ]]
}

@test "sqlite db-clone skips when source and target are identical" {
    echo "data" > "$WTBS_WORKTREE_ROOT/same.sqlite"
    run "$STRAPS/sqlite/db-clone" "$WTBS_WORKTREE_ROOT/same.sqlite" "$WTBS_WORKTREE_ROOT/same.sqlite"
    [ "$status" -eq 0 ]
    [[ "$output" == *"source and target are the same"* ]]
}

@test "sqlite db-clone creates an empty file via sqlite3 when source is missing" {
    cat > "$TMP_BIN/sqlite3" <<'EOF'
#!/usr/bin/env bash
echo "sqlite3 $*" >> "$SQLITE_LOG"
: > "$1"
EOF
    chmod +x "$TMP_BIN/sqlite3"
    export SQLITE_LOG="$TMP_TEST_DIR/sqlite.log"
    run "$STRAPS/sqlite/db-clone" missing.sqlite3 "$WTBS_WORKTREE_ROOT/new.sqlite"
    [ "$status" -eq 0 ]
    [[ "$output" == *"created empty"* ]]
    [[ -f "$WTBS_WORKTREE_ROOT/new.sqlite" ]]
    grep -q "VACUUM" "$SQLITE_LOG"
}

@test "sqlite db-clone touches an empty file when sqlite3 is unavailable" {
    if command -v sqlite3 >/dev/null 2>&1; then
        skip "sqlite3 present; touch path not reachable"
    fi
    run "$STRAPS/sqlite/db-clone" missing.sqlite3 "$WTBS_WORKTREE_ROOT/new.sqlite"
    [ "$status" -eq 0 ]
    [[ "$output" == *"touched empty"* ]]
    [[ -f "$WTBS_WORKTREE_ROOT/new.sqlite" ]]
}

@test "sqlite db-drop deletes the file" {
    echo "data" > "$WTBS_WORKTREE_ROOT/wt_branch.sqlite"
    run "$STRAPS/sqlite/db-drop" "$WTBS_WORKTREE_ROOT/wt_branch.sqlite"
    [ "$status" -eq 0 ]
    [[ ! -f "$WTBS_WORKTREE_ROOT/wt_branch.sqlite" ]]
}

@test "sqlite create lifecycle clones and rewrites DB_DATABASE" {
    echo "db-content" > "$WTBS_MAIN_REPO/db.sqlite3"
    echo 'DB_DATABASE=db.sqlite3' > "$WTBS_WORKTREE_ROOT/.env"
    (
        cd "$WTBS_WORKTREE_ROOT"
        "$STRAPS/sqlite/create"
    )
    [[ -f "$WTBS_WORKTREE_ROOT/wt_feature_x.sqlite" ]]
    grep -qx "DB_DATABASE=$WTBS_WORKTREE_ROOT/wt_feature_x.sqlite" "$WTBS_WORKTREE_ROOT/.env"
}

# ── mysql strap ─────────────────────────────────────────────────────────────

fake_mysql_absent() {
    cat > "$TMP_BIN/mysql" <<'EOF'
#!/usr/bin/env bash
echo "ARGS: $*" >> "$MYSQL_LOG"
echo "MYSQL_PWD=$MYSQL_PWD" >> "$MYSQL_LOG"
sql="$(cat)"
echo "SQL: $sql" >> "$MYSQL_LOG"
exit 0
EOF
    chmod +x "$TMP_BIN/mysql"
    cat > "$TMP_BIN/mysqldump" <<'EOF'
#!/usr/bin/env bash
echo "DUMP ARGS: $*" >> "$MYSQL_LOG"
echo "-- dump content"
EOF
    chmod +x "$TMP_BIN/mysqldump"
    export MYSQL_LOG="$TMP_TEST_DIR/mysql.log"
}

@test "mysql db-clone creates and clones with env credentials" {
    fake_mysql_absent
    run "$STRAPS/mysql/db-clone" wt_target
    [ "$status" -eq 0 ]
    [[ "$output" == *"cloned source_db -> wt_target"* ]]
    grep -q "SQL: CREATE DATABASE IF NOT EXISTS \`wt_target\`" "$MYSQL_LOG"
    grep -q "DUMP ARGS: --host=127.0.0.1 --port=3306 --user=root --single-transaction source_db" "$MYSQL_LOG"
    grep -q "ARGS: --host=127.0.0.1 --port=3306 --user=root wt_target" "$MYSQL_LOG"
    grep -q "MYSQL_PWD=secret" "$MYSQL_LOG"
}

@test "mysql db-clone skips an existing database" {
    cat > "$TMP_BIN/mysql" <<'EOF'
#!/usr/bin/env bash
sql="$(cat)"
case "$sql" in
    "SHOW DATABASES"*) echo "wt_target" ;;
esac
exit 0
EOF
    chmod +x "$TMP_BIN/mysql"
    run "$STRAPS/mysql/db-clone" wt_target
    [ "$status" -eq 0 ]
    [[ "$output" == *"already exists; skipping"* ]]
}

@test "mysql db-drop drops if exists" {
    fake_mysql_absent
    run "$STRAPS/mysql/db-drop" wt_target
    [ "$status" -eq 0 ]
    grep -q "SQL: DROP DATABASE IF EXISTS \`wt_target\`;" "$MYSQL_LOG"
}

@test "mysql create lifecycle clones and rewrites DB_DATABASE" {
    fake_mysql_absent
    echo 'DB_DATABASE=source_db' > "$WTBS_WORKTREE_ROOT/.env"
    (
        cd "$WTBS_WORKTREE_ROOT"
        "$STRAPS/mysql/create"
    )
    grep -qx "DB_DATABASE=wt_feature_x" "$WTBS_WORKTREE_ROOT/.env"
    grep -q "DUMP ARGS: --host=127.0.0.1 --port=3306 --user=root --single-transaction source_db" "$MYSQL_LOG"
}

@test "mysql db-clone fatals without DB_DATABASE" {
    unset DB_DATABASE
    run "$STRAPS/mysql/db-clone" wt_target
    [ "$status" -ne 0 ]
    [[ "$output" == *"DB_DATABASE is not set"* ]]
}

# ── postgres strap ──────────────────────────────────────────────────────────

fake_pg_absent() {
    cat > "$TMP_BIN/psql" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null   # consume stdin so upstream pg_dump never gets SIGPIPE
echo "ARGS: $*" >> "$PG_LOG"
echo "PGPASSWORD=$PGPASSWORD" >> "$PG_LOG"
sql=""
prev=""
for a in "$@"; do [[ "$prev" == "-c" || "$prev" == "-tAc" ]] && sql="$a"; prev="$a"; done
echo "SQL: $sql" >> "$PG_LOG"
exit 0
EOF
    chmod +x "$TMP_BIN/psql"
    cat > "$TMP_BIN/pg_dump" <<'EOF'
#!/usr/bin/env bash
echo "DUMP ARGS: $*" >> "$PG_LOG"
echo "-- dump content"
EOF
    chmod +x "$TMP_BIN/pg_dump"
    export PG_LOG="$TMP_TEST_DIR/pg.log"
}

@test "postgres db-clone creates and clones with env credentials" {
    fake_pg_absent
    export DB_PORT=5432
    run "$STRAPS/postgres/db-clone" wt_target
    [ "$status" -eq 0 ]
    [[ "$output" == *"cloned source_db -> wt_target"* ]]
    grep -q 'SQL: CREATE DATABASE "wt_target";' "$PG_LOG"
    grep -q "DUMP ARGS: --host=127.0.0.1 --port=5432 --username=root source_db" "$PG_LOG"
    grep -q "PGPASSWORD=secret" "$PG_LOG"
}

@test "postgres db-drop uses the maintenance database" {
    fake_pg_absent
    export DB_PORT=5432 PG_MAINTENANCE_DB=admin_db
    run "$STRAPS/postgres/db-drop" wt_target
    [ "$status" -eq 0 ]
    grep -q -- "-d admin_db" "$PG_LOG"
    grep -q 'SQL: DROP DATABASE IF EXISTS "wt_target";' "$PG_LOG"
}

# ── auto-ports strap ────────────────────────────────────────────────────────

@test "auto-ports lib reuses a registered offset" {
    (
        source "$STRAPS/auto-ports/lib"
        port_in_use() { return 1; }
        local -A bases=([serve]=48000)
        local reg="$TMP_TEST_DIR/auto-ports.tsv"
        register_offset "$reg" "feature/x" 7
        [[ "$(allocate_offset "$reg" "feature/x" bases)" == "7" ]]
    )
}

@test "auto-ports lib reclaims a free offset before allocating a new one" {
    (
        source "$STRAPS/auto-ports/lib"
        port_in_use() { return 1; }
        local -A bases=([serve]=48000)
        local reg="$TMP_TEST_DIR/auto-ports.tsv"
        register_offset "$reg" "feature/other" 3
        [[ "$(allocate_offset "$reg" "feature/new" bases)" == "3" ]]
    )
}

@test "auto-ports lib allocates above the highest registered offset" {
    (
        source "$STRAPS/auto-ports/lib"
        port_in_use() { [[ "$1" == "48003" ]]; }
        local -A bases=([serve]=48000)
        local reg="$TMP_TEST_DIR/auto-ports.tsv"
        register_offset "$reg" "feature/other" 3
        [[ "$(allocate_offset "$reg" "feature/new" bases)" == "4" ]]
    )
}

@test "auto-ports default_base is deterministic and in range" {
    (
        source "$STRAPS/auto-ports/lib"
        [[ "$(default_base serve)" == "$(default_base serve)" ]]
        local b
        b="$(default_base serve)"
        (( b >= 20000 && b < 40000 ))
    )
}

@test "auto-ports create publishes namespaced state keys and destroy releases" {
    export WTBS_STRAP_ARGS_AUTO_PORTS="serve:48000;db:49000"
    export WTBS_STATE_FILE="$TMP_TEST_DIR/main/.wtbs/worktrees/feature_x.yml"
    run "$STRAPS/auto-ports/create"
    [ "$status" -eq 0 ]
    grep -qx "auto_ports.serve: 48001" "$WTBS_STATE_FILE"
    grep -qx "auto_ports.db: 49001" "$WTBS_STATE_FILE"
    [[ -f "$TMP_TEST_DIR/main/.wtbs/auto-ports.tsv" ]]
    run "$STRAPS/auto-ports/destroy"
    [ "$status" -eq 0 ]
    [[ ! -s "$TMP_TEST_DIR/main/.wtbs/auto-ports.tsv" ]]
}

@test "auto-ports create is a no-op without activation args" {
    unset WTBS_STRAP_ARGS_AUTO_PORTS 2>/dev/null || true
    export WTBS_STRAP_ARGS_AUTO_PORTS=""
    export WTBS_STATE_FILE="$TMP_TEST_DIR/main/.wtbs/worktrees/feature_x.yml"
    run "$STRAPS/auto-ports/create"
    [ "$status" -eq 0 ]
    [[ "$output" == "" ]]
}

@test "auto-ports create dry-run echoes state keys without writing them" {
    export WTBS_STRAP_ARGS_AUTO_PORTS="serve:48000"
    export WTBS_STATE_FILE="$TMP_TEST_DIR/main/.wtbs/worktrees/feature_x.yml"
    (
        export WTBS_DRY_RUN=1
        run "$STRAPS/auto-ports/create"
        [ "$status" -eq 0 ]
        [[ "$output" == *"[dry-run] state: auto_ports.serve: 48001"* ]]
    )
    [[ ! -e "$WTBS_STATE_FILE" ]]
}

# ── valet strap ─────────────────────────────────────────────────────────────

fake_valet() {
    cat > "$TMP_BIN/valet" <<'EOF'
#!/usr/bin/env bash
echo "valet $*" >> "$VALET_LOG"
EOF
    chmod +x "$TMP_BIN/valet"
    export VALET_LOG="$TMP_TEST_DIR/valet.log"
    export VALET_CONFIG="/nonexistent/valet-config.json"
}

@test "valet-site secures a short name as-is" {
    fake_valet
    export WTBS_WORKTREE_ROOT="$TMP_TEST_DIR/wt/myapp-feature-x"
    mkdir -p "$WTBS_WORKTREE_ROOT"
    echo 'APP_URL=https://ngrok-static.example' > "$WTBS_WORKTREE_ROOT/.env"
    ( cd "$WTBS_WORKTREE_ROOT" && "$STRAPS/valet/valet-site" secure myapp-feature-x )
    grep -qx "valet secure myapp-feature-x" "$VALET_LOG"
    # Framework-agnostic: the strap never touches the project .env.
    grep -qx "APP_URL=https://ngrok-static.example" "$WTBS_WORKTREE_ROOT/.env"
    [[ "$(ls "$TMP_TEST_DIR/wt")" == "myapp-feature-x" ]]
}

@test "valet-site truncates a long name and symlinks" {
    fake_valet
    local long="myapp-feature-shopify-oauth-space-selector-and-then-some-more"
    export WTBS_WORKTREE_ROOT="$TMP_TEST_DIR/wt/$long"
    mkdir -p "$WTBS_WORKTREE_ROOT"
    local output resolved
    output="$( cd "$WTBS_WORKTREE_ROOT" && "$STRAPS/valet/valet-site" secure "$long" 2>&1 )"
    [[ "$output" == *"too long for nginx"* ]]
    resolved="$(sed -E "s/.*serving as '([^']+)'.*/\1/" <<< "$output")"
    [[ "$resolved" != "$long" ]]
    [[ "$(cd "$WTBS_WORKTREE_ROOT" && "$STRAPS/valet/valet-site" url "$long")" == "https://$resolved.test" ]]
    grep -qx "valet secure $resolved" "$VALET_LOG"
    [[ -L "$TMP_TEST_DIR/wt/$resolved" ]]
    [[ "$(readlink "$TMP_TEST_DIR/wt/$resolved")" == "$WTBS_WORKTREE_ROOT" ]]
}

@test "valet-site unsecure removes the short symlink" {
    fake_valet
    local long="myapp-feature-shopify-oauth-space-selector-and-then-some-more"
    export WTBS_WORKTREE_ROOT="$TMP_TEST_DIR/wt/$long"
    mkdir -p "$WTBS_WORKTREE_ROOT"
    local resolved
    resolved="$( cd "$WTBS_WORKTREE_ROOT" && "$STRAPS/valet/valet-site" secure "$long" 2>&1 | sed -E "s/.*serving as '([^']+)'.*/\1/")"
    ( cd "$WTBS_WORKTREE_ROOT" && "$STRAPS/valet/valet-site" unsecure "$long" )
    grep -qx "valet unsecure $resolved" "$VALET_LOG"
    [[ ! -e "$TMP_TEST_DIR/wt/$resolved" ]]
}

@test "valet-site url reads tld and domain keys from valet config" {
    fake_valet
    export VALET_CONFIG="$TMP_TEST_DIR/valet-config.json"
    echo '{ "tld": "develop" }' > "$VALET_CONFIG"
    export WTBS_WORKTREE_ROOT="$TMP_TEST_DIR/wt/myapp-feature-x"
    mkdir -p "$WTBS_WORKTREE_ROOT"
    [[ "$(cd "$WTBS_WORKTREE_ROOT" && "$STRAPS/valet/valet-site" url myapp-feature-x)" == "https://myapp-feature-x.develop" ]]
    echo '{ "domain": "develop", "paths": [] }' > "$VALET_CONFIG"
    [[ "$(cd "$WTBS_WORKTREE_ROOT" && "$STRAPS/valet/valet-site" url myapp-feature-x)" == "https://myapp-feature-x.develop" ]]
}

@test "valet-site records valet.url in the wtbs state file, never the project .env" {
    fake_valet
    export WTBS_WORKTREE_ROOT="$TMP_TEST_DIR/wt/myapp-feature-x"
    export WTBS_STATE_FILE="$TMP_TEST_DIR/main/.wtbs/worktrees/feature_x.yml"
    mkdir -p "$WTBS_WORKTREE_ROOT"
    echo 'APP_URL=https://ngrok-static.example' > "$WTBS_WORKTREE_ROOT/.env"
    ( cd "$WTBS_WORKTREE_ROOT" && "$STRAPS/valet/valet-site" secure myapp-feature-x )
    grep -qx "valet.url: https://myapp-feature-x.test" "$WTBS_STATE_FILE"
    grep -qx "APP_URL=https://ngrok-static.example" "$WTBS_WORKTREE_ROOT/.env"
    ! grep -q 'VALET_URL' "$WTBS_WORKTREE_ROOT/.env"
    ( cd "$WTBS_WORKTREE_ROOT" && "$STRAPS/valet/valet-site" secure myapp-feature-x )
    [[ "$(grep -c '^valet\.url:' "$WTBS_STATE_FILE")" -eq 1 ]]
}

# ── ngrok strap guard ───────────────────────────────────────────────────────

@test "ngrok-guard permits sharing from the main repo" {
    export WTBS_WORKTREE_ROOT="$WTBS_MAIN_REPO" NGROK_SHARED_URL=x.ngrok.dev
    run "$STRAPS/ngrok/ngrok-guard"
    [ "$status" -eq 0 ]
}

@test "ngrok-guard rejects a worktree steal by default" {
    export NGROK_SHARED_URL=x.ngrok.dev
    run "$STRAPS/ngrok/ngrok-guard"
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing to hand https://x.ngrok.dev to 'wt'"* ]]
    [[ "$output" == *"registered to: main"* ]]
    [[ "$output" == *'sites: "main,wt"'* ]]
    [[ "$output" == *"~/.config/wtbs/settings.yml"* ]]
}

@test "ngrok-guard permits a registered worktree" {
    export NGROK_SHARED_URL=x.ngrok.dev NGROK_SITES="main,wt"
    run "$STRAPS/ngrok/ngrok-guard"
    [ "$status" -eq 0 ]
}

@test "ngrok-guard rejects an unregistered site even with a list" {
    export NGROK_SHARED_URL=x.ngrok.dev NGROK_SITES="main,other-site"
    run "$STRAPS/ngrok/ngrok-guard"
    [ "$status" -eq 1 ]
}

@test "ngrok-guard prefers project strap.yml sites over user settings" {
    export NGROK_SHARED_URL=x.ngrok.dev NGROK_SITES="main,other-site"
    # The hermetic ngrok strap has no sites: in its strap.yml — env wins.
    run "$STRAPS/ngrok/ngrok-guard"
    [ "$status" -eq 1 ]
    # A customized copy declaring sites permits.
    local custom="$WTBS_MAIN_REPO/.wtbs/straps/ngrok"
    mkdir -p "$custom"
    cp "$STRAPS/ngrok/ngrok-guard" "$custom/"
    printf 'sites: "main,wt"\n' > "$custom/strap.yml"
    run "$custom/ngrok-guard"
    [ "$status" -eq 0 ]
}

@test "ngrok-guard permits everything from a customized strap" {
    local custom="$WTBS_MAIN_REPO/.wtbs/straps/ngrok"
    mkdir -p "$custom"
    cp "$STRAPS/ngrok/ngrok-guard" "$custom/"
    export NGROK_SHARED_URL=x.ngrok.dev
    run "$custom/ngrok-guard"
    [ "$status" -eq 0 ]
}
