#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../../lib/utils.sh"
    source "$BATS_TEST_DIRNAME/../../lib/env.sh"
    source "$BATS_TEST_DIRNAME/../../lib/config.sh"
    source "$BATS_TEST_DIRNAME/../../lib/ports.sh"
    export TMP_REG="$(mktemp)"
    mkdir -p "$(dirname "$TMP_REG")"
}

teardown() {
    rm -f "$TMP_REG"
}

@test "state_put and state_get round-trip branch state" {
    state_put "$TMP_REG" "feature/test" "db_test"
    [[ "$(state_get "$TMP_REG" "feature/test" db)" == "db_test" ]]
}

@test "state_put updates only the exact branch entry" {
    printf '%s\t%s\t%s\n' "feature.test" "db_test" "2026-08-01T00:00:00" > "$TMP_REG"
    printf '%s\t%s\t%s\n' "featureXtest" "db_test2" "2026-08-01T00:00:00" >> "$TMP_REG"
    state_put "$TMP_REG" "feature.test" "db_test_new"
    [[ "$(awk -F'\t' '$1 == "feature.test"' "$TMP_REG" | wc -l)" -eq 1 ]]
    [[ "$(awk -F'\t' '$1 == "featureXtest"' "$TMP_REG" | wc -l)" -eq 1 ]]
    [[ "$(state_get "$TMP_REG" "feature.test" db)" == "db_test_new" ]]
}

@test "state_put dry-run does not modify the registry" {
    printf '%s\t%s\t%s\n' "feature/test" "db_test" "2026-08-01T00:00:00" > "$TMP_REG"
    state_put "$TMP_REG" "feature/test" "db_test_new" "1"
    [[ "$(state_get "$TMP_REG" "feature/test" db)" == "db_test" ]]
}

@test "state_get returns empty for an unregistered branch" {
    [[ -z "$(state_get "$TMP_REG" "feature/nope" db)" ]]
}

@test "state_delete removes the branch row" {
    state_put "$TMP_REG" "feature/test" "db_test"
    state_put "$TMP_REG" "feature/other" "db_other"
    state_delete "$TMP_REG" "feature/test"
    [[ -z "$(state_get "$TMP_REG" "feature/test" db)" ]]
    [[ "$(state_get "$TMP_REG" "feature/other" db)" == "db_other" ]]
}

@test "state_delete is a no-op without a registry" {
    state_delete "/nonexistent/registry.tsv" "feature/test"
}

@test "load_state_into_ctx exposes dotted keys as namespaced tokens" {
    local f
    f="$(mktemp)"
    printf 'valet.url: https://short-name.develop\nauto_ports.serve: 8001\n' > "$f"
    local -A ctx=()
    load_state_into_ctx "$f" ctx
    [[ "${ctx[valet.url]}" == "https://short-name.develop" ]]
    [[ "${ctx[auto_ports.serve]}" == "8001" ]]
    load_state_into_ctx "/nonexistent.yml" ctx
    [[ -z "${ctx[missing]:-}" ]]
    rm -f "$f"
}

@test "state_file_path is branch-scoped under the wtbs state dir" {
    [[ "$(state_file_path /main feature_x)" == "/main/.wtbs/worktrees/feature_x.yml" ]]
}
