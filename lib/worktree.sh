#!/usr/bin/env bash
set -euo pipefail

# Resolve the main repo root. If override is provided, use it; otherwise derive from git common dir.
resolve_main_root() {
    local override="$1"
    if [[ -n "$override" ]]; then
        echo "$override"
        return 0
    fi
    local common
    common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || fatal "not inside a git repository"
    dirname "$common"
}

# Ensure cwd is not the main repo root.
require_not_main_root() {
    local main_root="$1"
    local worktree_root
    worktree_root="$(pwd)"
    if [[ "$worktree_root" == "$main_root" ]]; then
        fatal "you are running this from the main repo root. Create a worktree first."
    fi
}

# List worktree paths, one per line.
list_worktrees() {
    git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print $2}'
}

# Default worktree path for a branch: a sibling directory of the main repo
# named <repo>-<branch>, with slashes in the branch name becoming dashes so
# the path stays a single directory. Names stay natural/full-length; the
# valet strap's valet-check-name warns when a name would break nginx.
default_worktree_path() {
    local main_root="$1" branch="$2"
    echo "$(dirname "$main_root")/$(basename "$main_root")-${branch//\//-}"
}

# Create a worktree for a branch at a path. If the branch does not exist yet,
# create it from the optional base ref (defaults to HEAD).
create_worktree() {
    local branch="$1"
    local path="$2"
    local base="${3:-}"
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        git worktree add "$path" "$branch"
    else
        info "branch '$branch' does not exist; creating from ${base:-HEAD}"
        if [[ -n "$base" ]]; then
            git worktree add -b "$branch" "$path" "$base"
        else
            git worktree add -b "$branch" "$path"
        fi
    fi
}

# Internal: return 0 if the directory is a registered worktree path.
_is_worktree_path() {
    local path="$1"
    [[ -d "$path" ]] || return 1
    local abs_path
    abs_path="$(cd "$path" && pwd)"
    [[ -e "$abs_path/.git" ]] || return 1
    git worktree list --porcelain 2>/dev/null | grep -qx "worktree $abs_path"
}

# Internal: resolve a branch name to its registered worktree path.
_worktree_path_for_branch() {
    local branch="$1"
    git worktree list --porcelain 2>/dev/null | awk -v b="$branch" '
        /^worktree / { path=$2 }
        /^branch / {
            ref=$2
            sub(/^refs\/heads\//, "", ref)
            if (ref == b) { print path; exit }
        }
    '
}

# Internal: safely remove a leftover worktree directory after git worktree remove fails.
_safe_remove_path() {
    local path="$1"
    if _is_worktree_path "$path" || git worktree list --porcelain 2>/dev/null | grep -qx "worktree $path"; then
        rm -rf "$path"
    else
        fatal "refusing unsafe removal of non-worktree path: $path"
    fi
}

# Remove a worktree by path.
remove_worktree() {
    local path="$1"
    local dry_run="${2:-}"
    if [[ "$dry_run" == "1" || "$dry_run" == "true" ]]; then
        echo "[dry-run] would remove worktree: $path"
        return 0
    fi
    git worktree remove "$path" 2>/dev/null || _safe_remove_path "$path"
}

# Remove a worktree by branch name or path.
destroy_worktree() {
    local branch_or_path="$1"
    local dry_run="${2:-}"
    local path=""
    if _is_worktree_path "$branch_or_path"; then
        path="$branch_or_path"
    else
        path="$(_worktree_path_for_branch "$branch_or_path")"
    fi
    [[ -n "$path" ]] || fatal "no worktree found for: $branch_or_path"
    remove_worktree "$path" "$dry_run"
}

# ── Residue copy (docs/adr/0008) ────────────────────────────────────────────
# git worktree add checks out tracked files; the copy noun mirrors the
# untracked residue (including gitignored files like .env) from the main
# repo into the worktree, minus the ignore list. Git's own machinery
# decides what is residue — the core invents no file-walking logic.
# .git and .wtbs/ are always skipped: mechanism, not policy.

# Echo the residue file list, one per line, excluding the given ignore
# patterns (gitignore-style, matched by git pathspec) and the built-ins.
residue_list() {
    local main_root="$1"
    shift
    local -a excludes=()
    local p
    for p in "$@"; do
        [[ -n "$p" ]] && excludes+=(":(exclude)$p")
    done
    git -C "$main_root" ls-files --others -- . \
        ":(exclude).git" ":(exclude).wtbs" ${excludes[@]+"${excludes[@]}"}
}

# Seed missing residue files into the worktree. Seed-only: a file already
# present is never overwritten (copy runs before strap lifecycles, which
# own the file afterwards). Prints "copied=<n> skipped=<n>".
copy_residue() {
    local main_root="$1" worktree_root="$2"
    shift 2
    local -a files=()
    mapfile -t files < <(residue_list "$main_root" "$@")
    local f copied=0 skipped=0
    for f in "${files[@]}"; do
        if [[ -e "$worktree_root/$f" ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        mkdir -p "$worktree_root/$(dirname "$f")"
        cp "$main_root/$f" "$worktree_root/$f"
        copied=$((copied + 1))
    done
    echo "copied=$copied skipped=$skipped"
}
