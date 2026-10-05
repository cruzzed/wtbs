#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../../lib/utils.sh"
    source "$BATS_TEST_DIRNAME/../../lib/env.sh"
    export TMP_ENV="$(mktemp)"
    cat > "$TMP_ENV" <<EOF
DB_HOST=127.0.0.1
DB_DATABASE=main_app
APP_PORT=8080
EOF
}

teardown() {
    rm -f "$TMP_ENV"
}

@test "env_value reads unquoted values" {
    [[ "$(env_value "$TMP_ENV" DB_DATABASE)" == "main_app" ]]
}

@test "env_value reads quoted values" {
    cat > "$TMP_ENV" <<EOF
FOO="hello world"
BAR='single quotes'
EOF
    [[ "$(env_value "$TMP_ENV" FOO)" == "hello world" ]]
    [[ "$(env_value "$TMP_ENV" BAR)" == "single quotes" ]]
}

@test "update_env_key updates existing key" {
    update_env_key "$TMP_ENV" APP_PORT 9090
    [[ "$(env_value "$TMP_ENV" APP_PORT)" == "9090" ]]
}

@test "update_env_key appends missing key" {
    update_env_key "$TMP_ENV" NEW_KEY xyz
    [[ "$(env_value "$TMP_ENV" NEW_KEY)" == "xyz" ]]
}

@test "env_value strips carriage returns from CRLF files" {
    printf 'CRLF_KEY=windows-value\r\n' > "$TMP_ENV"
    [[ "$(env_value "$TMP_ENV" CRLF_KEY)" == "windows-value" ]]
}
