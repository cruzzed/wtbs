#!/usr/bin/env bats

# Tests for lib/strap-lib.sh — the pen the core lends straps
# (docs/adr/0007). Sourced the way strap scripts source it; WTBS_STATE_FILE
# points at a temp file.

setup() {
    export WTBS_LIB_DIR="$BATS_TEST_DIRNAME/../../lib"
    source "$WTBS_LIB_DIR/strap-lib.sh"
    export TMP_DIR="$(mktemp -d)"
    export WTBS_STATE_FILE="$TMP_DIR/state.yml"
    export WTBS_ENV_FILE="$TMP_DIR/.env"
}

teardown() {
    rm -rf "$TMP_DIR"
    unset WTBS_DRY_RUN WTBS_ENV_FILE WTBS_STATE_FILE
}

# ── wtbs_env_set ────────────────────────────────────────────────────────────

@test "wtbs_env_set updates an existing key" {
    printf 'A=1\nB=2\n' > "$WTBS_ENV_FILE"
    wtbs_env_set B 3
    [[ "$(env_value "$WTBS_ENV_FILE" B)" == "3" ]]
    [[ "$(env_value "$WTBS_ENV_FILE" A)" == "1" ]]
    [[ "$(wc -l < "$WTBS_ENV_FILE")" -eq 2 ]]
}

@test "wtbs_env_set appends a missing key" {
    printf 'A=1\n' > "$WTBS_ENV_FILE"
    wtbs_env_set NEW_KEY xyz
    [[ "$(env_value "$WTBS_ENV_FILE" NEW_KEY)" == "xyz" ]]
    grep -qx "NEW_KEY=xyz" "$WTBS_ENV_FILE"
}

@test "wtbs_env_set creates the file when missing" {
    [[ ! -e "$WTBS_ENV_FILE" ]]
    wtbs_env_set FRESH created
    [[ "$(env_value "$WTBS_ENV_FILE" FRESH)" == "created" ]]
}

@test "wtbs_env_set defaults to ./.env under the current directory" {
    (
        cd "$TMP_DIR"
        unset WTBS_ENV_FILE
        wtbs_env_set LOCAL_KEY local_value
        grep -qx "LOCAL_KEY=local_value" ./.env
    )
}

@test "wtbs_env_set dry-run echoes the line without writing" {
    printf 'A=1\n' > "$WTBS_ENV_FILE"
    local out
    out="$(
        export WTBS_DRY_RUN=1
        wtbs_env_set A 9
    )"
    [[ "$out" == "[dry-run] env: A=9" ]]
    [[ "$(env_value "$WTBS_ENV_FILE" A)" == "1" ]]
}

# ── wtbs_state_set ──────────────────────────────────────────────────────────

@test "wtbs_state_set writes a key to the state file" {
    wtbs_state_set probe.value hello
    grep -qx "probe.value: hello" "$WTBS_STATE_FILE"
}

@test "wtbs_state_set replaces a key idempotently" {
    wtbs_state_set probe.value first
    wtbs_state_set probe.value second
    [[ "$(grep -c '^probe\.value:' "$WTBS_STATE_FILE")" -eq 1 ]]
    [[ "$(wtbs_state_get probe.value)" == "second" ]]
}

@test "wtbs_state_set keeps other keys when replacing" {
    wtbs_state_set probe.a 1
    wtbs_state_set probe.b 2
    wtbs_state_set probe.a 3
    [[ "$(wtbs_state_get probe.b)" == "2" ]]
    [[ "$(wtbs_state_get probe.a)" == "3" ]]
}

@test "wtbs_state_set dry-run echoes without writing" {
    local out
    out="$(
        export WTBS_DRY_RUN=1
        wtbs_state_set probe.value ghost
    )"
    [[ "$out" == "[dry-run] state: probe.value: ghost" ]]
    [[ ! -e "$WTBS_STATE_FILE" ]]
}

@test "wtbs_state_set rejects invalid keys" {
    run wtbs_state_set "BAD KEY" x
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid key"* ]]
}

# ── wtbs_state_get ──────────────────────────────────────────────────────────

@test "wtbs_state_get returns the value for a published key" {
    wtbs_state_set probe.hit bullseye
    [[ "$(wtbs_state_get probe.hit)" == "bullseye" ]]
}

@test "wtbs_state_get returns empty for a missing key or file" {
    [[ -z "$(wtbs_state_get probe.miss)" ]]
    WTBS_STATE_FILE="$TMP_DIR/nonexistent.yml"
    [[ -z "$(wtbs_state_get probe.hit)" ]]
}
