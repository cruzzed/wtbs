#!/usr/bin/env bats

# Static invariant tests: the mechanical rules that keep destructive bash
# patterns from creeping back in. Behavior-level checks live in the other
# test files; these pin the shape of the source itself.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

@test "the only rm occurrences in core are the guard functions in utils.sh" {
    local file
    while IFS=: read -r file _; do
        [[ "$file" == "$REPO_ROOT/lib/utils.sh" ]]
    done < <(grep -rn "rm " "$REPO_ROOT/lib" "$REPO_ROOT/wtbs.sh" | grep -v "^\s*#")
}

@test "git branch -D appears only in the wtbs_remove_branch guard" {
    local hits
    hits="$(grep -rln "branch -D" "$REPO_ROOT/lib" "$REPO_ROOT/wtbs.sh")"
    [[ "$hits" == "$REPO_ROOT/lib/utils.sh" ]]
}

@test "the only eval in core is the run_hooks command executor" {
    local hits
    hits="$(grep -rn "eval " "$REPO_ROOT/lib" "$REPO_ROOT/wtbs.sh" | grep -v "^\s*#")"
    [[ "$hits" == *"lib/bootstrap.sh:"* ]]
    [[ "$hits" == *'eval "$rendered_cmd"'* ]]
    # Exactly one eval line, nowhere else.
    [[ "$(printf '%s\n' "$hits" | grep -c "eval ")" -eq 1 ]]
}

@test "no backtick command substitution outside mysql identifier quoting" {
    local line file lineno text
    while IFS=: read -r file lineno text; do
        # Skip comment lines.
        [[ "${text#"${text%%[![:space:]]*}"}" == \#* ]] && continue
        # mysql straps use literal backtick characters for identifier quoting.
        [[ "$file" == "$REPO_ROOT/straps/mysql/db-drop" ]] && continue
        [[ "$file" == "$REPO_ROOT/straps/mysql/db-clone" ]] && continue
        # A backtick followed by a word char or $( is command substitution.
        if [[ "$text" =~ \`[A-Za-z\$\(] ]]; then
            echo "backtick command substitution: $file:$lineno: $text" >&2
            false
        fi
    done < <(grep -rn '`' "$REPO_ROOT/lib" "$REPO_ROOT/wtbs.sh" "$REPO_ROOT/install.sh" \
        "$REPO_ROOT"/straps/*/db-* "$REPO_ROOT"/straps/*/create "$REPO_ROOT"/straps/*/destroy \
        "$REPO_ROOT"/straps/ngrok/ngrok-guard "$REPO_ROOT"/straps/ngrok/share \
        "$REPO_ROOT"/straps/valet/valet-site "$REPO_ROOT"/straps/auto-ports/create \
        "$REPO_ROOT"/straps/auto-ports/destroy 2>/dev/null)
}

@test "every shell script declares set -euo pipefail" {
    local f first_lines
    for f in "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/lib/db/*.sh \
             "$REPO_ROOT/wtbs.sh" "$REPO_ROOT/install.sh" \
             "$REPO_ROOT"/straps/*/*; do
        [[ -f "$f" ]] || continue
        case "$f" in
            *.yml|*.md) continue ;;
        esac
        # Only executable scripts need the line; extension-less libs that are
        # sourced (e.g. straps/auto-ports/lib) inherit the caller's options.
        head -1 "$f" | grep -q '^#!' || continue
        first_lines="$(head -30 "$f")"
        [[ "$first_lines" == *"set -euo pipefail"* ]] || {
            echo "missing set -euo pipefail: $f" >&2
            false
        }
    done
}

@test "bundled destructive scripts validate their targets" {
    # sqlite db-drop: core guards or inline refusal checks.
    grep -q "wtbs_remove_file\|refusing unsafe db-drop target" \
        "$REPO_ROOT/straps/sqlite/db-drop"
    # mysql/postgres db-drop/db-clone: db-name allowlist.
    local f
    for f in "$REPO_ROOT"/straps/mysql/db-drop "$REPO_ROOT"/straps/mysql/db-clone \
             "$REPO_ROOT"/straps/postgres/db-drop "$REPO_ROOT"/straps/postgres/db-clone; do
        grep -q 'A-Za-z0-9_' "$f" || {
            echo "missing db-name allowlist validation: $f" >&2
            false
        }
    done
    # valet-site: guarded symlink removal.
    grep -q "remove_link" "$REPO_ROOT/straps/valet/valet-site"
}
