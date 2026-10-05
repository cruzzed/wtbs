#!/usr/bin/env bats

# Tests for the bundled strap scripts (straps/*). The scripts are standalone:
# they run with fake client binaries on PATH and DB_* / WTBS_* env vars set,
# exactly as the hook environment provides them.

setup() {
    # Hermetic copy of the bundled straps: this environment may normalize the
    # executable bits of untracked repo files between processes, and the
    # scripts must be executable to run.
    export STRAPS="$(mktemp -d)"
    cp -R "$BATS_TEST_DIRNAME/../../straps/." "$STRAPS/"
    chmod 755 "$STRAPS"/*/db-clone "$STRAPS"/*/db-drop \
        "$STRAPS"/valet/valet-check-name "$STRAPS"/ngrok/ngrok-share "$STRAPS"/ngrok/ngrok-guard
    export TMP_BIN="$(mktemp -d)"
    export TMP_TEST_DIR="$(mktemp -d)"
    export PATH="$TMP_BIN:$PATH"
    export DB_HOST=127.0.0.1 DB_PORT=3306 DB_USERNAME=root DB_PASSWORD=secret
    export DB_DATABASE=source_db
    export WTBS_MAIN_REPO="$TMP_TEST_DIR/main"
    export WTBS_WORKTREE_ROOT="$TMP_TEST_DIR/wt"
    export WTBS_SITE=wt
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

@test "sqlite db-clone --force re-clones an existing target" {
    echo "data" > "$WTBS_MAIN_REPO/db.sqlite3"
    echo "existing" > "$WTBS_WORKTREE_ROOT/wt_branch.sqlite"
    run "$STRAPS/sqlite/db-clone" db.sqlite3 "$WTBS_WORKTREE_ROOT/wt_branch.sqlite" --force
    [ "$status" -eq 0 ]
    [[ "$(cat "$WTBS_WORKTREE_ROOT/wt_branch.sqlite")" == "data" ]]
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
    # No fake sqlite3 on PATH; the real one is absent on this machine too.
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

# ── mysql strap ─────────────────────────────────────────────────────────────

fake_mysql_absent() {
    # mysql: SHOW DATABASES finds nothing; logs args/env and swallows SQL.
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
    # Maintenance queries go to the maintenance db.
    grep -q "postgres -tAc SELECT 1 FROM pg_database" "$PG_LOG" \
        || grep -q -- "-d postgres -tAc" "$PG_LOG"
}

@test "postgres db-drop uses the maintenance database" {
    fake_pg_absent
    export DB_PORT=5432 PG_MAINTENANCE_DB=admin_db
    run "$STRAPS/postgres/db-drop" wt_target
    [ "$status" -eq 0 ]
    grep -q -- "-d admin_db" "$PG_LOG"
    grep -q 'SQL: DROP DATABASE IF EXISTS "wt_target";' "$PG_LOG"
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
    [[ "$output" == *'NGROK_SITES="main,wt"'* ]]
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

@test "ngrok-guard permits everything from a customized strap" {
    local custom="$WTBS_MAIN_REPO/.wtbs/straps/ngrok"
    mkdir -p "$custom"
    cp "$STRAPS/ngrok/ngrok-guard" "$custom/"
    export NGROK_SHARED_URL=x.ngrok.dev
    run "$custom/ngrok-guard"
    [ "$status" -eq 0 ]
}
