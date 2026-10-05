#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../../lib/utils.sh"
    source "$BATS_TEST_DIRNAME/../../lib/env.sh"
    source "$BATS_TEST_DIRNAME/../../lib/config.sh"
    source "$BATS_TEST_DIRNAME/../../lib/ports.sh"
    # Make port availability deterministic regardless of host state.
    port_in_use() { return 1; }
    export TMP_REG="$(mktemp)"
    mkdir -p "$(dirname "$TMP_REG")"
}

teardown() {
    rm -f "$TMP_REG"
}

@test "compute_ports calculates offsets" {
    local -A base=([app]=8080 [db]=33060 [serve]=8000)
    local -A result
    compute_ports 5 base result
    [[ "${result[app]}" -eq 8085 ]]
    [[ "${result[db]}" -eq 33065 ]]
}

@test "collect_base_ports reads declared ports from the config" {
    CONFIG=()
    CONFIG["ports.app"]="8080"
    CONFIG["ports.serve"]="8000"
    CONFIG["env.OTHER"]="ignored"
    local -A base
    collect_base_ports base
    [[ "${#base[@]}" -eq 2 ]]
    [[ "${base[app]}" == "8080" ]]
    [[ "${base[serve]}" == "8000" ]]
}

@test "offset_ports_available checks every declared port" {
    local -A checked=()
    port_in_use() { checked["$1"]=1; return 1; }
    local -A base=([app]=8080 [db]=33060 [serve]=8000)
    offset_ports_available 1 base
    [[ -n "${checked[8081]:-}" ]]
    [[ -n "${checked[33061]:-}" ]]
    [[ -n "${checked[8001]:-}" ]]
}

@test "offset_ports_available fails when any declared port is busy" {
    port_in_use() { [[ "$1" == "33061" ]]; }
    local -A base=([app]=8080 [db]=33060)
    ! offset_ports_available 1 base
}

@test "allocate_offset returns 1 for empty registry" {
    local -A base=([app]=8080)
    local offset
    offset="$(allocate_offset "$TMP_REG" "feature/test" base)"
    [[ "$offset" == "1" ]]
}

@test "allocate_offset reuses existing branch offset" {
    local -A base=([app]=8080)
    printf '%s\t%s\t%s\t%s\n' "feature/test" "7" "db_test" "2026-08-01T00:00:00" > "$TMP_REG"
    local offset
    offset="$(allocate_offset "$TMP_REG" "feature/test" base)"
    [[ "$offset" == "7" ]]
}

@test "allocate_offset matches branch names with regex metacharacters literally" {
    local -A base=([app]=8080)
    printf '%s\t%s\t%s\t%s\n' "feature.test" "7" "db_test" "2026-08-01T00:00:00" > "$TMP_REG"
    printf '%s\t%s\t%s\t%s\n' "featureXtest" "8" "db_test2" "2026-08-01T00:00:00" >> "$TMP_REG"
    local offset
    offset="$(allocate_offset "$TMP_REG" "feature.test" base)"
    [[ "$offset" == "7" ]]
}

@test "allocate_offset reclaims a free registered offset" {
    local -A base=([app]=8080)
    printf '%s\t%s\t%s\t%s\n' "feature/a" "3" "db_a" "2026-08-01T00:00:00" > "$TMP_REG"
    local offset
    offset="$(allocate_offset "$TMP_REG" "feature/b" base)"
    [[ "$offset" == "3" ]]
}

@test "allocate_offset allocates above the highest offset when registered ones are busy" {
    port_in_use() { [[ "$1" == "8083" ]]; }
    local -A base=([app]=8080)
    printf '%s\t%s\t%s\t%s\n' "feature/a" "3" "db_a" "2026-08-01T00:00:00" > "$TMP_REG"
    local offset
    offset="$(allocate_offset "$TMP_REG" "feature/b" base)"
    [[ "$offset" == "4" ]]
}

@test "state_put and state_get round-trip branch state" {
    state_put "$TMP_REG" "feature/test" "5" "db_test"
    [[ "$(state_get "$TMP_REG" "feature/test" offset)" == "5" ]]
    [[ "$(state_get "$TMP_REG" "feature/test" db)" == "db_test" ]]
}

@test "state_put updates only the exact branch entry" {
    printf '%s\t%s\t%s\t%s\n' "feature.test" "7" "db_test" "2026-08-01T00:00:00" > "$TMP_REG"
    printf '%s\t%s\t%s\t%s\n' "featureXtest" "8" "db_test2" "2026-08-01T00:00:00" >> "$TMP_REG"
    state_put "$TMP_REG" "feature.test" "9" "db_test_new"
    [[ "$(awk -F'\t' '$1 == "feature.test"' "$TMP_REG" | wc -l)" -eq 1 ]]
    [[ "$(awk -F'\t' '$1 == "featureXtest"' "$TMP_REG" | wc -l)" -eq 1 ]]
    [[ "$(state_get "$TMP_REG" "feature.test" offset)" == "9" ]]
}

@test "state_put dry-run does not modify the registry" {
    printf '%s\t%s\t%s\t%s\n' "feature/test" "7" "db_test" "2026-08-01T00:00:00" > "$TMP_REG"
    state_put "$TMP_REG" "feature/test" "9" "db_test_new" "1"
    [[ "$(state_get "$TMP_REG" "feature/test" offset)" == "7" ]]
}

@test "state_get returns empty for an unregistered branch" {
    [[ -z "$(state_get "$TMP_REG" "feature/nope" offset)" ]]
}

@test "state_delete removes the branch row" {
    state_put "$TMP_REG" "feature/test" "5" "db_test"
    state_put "$TMP_REG" "feature/other" "6" "db_other"
    state_delete "$TMP_REG" "feature/test"
    [[ -z "$(state_get "$TMP_REG" "feature/test" offset)" ]]
    [[ "$(state_get "$TMP_REG" "feature/other" offset)" == "6" ]]
}

@test "state_delete is a no-op without a registry" {
    state_delete "/nonexistent/registry.tsv" "feature/test"
}
