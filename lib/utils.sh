#!/usr/bin/env bash
set -euo pipefail

info() { echo "  $*"; }
warn() { echo "WARN: $*" >&2; }

fatal() {
    echo "FATAL: $*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    local cmd="$1"
    command_exists "$cmd" || fatal "required command not found: $cmd"
}

slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g' | sed -E 's/^_|_$//g' | cut -c1-60
}

is_git_repo() {
    git rev-parse --git-dir >/dev/null 2>&1
}

# --- Destructive-operation guards ---------------------------------------
#
# Every delete in wtbs goes through these. They fail closed: empty paths,
# /, and $HOME are never deletion targets, and recursive removal requires
# a directory git recognizes as a worktree (or carrying a .git entry).

# Die if the named variable is unset or empty. Pass the NAME, not the value.
require_nonempty() {
    local varname="$1"
    [[ -n "${!varname:-}" ]] || fatal "refusing to proceed: $varname is empty (from ${FUNCNAME[1]:-toplevel})"
}

# Shared refusal rules for deletion targets.
_refuse_unsafe_delete_path() {
    local path="$1"
    path="${path%/}"
    [[ -n "$path" ]] || fatal "refusing to remove an empty path"
    [[ "$path" != "/" ]] || fatal "refusing to remove /"
    [[ -n "${HOME:-}" ]] || fatal "refusing removal: HOME is unset, cannot establish path safety"
    [[ "$path" != "$HOME" ]] || fatal "refusing to remove \$HOME"
}

# Remove a single file (or symlink). Refuses directories and unsafe paths.
wtbs_remove_file() {
    local path="$1"
    _refuse_unsafe_delete_path "$path"
    path="${path%/}"
    if [[ -d "$path" && ! -L "$path" ]]; then
        fatal "refusing to remove directory with wtbs_remove_file: $path (use wtbs_remove_tree)"
    fi
    rm -f -- "$path"
}

# Recursively remove a directory, but only one git recognizes as a worktree
# (or that carries a .git entry). This is the only recursive rm in the tool.
wtbs_remove_tree() {
    local path="$1"
    _refuse_unsafe_delete_path "$path"
    path="${path%/}"
    [[ -d "$path" ]] || fatal "not a directory: $path"
    local abs
    abs="$(cd "$path" && pwd)"
    if ! git worktree list --porcelain 2>/dev/null | grep -qx "worktree $abs" \
        && [[ ! -e "$path/.git" ]]; then
        fatal "refusing recursive removal of non-worktree path: $path"
    fi
    rm -rf -- "$path"
}

# Delete a git branch with -D, failing closed: protected names and branches
# that do not exist locally are refused.
wtbs_remove_branch() {
    local repo="$1" branch="$2"
    require_nonempty branch
    case "$branch" in
        main|master|dev|develop|HEAD|-*) fatal "refusing to delete protected branch: $branch" ;;
    esac
    git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" \
        || fatal "refusing to delete branch that does not exist: $branch"
    git -C "$repo" branch -D "$branch"
}

# --- Danger scan for strap/hook scripts ----------------------------------
#
# wtbs executes project-owned scripts (hooks, strap verbs, presets). Before
# running one, scan it for destructive patterns and refuse. This is a
# lint-layer guard against mistypes and careless patterns — not a sandbox.
#
# Escape hatches: mark a specific line '# wtbs:danger-ok <reason>', or set
# WTBS_ALLOW_DANGEROUS=1 to skip scanning entirely (warns loudly).

_DANGER_PATTERNS=(
    "recursive-delete:rm[[:space:]]+-[A-Za-z]*r[A-Za-z]*([[:space:]]|$)"
    "find-delete:find[[:space:]][^|#]*-delete"
    "find-exec-rm:find[[:space:]][^|#]*-exec[[:space:]]+rm"
    "sudo:(^|[^A-Za-z0-9_])sudo[[:space:]]"
    "force-push:(^|[^A-Za-z0-9_])git[[:space:]]+push[[:space:]][^#]*--force"
    "disk-destroy:(^|[^A-Za-z0-9_])mkfs"
    "device-write:(^|[^A-Za-z0-9_])dd[[:space:]][^#]*of=/dev/"
    "device-redirect:[[:space:]]>+>[[:space:]]*/dev/(sd|hd|nvme|disk)"
)

# Scan a script for dangerous patterns. Follows same-dir sources one level.
# Returns 0 when clean; prints FATAL diagnostics and returns 1 on a hit.
danger_scan() {
    local file="$1" depth="${2:-}"
    [[ -f "$file" ]] || return 0
    if [[ "${WTBS_ALLOW_DANGEROUS:-}" == "1" ]]; then
        warn "WTBS_ALLOW_DANGEROUS=1: skipping danger scan of $file"
        return 0
    fi
    local script_dir line lineno entry name regex src_arg src_path src_dir
    local heredoc_end=""
    script_dir="$(cd "$(dirname "$file")" && pwd)"
    lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        # Inside a heredoc body: prose/usage examples, not executed commands.
        # (The heredoc start line itself was still pattern-checked above.)
        if [[ -n "$heredoc_end" ]]; then
            [[ "${line#"${line%%[![:space:]]*}"}" == "$heredoc_end" ]] && heredoc_end=""
            continue
        fi
        # Comments are exempt — they often document dangerous examples.
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Per-line opt-out directive.
        [[ "$line" == *"# wtbs:danger-ok"* ]] && continue
        for entry in "${_DANGER_PATTERNS[@]}"; do
            name="${entry%%:*}"
            regex="${entry#*:}"
            if [[ "$line" =~ $regex ]]; then
                # Quote the offending line verbatim — the user must be able
                # to see exactly what was considered dangerous.
                printf 'FATAL: wtbs danger scan refused to run: %s\n' "$file" >&2
                printf '  pattern : %s\n' "$name" >&2
                printf '  at      : %s:%d\n' "$file" "$lineno" >&2
                printf '  command : %s\n' "$line" >&2
                printf '  fix     : rewrite using the wtbs guard helpers, or mark the line\n' >&2
                printf "            '# wtbs:danger-ok <reason>' (or WTBS_ALLOW_DANGEROUS=1 to skip all scans)\n" >&2
                return 1
            fi
        done
        # Track heredoc openings (<<WORD, <<-WORD, quoted delimiters) so their
        # bodies are skipped on subsequent lines. Variable-held regex: bash's
        # [[ ]] lexer treats a literal < as an operator even inside =~.
        local heredoc_re='<<-?[[:space:]]*['"'"'"]?([A-Za-z_][A-Za-z0-9_]*)['"'"'"]?'
        if [[ "$line" =~ $heredoc_re ]]; then
            heredoc_end="${BASH_REMATCH[1]}"
        fi
        # Follow one level of same-dir sources (depth 0 only).
        if [[ "$depth" -eq 0 && "$line" =~ ^[[:space:]]*(source|[.])[[:space:]]+([^[:space:]#]+) ]]; then
            src_arg="${BASH_REMATCH[2]}"
            src_arg="${src_arg%\"}"; src_arg="${src_arg#\"}"
            src_arg="${src_arg%\'}"; src_arg="${src_arg#\'}"
            if [[ "$src_arg" = /* ]]; then
                src_path="$src_arg"
            else
                src_path="$script_dir/$src_arg"
            fi
            src_dir="$(cd "$(dirname "$src_path")" 2>/dev/null && pwd)" || continue
            # Only files inside the scanned script's own directory are followed.
            [[ "$src_dir" == "$script_dir" && -f "$src_path" ]] || continue
            danger_scan "$src_path" 1 || return 1
        fi
    done < "$file"
}
