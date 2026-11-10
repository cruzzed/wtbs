#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../../lib/utils.sh"
    export TMP_SCAN="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_SCAN"
}

write_script() {
    # write_script <name> [heredoc on stdin]
    cat > "$TMP_SCAN/$1"
}

@test "danger_scan passes clean scripts and missing files" {
    write_script clean.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "hello"
wtbs_remove_file "$1"
EOF
    danger_scan "$TMP_SCAN/clean.sh"
    danger_scan "$TMP_SCAN/does-not-exist.sh"
}

@test "danger_scan flags recursive rm" {
    write_script bad.sh <<'EOF'
#!/usr/bin/env bash
rm -rf "$TARGET_DIR"
EOF
    run danger_scan "$TMP_SCAN/bad.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"recursive-delete"* ]]
}

@test "danger_scan flags sudo, find -delete, force push, mkfs, dd" {
    write_script sudo.sh <<'EOF'
#!/usr/bin/env bash
sudo valet secure x
EOF
    run danger_scan "$TMP_SCAN/sudo.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"sudo"* ]]

    write_script finddel.sh <<'EOF'
#!/usr/bin/env bash
find . -name '*.log' -delete
EOF
    run danger_scan "$TMP_SCAN/finddel.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"find-delete"* ]]

    write_script push.sh <<'EOF'
#!/usr/bin/env bash
git push --force origin main
EOF
    run danger_scan "$TMP_SCAN/push.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"force-push"* ]]

    write_script mkfs.sh <<'EOF'
#!/usr/bin/env bash
mkfs.ext4 /dev/sda1
EOF
    run danger_scan "$TMP_SCAN/mkfs.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"disk-destroy"* ]]

    write_script dd.sh <<'EOF'
#!/usr/bin/env bash
dd if=/dev/zero of=/dev/sda bs=1M
EOF
    run danger_scan "$TMP_SCAN/dd.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"device-write"* ]]
}

@test "danger_scan skips comment lines" {
    write_script commented.sh <<'EOF'
#!/usr/bin/env bash
# Example of what NOT to do: rm -rf /
# sudo make me a sandwich
echo fine
EOF
    danger_scan "$TMP_SCAN/commented.sh"
}

@test "danger_scan honors the wtbs:danger-ok directive per line" {
    write_script opted.sh <<'EOF'
#!/usr/bin/env bash
rm -rf /tmp/known-scratch  # wtbs:danger-ok teardown of our own scratch dir
echo done
EOF
    danger_scan "$TMP_SCAN/opted.sh"
}

@test "danger_scan follows same-dir sources one level" {
    write_script main.sh <<'EOF'
#!/usr/bin/env bash
source ./lib.sh
echo main
EOF
    write_script lib.sh <<'EOF'
#!/usr/bin/env bash
rm -rf "$X"
EOF
    run danger_scan "$TMP_SCAN/main.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"lib.sh"* ]]
}

@test "danger_scan does not follow sources outside the script's directory" {
    mkdir "$TMP_SCAN/outside"
    write_script main2.sh <<'EOF'
#!/usr/bin/env bash
source ../outside/evil.sh
echo main
EOF
    cat > "$TMP_SCAN/outside/evil.sh" <<'EOF'
#!/usr/bin/env bash
rm -rf "$X"
EOF
    danger_scan "$TMP_SCAN/main2.sh"
}

@test "danger_scan only follows sources one level deep" {
    write_script a.sh <<'EOF'
#!/usr/bin/env bash
source ./b.sh
EOF
    write_script b.sh <<'EOF'
#!/usr/bin/env bash
source ./c.sh
EOF
    write_script c.sh <<'EOF'
#!/usr/bin/env bash
rm -rf "$X"
EOF
    # Depth-2 content is intentionally not scanned; pin that behavior.
    danger_scan "$TMP_SCAN/a.sh"
}

@test "WTBS_ALLOW_DANGEROUS=1 skips scanning with a warning" {
    write_script badd.sh <<'EOF'
#!/usr/bin/env bash
rm -rf "$X"
EOF
    run env WTBS_ALLOW_DANGEROUS=1 bash -c \
        'source "$0/../../lib/utils.sh"; danger_scan "$1"' \
        "$BATS_TEST_DIRNAME" "$TMP_SCAN/badd.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WTBS_ALLOW_DANGEROUS"* ]]
}

@test "bundled straps pass the danger scan" {
    local strap_file
    for strap_file in "$BATS_TEST_DIRNAME"/../../straps/*/*; do
        [[ -f "$strap_file" ]] || continue
        case "$strap_file" in
            *.yml|*.md) continue ;;
        esac
        danger_scan "$strap_file"
    done
}
