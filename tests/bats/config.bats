#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../../lib/utils.sh"
    source "$BATS_TEST_DIRNAME/../../lib/env.sh"
    source "$BATS_TEST_DIRNAME/../../lib/config.sh"
    export TMP_CONFIG="$(mktemp).yml"
    cat > "$TMP_CONFIG" <<'EOF'
straps:
  - sqlite
copy:
  ignore:
    - node_modules
db_name: "myapp_{branch_slug}"
ports:
  app: 8080
  db: 33060
hooks:
  create:
    - "echo hi {branch_slug}"
aliases:
  test: "echo test"
EOF
}

teardown() {
    rm -f "$TMP_CONFIG"
}

@test "load_config reads yaml via python3" {
    load_config "$TMP_CONFIG"
    [[ "$(get_config db_name)" == 'myapp_{branch_slug}' ]]
    [[ "$(get_config ports.app)" == "8080" ]]
    [[ "$(get_config aliases.test)" == "echo test" ]]
}

@test "config_list collects list entries in order" {
    load_config "$TMP_CONFIG"
    local -a straps=() copy=() create=()
    config_list straps straps
    config_list copy.ignore copy
    config_list hooks.create create
    [[ "${straps[0]}" == "sqlite" ]]
    [[ "${copy[0]}" == "node_modules" ]]
    [[ "${create[0]}" == 'echo hi {branch_slug}' ]]
}

@test "get_config returns empty for missing path" {
    load_config "$TMP_CONFIG"
    [[ -z "$(get_config does.not.exist)" ]]
}

@test "apply_defaults only defaults db_name" {
    load_config "/nonexistent/config.yml"
    apply_defaults
    [[ "$(get_config db_name)" == 'wt_{branch_slug}' ]]
    # No framework defaults may leak in.
    [[ -z "$(get_config ports.app)" ]]
    [[ -z "$(get_config hooks.create[0])" ]]
    [[ -z "$(get_config copy[0])" ]]
}

@test "reject_legacy_keys fatals on v0.3 config keys" {
    cat > "$TMP_CONFIG" <<'EOF'
database:
  driver: mysql
commands:
  install:
    - npm ci
EOF
    load_config "$TMP_CONFIG"
    run reject_legacy_keys
    [ "$status" -eq 1 ]
    [[ "$output" == *"v0.5 config surface"* ]]
    [[ "$output" == *"examples/"* ]]
}

@test "reject_legacy_keys fatals on v0.4 env and copy list keys" {
    # docs/adr/0007+0008: env: moved into straps, copy: became a residue
    # mirror — the old forms are rejected with a migration pointer.
    cat > "$TMP_CONFIG" <<'EOF'
copy: [.env]
env:
  APP_PORT: "8080"
EOF
    load_config "$TMP_CONFIG"
    run reject_legacy_keys
    [ "$status" -eq 1 ]
    [[ "$output" == *"copy[0]"* ]]
    [[ "$output" == *"env.APP_PORT"* ]]
    [[ "$output" == *"v0.5 config surface"* ]]
}

@test "reject_legacy_keys accepts the v0.5 surface" {
    load_config "$TMP_CONFIG"
    reject_legacy_keys
}

@test "compute_db_name renders the configured template" {
    load_config "$TMP_CONFIG"
    apply_defaults
    [[ "$(compute_db_name feature/foo-bar feature_foo_bar)" == "myapp_feature_foo_bar" ]]
}

@test "compute_db_name uses the default template" {
    load_config "/nonexistent/config.yml"
    apply_defaults
    [[ "$(compute_db_name feature/foo feature_foo)" == "wt_feature_foo" ]]
}

@test "render_template substitutes context keys" {
    local -A ctx=(
        [branch]=feature/foo-bar
        [branch_slug]=feature_foo_bar
        [site]=mysite
        [db_name]=wt_feature_foo_bar
        [worktree_root]=/tmp/wt
        [main_repo]=/tmp/main
        [ports.app]=8081
        [ports.db]=33061
    )
    local rendered
    rendered="$(render_template 'wt_{branch_slug}_{ports.app}' ctx)"
    [[ "$rendered" == "wt_feature_foo_bar_8081" ]]
    rendered="$(render_template '{db_name} {worktree_root} {main_repo} {site} {branch}' ctx)"
    [[ "$rendered" == "wt_feature_foo_bar /tmp/wt /tmp/main mysite feature/foo-bar" ]]
}

@test "render_env_refs substitutes existing env values" {
    local env_file="$(mktemp)"
    printf 'DATABASE_URL=postgres://main\nQUOTED="some value"\n' > "$env_file"
    local rendered
    rendered="$(render_env_refs 'PARENT={env.DATABASE_URL} MISSING={env.NOPE} Q={env.QUOTED}' "$env_file")"
    [[ "$rendered" == "PARENT=postgres://main MISSING= Q=some value" ]]
    rm -f "$env_file"
}

@test "export_user_settings exports namespaced keys as env vars" {
    local settings
    settings="$(mktemp).yml"
    cat > "$settings" <<'EOF'
ngrok:
  shared_url: franki.ngrok.dev
  share_port: 8787
EOF
    (
        export WTBS_SETTINGS_FILE="$settings"
        unset NGROK_SHARED_URL NGROK_SHARE_PORT 2>/dev/null || true
        export_user_settings
        [[ "$NGROK_SHARED_URL" == "franki.ngrok.dev" ]]
        [[ "$NGROK_SHARE_PORT" == "8787" ]]
    )
    rm -f "$settings"
}

@test "export_user_settings is a no-op without a settings file" {
    (
        export WTBS_SETTINGS_FILE="/nonexistent/settings.yml"
        export_user_settings
    )
}
