#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    [[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/bootstrap.sh"

show_help() {
    cat <<'EOF'
Usage: wtbs <command> [options]

Commands:
  create <branch>        Create a new worktree and bootstrap it.
  bootstrap --main-repo <path>
                         Bootstrap the current worktree directory.
  destroy <branch|path>  Destroy a worktree and free its resources.
  exec <branch|path> [cmd...]
                         Run a preset/alias/command inside a worktree: its
                         directory, .env, straps, and bin dirs. With no
                         command, lists what's available.
  <branch|path> [cmd...] Shorthand for exec.
  straps                 List available straps (worktree > main > bundled).
  strap customize <name> Copy a bundled strap into .wtbs/straps/<name> for
                         editing (the local copy then shadows the bundled).
  strap init <name>      Scaffold a new project strap in .wtbs/straps/.
  --help                 Show this help.

Global options (may appear in any position for create/bootstrap/destroy;
before the worktree name for exec/shorthand):
  --dry-run              Preview without making changes; on create this
                         renders the full bootstrap plan (merged straps,
                         ports, env updates, and every hook command).
  --main-repo <path>     Override path to the main repository.
  --config <path>        Override config file path.
  --base <ref>           Base ref for a new branch (create only; default: HEAD).
  --dir <name>           Custom worktree directory name (create only; default:
                         <repo>-<branch> as a sibling directory, slashes in the
                         branch name becoming dashes).
  --delete-branch        Also delete the branch after destroy.
  --no-publish           Keep bundled strap resolution; do not copy activated
                         straps into the project's .wtbs/straps/.

Config (.wtbs.yml): straps, copy.ignore, db_name, hooks, aliases — env
writes live in straps, copy mirrors untracked files minus the ignore
rules. See examples/ and the README.
EOF
}

main() {
    if [[ $# -eq 0 ]]; then show_help; exit 0; fi

    # Parse flags in any position; first positional is the command, the rest
    # are its arguments.
    local command=""
    local -a positionals=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) show_help; exit 0 ;;
            --dry-run) DRY_RUN=1 ;;
            --delete-branch) DELETE_BRANCH=1 ;;
            --no-publish) NO_PUBLISH=1 ;;
            --main-repo) shift; [[ $# -gt 0 ]] || fatal "--main-repo requires a value"; MAIN_ROOT_OVERRIDE="$1" ;;
            --config) shift; [[ $# -gt 0 ]] || fatal "--config requires a value"; CONFIG_PATH_OVERRIDE="$1" ;;
            --base) shift; [[ $# -gt 0 ]] || fatal "--base requires a value"; BASE_REF="$1" ;;
            --dir) shift; [[ $# -gt 0 ]] || fatal "--dir requires a value"; DIR_OVERRIDE="$1" ;;
            -*) fatal "unknown option: $1" ;;
            *)
                if [[ -z "$command" ]]; then
                    command="$1"
                    # exec and the shorthand pass everything after the target
                    # through verbatim (including -flags), so stop global flag
                    # parsing and dispatch immediately.
                    case "$command" in
                        create|bootstrap|destroy|straps|strap) ;;
                        exec)
                            shift
                            [[ $# -gt 0 ]] || fatal "exec requires a branch or path"
                            command="$1"
                            shift
                            [[ "${1:-}" == "--" ]] && shift
                            cmd_exec "$command" "$@"
                            exit $?
                            ;;
                        *)
                            shift
                            [[ "${1:-}" == "--" ]] && shift
                            cmd_exec "$command" "$@"
                            exit $?
                            ;;
                    esac
                else
                    positionals+=("$1")
                fi
                ;;
        esac
        shift
    done

    case "$command" in
        "") show_help; exit 0 ;;
        create)
            [[ ${#positionals[@]} -ge 1 ]] || fatal "create requires a branch name"
            cmd_create "${positionals[0]}"
            ;;
        bootstrap)
            cmd_bootstrap
            ;;
        destroy)
            [[ ${#positionals[@]} -ge 1 ]] || fatal "destroy requires a branch or path"
            cmd_destroy "${positionals[0]}"
            ;;
        straps)
            cmd_straps
            ;;
        strap)
            [[ ${#positionals[@]} -ge 1 ]] || fatal "strap requires a subcommand: customize | init"
            case "${positionals[0]}" in
                customize)
                    [[ ${#positionals[@]} -ge 2 ]] || fatal "strap customize requires a strap name"
                    cmd_strap_customize "${positionals[1]}"
                    ;;
                init)
                    [[ ${#positionals[@]} -ge 2 ]] || fatal "strap init requires a strap name"
                    cmd_strap_init "${positionals[1]}"
                    ;;
                *) fatal "unknown strap subcommand: ${positionals[0]} (customize | init)" ;;
            esac
            ;;
        *) fatal "unknown command: $command" ;;
    esac
}

main "$@"
