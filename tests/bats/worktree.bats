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
    rm -rf "$TMP_ORIGIN" "$(dirname "$TMP_ORIGIN")/wt-raw" "$(dirname "$TMP_ORIGIN")/wt-customdir"
}

# Path of the single non-main worktree.
worktree_path() {
    git -C "$TMP_ORIGIN" worktree list --porcelain \
        | awk '/^worktree /{print $2}' | grep -v "^$TMP_ORIGIN$" | head -n1
}

@test "list shows a bootstrapped worktree with ok status" {
    git branch feature/alpha
    run "$SCRIPT" create feature/alpha
    [ "$status" -eq 0 ]
    mkdir -p "$TMP_ORIGIN/.wtbs/worktrees"
    printf 'auto_ports.serve: 8001\n' > "$TMP_ORIGIN/.wtbs/worktrees/feature_alpha.yml"
    run "$SCRIPT" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"feature/alpha"* ]]
    [[ "$output" == *"status ... ok"* ]]
    [[ "$output" == *"tokens ... auto_ports.serve=8001"* ]]
    [[ "$output" == *"1 worktree, 0 stale"* ]]
}

@test "list flags a registered worktree whose directory is gone" {
    git branch feature/beta
    run "$SCRIPT" create feature/beta
    [ "$status" -eq 0 ]
    git -C "$TMP_ORIGIN" worktree remove --force "$(worktree_path)"
    run "$SCRIPT" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"feature/beta"* ]]
    [[ "$output" == *"missing"* ]]
    [[ "$output" == *"1 worktree, 1 stale"* ]]
}

@test "list flags a worktree the registry never saw" {
    git branch feature/raw
    git worktree add -q "$(dirname "$TMP_ORIGIN")/wt-raw" feature/raw
    run "$SCRIPT" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"feature/raw"* ]]
    [[ "$output" == *"unregistered"* ]]
    [[ "$output" == *"wt_feature_raw"* ]]
    [[ "$output" == *"1 worktree, 1 stale"* ]]
}

@test "a freshly created branch is not flagged as merged" {
    # A branch with no commits of its own is trivially an ancestor of
    # main HEAD; that must not count as "merged" (docs/adr/0009).
    git branch feature/fresh
    run "$SCRIPT" create feature/fresh
    [ "$status" -eq 0 ]
    run "$SCRIPT" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"status ... ok"* ]]
    [[ "$output" != *"merged"* ]]
}

@test "list flags a branch whose commits all landed in main HEAD" {
    git branch feature/done
    run "$SCRIPT" create feature/done
    [ "$status" -eq 0 ]
    git -C "$(worktree_path)" commit --allow-empty -q -m "work on done"
    git -C "$TMP_ORIGIN" merge --no-ff -q -m "land done" feature/done
    run "$SCRIPT" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"merged"* ]]
    [[ "$output" == *"1 worktree, 1 stale"* ]]
}

@test "list --stale filters to flagged rows" {
    git branch feature/ok
    git branch feature/gone
    run "$SCRIPT" create feature/ok
    [ "$status" -eq 0 ]
    run "$SCRIPT" create feature/gone
    [ "$status" -eq 0 ]
    git -C "$TMP_ORIGIN" worktree remove --force \
        "$(git -C "$TMP_ORIGIN" worktree list --porcelain | awk '/^worktree /{print $2}' | grep 'feature-gone$')"
    run "$SCRIPT" list --stale
    [ "$status" -eq 0 ]
    [[ "$output" != *"feature/ok"* ]]
    [[ "$output" == *"feature/gone"* ]]
    [[ "$output" == *"showing 1 of 2 (1 stale)"* ]]
}

@test "list flags config drift when .wtbs.yml changes after create" {
    cat > .wtbs.yml <<'EOF'
db_name: "myapp_{branch_slug}"
EOF
    git add .wtbs.yml && git commit -q -m "config"
    git branch feature/drift
    run "$SCRIPT" create feature/drift
    [ "$status" -eq 0 ]
    echo 'aliases: {test: "echo hi"}' >> .wtbs.yml
    run "$SCRIPT" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"config drift"* ]]
}

@test "legacy registry rows without a digest column are never flagged" {
    git branch feature/legacy
    run "$SCRIPT" create feature/legacy
    [ "$status" -eq 0 ]
    printf 'feature/legacy\twt_feature_legacy\t2026-01-01T00:00:00+00:00\n' \
        > "$TMP_ORIGIN/.wtbs/registry.tsv"
    run "$SCRIPT" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"feature/legacy"* ]]
    [[ "$output" == *"status ... ok"* ]]
    [[ "$output" == *"1 worktree, 0 stale"* ]]
}

@test "list --json emits a parseable machine report" {
    git branch feature/json
    run "$SCRIPT" create feature/json
    [ "$status" -eq 0 ]
    mkdir -p "$TMP_ORIGIN/.wtbs/worktrees"
    printf 'auto_ports.serve: 8001\nvalet.url: https://short.develop\n' \
        > "$TMP_ORIGIN/.wtbs/worktrees/feature_json.yml"
    run "$SCRIPT" list --json
    [ "$status" -eq 0 ]
    OUTPUT="$output" python3 - <<'PY'
import json, os
d = json.loads(os.environ["OUTPUT"])
assert d["summary"] == {"total": 1, "stale": 0, "shown": 1}, d["summary"]
(w,) = d["worktrees"]
assert w["branch"] == "feature/json"
assert w["path"].endswith("feature-json"), w["path"]
assert w["db"] == "wt_feature_json"
assert w["registered"] is True
assert w["stale"] is False
assert w["flags"] == []
assert isinstance(w["created"], str) and w["created"]
assert w["tokens"] == {"auto_ports.serve": "8001", "valet.url": "https://short.develop"}, w["tokens"]
PY
}

@test "list --json --stale shows only flagged worktrees" {
    git branch feature/jsonok
    git branch feature/jsongone
    run "$SCRIPT" create feature/jsonok
    [ "$status" -eq 0 ]
    run "$SCRIPT" create feature/jsongone
    [ "$status" -eq 0 ]
    git -C "$TMP_ORIGIN" worktree remove --force \
        "$(git -C "$TMP_ORIGIN" worktree list --porcelain | awk '/^worktree /{print $2}' | grep 'jsongone$')"
    run "$SCRIPT" list --json --stale
    [ "$status" -eq 0 ]
    OUTPUT="$output" python3 - <<'PY'
import json, os
d = json.loads(os.environ["OUTPUT"])
assert d["summary"] == {"total": 2, "stale": 1, "shown": 1}, d["summary"]
(w,) = d["worktrees"]
assert w["branch"] == "feature/jsongone"
assert w["stale"] is True
assert w["flags"] == ["missing"], w["flags"]
assert w["path"] is None
PY
}

@test "doctor passes a healthy project" {
    git branch feature/healthy
    run "$SCRIPT" create feature/healthy
    [ "$status" -eq 0 ]
    run "$SCRIPT" doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"main repo"* ]]
    [[ "$output" == *"config"*ok* ]]
    [[ "$output" == *"worktrees"*ok*"(1"* ]]
    [[ "$output" == *"state"*ok* ]]
    [[ "$output" == *"doctor: all checks passed"* ]]
}

@test "doctor fails on an unresolvable declared strap, reporting not aborting" {
    cat > .wtbs.yml <<'EOF'
straps: [no-such-strap]
EOF
    git add .wtbs.yml && git commit -q -m "config"
    run "$SCRIPT" doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"no-such-strap"* ]]
    [[ "$output" == *"FAIL"* ]]
}

@test "doctor fails on a missing hook script" {
    cat > .wtbs.yml <<'EOF'
hooks:
  create:
    - scripts/does-not-exist.sh run
EOF
    git add .wtbs.yml && git commit -q -m "config"
    run "$SCRIPT" doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL (missing: scripts/does-not-exist.sh)"* ]]
}

@test "doctor runs strap check verbs and reports pass, failure, and absence" {
    for s in ping busted quiet; do
        mkdir -p ".wtbs/straps/$s"
        printf '#!/usr/bin/env bash\nset -euo pipefail\n' > ".wtbs/straps/$s/create"
        printf '#!/usr/bin/env bash\nset -euo pipefail\n' > ".wtbs/straps/$s/destroy"
        chmod +x ".wtbs/straps/$s/create" ".wtbs/straps/$s/destroy"
    done
    printf '#!/usr/bin/env bash\necho "all good"\n' > .wtbs/straps/ping/check
    printf '#!/usr/bin/env bash\necho "something is wrong" >&2\nexit 1\n' > .wtbs/straps/busted/check
    chmod +x .wtbs/straps/ping/check .wtbs/straps/busted/check
    cat > .wtbs.yml <<'EOF'
straps: [ping, busted, quiet]
EOF
    git add .wtbs.yml .wtbs/straps && git commit -q -m "straps"
    run "$SCRIPT" doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"ok: ping"* ]]
    [[ "$output" == *"FAIL: busted"* ]]
    [[ "$output" == *"none: quiet"* ]]
    [[ "$output" == *"1 check(s) failed"* ]]
}

@test "doctor --dry-run renders the check plan without running it" {
    mkdir -p .wtbs/straps/ping
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' > .wtbs/straps/ping/create
    chmod +x .wtbs/straps/ping/create
    printf '#!/usr/bin/env bash\necho "would have run"\n' > .wtbs/straps/ping/check
    chmod +x .wtbs/straps/ping/check
    cat > .wtbs.yml <<'EOF'
straps: [ping]
EOF
    git add .wtbs.yml .wtbs/straps && git commit -q -m "strap"
    run "$SCRIPT" doctor --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run] would run strap 'ping' check:"* ]]
    [[ "$output" != *"would have run"* ]]
}

@test "doctor flags legacy config keys as a failure" {
    cat > .wtbs.yml <<'EOF'
env:
  APP_URL: "https://{site}.test"
EOF
    git add .wtbs.yml && git commit -q -m "legacy config"
    run "$SCRIPT" doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"unsupported keys: env.APP_URL"* ]]
}


@test "create --json emits a pure-JSON machine report with strap tokens" {
    mkdir -p .wtbs/straps/tokenizer
    cat > .wtbs/straps/tokenizer/create <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
source "${WTBS_LIB_DIR:?run inside wtbs}/strap-lib.sh"
wtbs_state_set demo.value "hello"
EOS
    chmod +x .wtbs/straps/tokenizer/create
    cat > .wtbs.yml <<'EOF'
straps: [tokenizer]
EOF
    git add .wtbs.yml .wtbs/straps && git commit -q -m "strap"
    git branch feature/jreport
    # JSON mode routes progress to stderr; capture streams separately so
    # stdout stays the pure machine report.
    run --separate-stderr "$SCRIPT" create feature/jreport --json
    [ "$status" -eq 0 ]
    OUTPUT="$output" python3 - <<'PY'
import json, os
d = json.loads(os.environ["OUTPUT"])
assert d["branch"] == "feature/jreport"
assert d["db_name"] == "wt_feature_jreport"
assert d["worktree_root"].endswith("feature-jreport"), d["worktree_root"]
assert d["main_repo"]
assert d["dry_run"] is False
assert d["straps"] == ["tokenizer"], d["straps"]
assert d["tokens"] == {"demo.value": "hello"}, d["tokens"]
PY
}

@test "create --dry-run --json keeps stdout pure JSON with the plan flagged" {
    git branch feature/jplan
    run --separate-stderr "$SCRIPT" create --dry-run feature/jplan --json
    [ "$status" -eq 0 ]
    OUTPUT="$output" python3 - <<'PY'
import json, os
d = json.loads(os.environ["OUTPUT"])
assert d["branch"] == "feature/jplan"
assert d["dry_run"] is True
assert d["straps"] == []
PY
    [[ "$output" != *"dry-run"* ]]
    [[ "$output" != *"wtbs report"* ]]
}
