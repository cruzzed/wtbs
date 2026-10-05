#!/usr/bin/env bats

setup() {
    export TMP_ORIGIN="$(mktemp -d)"
    export SCRIPT="$BATS_TEST_DIRNAME/../../wtbs.sh"
    # Hermetic: no user settings (~/.config/wtbs/settings.yml) during tests.
    export WTBS_SETTINGS_FILE="/nonexistent/wtbs-settings.yml"
    export WT="${TMP_ORIGIN}-feature-exec"
    cd "$TMP_ORIGIN"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"
    # This machine sets core.autocrlf=true globally; committed scripts must
    # keep LF endings or their shebangs break in worktree checkouts.
    git config core.autocrlf false
    cat > .wtbs.yml <<'EOF'
aliases:
  whereami: "pwd > whereami.out"
  greet: "echo hello"
  envvar: "echo $SECRET_KEY"
  fail3: "exit 3"
EOF
    mkdir -p .wtbs
    cat > .wtbs/mkpreset <<'EOF'
#!/usr/bin/env bash
echo "preset:$WTBS_BRANCH_SLUG:$1" > preset.out
EOF
    cat > .wtbs/shadow <<'EOF'
#!/usr/bin/env bash
echo from-main
EOF
    # A project strap whose scripts must land on PATH during exec.
    mkdir -p .wtbs/straps/toolstrap
    cat > .wtbs/straps/toolstrap/strap.yml <<'EOF'
# private config — the core never reads this
EOF
    cat > .wtbs/straps/toolstrap/strap-tool <<'EOF'
#!/usr/bin/env bash
echo strap-tool-ran "$@"
EOF
    chmod +x .wtbs/straps/toolstrap/strap-tool
    git add -A
    git commit -q -m "initial"
    git branch feature/exec
    git worktree add -q "$WT" feature/exec
    printf 'SECRET_KEY=from-env\n' > "$WT/.env"
    # Branch state lives in the registry (branch, db name, date).
    mkdir -p .wtbs
    printf 'feature/exec\ttest_feature_exec\t2026-01-01T00:00:00\n' > .wtbs/registry.tsv
}

teardown() {
    rm -rf "$TMP_ORIGIN" "$WT"
}

@test "exec runs an alias in the worktree directory" {
    run "$SCRIPT" exec feature/exec whereami
    [ "$status" -eq 0 ]
    [ -f "$WT/whereami.out" ]
    grep -qx "$WT" "$WT/whereami.out"
}

@test "shorthand form behaves like exec" {
    run "$SCRIPT" feature/exec whereami
    [ "$status" -eq 0 ]
    [ -f "$WT/whereami.out" ]
}

@test "exec appends extra args to an alias" {
    run "$SCRIPT" exec feature/exec greet world
    [ "$status" -eq 0 ]
    [[ "$output" == *"hello world"* ]]
}

@test "exec falls back to raw commands" {
    run "$SCRIPT" exec feature/exec echo raw done
    [ "$status" -eq 0 ]
    [[ "$output" == *"raw done"* ]]
}

@test "exec prepends the worktree .venv/bin to PATH" {
    mkdir -p "$WT/.venv/bin"
    printf '#!/usr/bin/env bash\necho faketool-ran\n' > "$WT/.venv/bin/faketool"
    chmod +x "$WT/.venv/bin/faketool"
    run "$SCRIPT" exec feature/exec faketool
    [ "$status" -eq 0 ]
    [[ "$output" == *"faketool-ran"* ]]
}

@test "exec exports the worktree .env" {
    run "$SCRIPT" exec feature/exec envvar
    [ "$status" -eq 0 ]
    [[ "$output" == *"from-env"* ]]
}

@test "exec fails for an unknown worktree" {
    run "$SCRIPT" exec feature/nope whereami
    [ "$status" -ne 0 ]
    [[ "$output" == *"no worktree found"* ]]
}

@test "exec --dry-run prints the command without running it" {
    run "$SCRIPT" --dry-run exec feature/exec whereami
    [ "$status" -eq 0 ]
    [[ "$output" == *"would run: pwd > whereami.out"* ]]
    [ ! -e "$WT/whereami.out" ]
}

@test "exec with no command lists straps, verbs, presets and aliases" {
    cat > .wtbs.yml <<'EOF'
straps: [toolstrap]
aliases:
  whereami: "pwd > whereami.out"
  greet: "echo hello"
EOF
    run "$SCRIPT" exec feature/exec
    [ "$status" -eq 0 ]
    [[ "$output" == *"worktree: $WT"* ]]
    [[ "$output" == *"straps (active):"* ]]
    [[ "$output" == *"toolstrap"* ]]
    [[ "$output" == *"verbs (strap scripts):"* ]]
    [[ "$output" == *"strap-tool"* ]]
    [[ "$output" == *"presets (.wtbs/):"* ]]
    [[ "$output" == *"mkpreset"* ]]
    [[ "$output" == *"aliases (.wtbs.yml):"* ]]
    [[ "$output" == *"greet"* ]]
}

@test "exec propagates the command exit code" {
    run "$SCRIPT" exec feature/exec fail3
    [ "$status" -eq 3 ]
}

@test "exec runs a .wtbs preset with WTBS_* env and positional args" {
    run "$SCRIPT" exec feature/exec mkpreset hello
    [ "$status" -eq 0 ]
    [ "$(cat "$WT/preset.out")" = "preset:feature_exec:hello" ]
}

@test "worktree .wtbs presets shadow main-repo presets" {
    printf '#!/usr/bin/env bash\necho from-worktree\n' > "$WT/.wtbs/shadow"
    run "$SCRIPT" exec feature/exec shadow
    [ "$status" -eq 0 ]
    [[ "$output" == *"from-worktree"* ]]
    [[ "$output" != *"from-main"* ]]
}

@test "exec --dry-run prints the preset without running it" {
    run "$SCRIPT" --dry-run exec feature/exec mkpreset hello
    [ "$status" -eq 0 ]
    [[ "$output" == *"would run preset: bash"*"/mkpreset hello"* ]]
    [ ! -e "$WT/preset.out" ]
}

@test "exec resolves a strap verb through the raw-command tier" {
    cat > .wtbs.yml <<'EOF'
straps: [toolstrap]
aliases:
  whereami: "pwd > whereami.out"
EOF
    run "$SCRIPT" exec feature/exec strap-tool with-args
    [ "$status" -eq 0 ]
    [[ "$output" == *"strap-tool-ran with-args"* ]]
}

@test "exec templates resolve strap-published state tokens" {
    cat > .wtbs.yml <<'EOF'
aliases:
  served: "echo served at {valet.url}"
EOF
    mkdir -p .wtbs/worktrees
    printf 'valet.url: https://short.develop\n' > .wtbs/worktrees/feature_exec.yml
    run "$SCRIPT" exec feature/exec served
    [ "$status" -eq 0 ]
    [[ "$output" == *"served at https://short.develop"* ]]
}
