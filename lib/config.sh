#!/usr/bin/env bash
set -euo pipefail

# Loaded config is stored as a flat associative array:
#   CONFIG["db_name"], CONFIG["ports.app"], CONFIG["env.APP_PORT"],
#   CONFIG["hooks.create[0]"], CONFIG["copy[0]"], CONFIG["straps[0]"], ...
declare -gA CONFIG

# Parse a YAML file into the named associative array as flat KEY=VALUE pairs.
_yaml_to_assoc() {
    local yaml_path="$1"
    local -n out_ref="$2"

    if ! command_exists python3; then
        fatal "python3 is required to parse .wtbs.yml"
    fi

    local raw
    raw="$(python3 - "$yaml_path" <<'PY'
import sys, yaml
def flatten(obj, prefix=''):
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            out.extend(flatten(v, prefix + ('.' if prefix else '') + str(k)))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            out.extend(flatten(v, prefix + '[' + str(i) + ']'))
    else:
        out.append((prefix, str(obj)))
    return out

try:
    data = yaml.safe_load(open(sys.argv[1]))
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
if data is None:
    sys.exit(0)
for k, v in flatten(data):
    print(f'{k}={v}')
PY
    )" || fatal "failed to parse config: $yaml_path"

    out_ref=()
    local line key value
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        out_ref["$key"]="$value"
    done <<< "$raw"
}

# Load the project config file into CONFIG. Missing file = empty config.
load_config() {
    local config_path="$1"
    CONFIG=()
    [[ -f "$config_path" ]] || return 0
    _yaml_to_assoc "$config_path" CONFIG
}

# Read a dotted config path. Returns empty string if missing.
get_config() {
    local path="$1"
    echo "${CONFIG[$path]:-}"
}

# Collect list entries (prefix[0], prefix[1], ...) into the named array.
config_list() {
    local prefix="$1"
    local -n list_ref="$2"
    list_ref=()
    local i=0 val
    while true; do
        val="${CONFIG["${prefix}[${i}]"]:-}"
        [[ -z "$val" ]] && break
        list_ref+=("$val")
        i=$((i + 1))
    done
}

# v0.4 is a clean break: v0.3 keys are rejected with a migration pointer
# instead of being silently reinterpreted.
reject_legacy_keys() {
    local -a legacy=()
    local k
    for k in "${!CONFIG[@]}"; do
        case "$k" in
            database.*|commands.*|env_updates.*|copy_from_main*|ports.base.*)
                legacy+=("$k") ;;
        esac
    done
    if [[ ${#legacy[@]} -gt 0 ]]; then
        printf 'FATAL: v0.3 config keys are not supported anymore: %s\n' "${legacy[*]}" >&2
        fatal "v0.4 config surface: straps, copy, db_name, ports, env, hooks, aliases — see examples/"
    fi
}

# The only built-in default left: how the {db_name} token is computed.
# Everything else is policy, expressed via config or straps.
apply_defaults() {
    [[ -z "${CONFIG["db_name"]:-}" ]] && CONFIG["db_name"]="wt_{branch_slug}"
    return 0
}

# Render a template string using a context associative array.
# Recognized tokens correspond to context keys: {branch}, {branch_slug},
# {site}, {db_name}, {worktree_root}, {main_repo}, and {ports.<name>}.
render_template() {
    local template="$1"
    local -n ctx_ref="$2"

    local result="$template"
    local key
    for key in "${!ctx_ref[@]}"; do
        result="${result//\{$key\}/${ctx_ref[$key]}}"
    done

    echo "$result"
}

# Replace {env.KEY} tokens in a template with the current value of KEY read
# from an env file. Missing keys render as an empty string.
render_env_refs() {
    local template="$1"
    local env_file="$2"

    local result="$template"
    local token key value
    while [[ "$result" =~ \{env\.([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
        token="${BASH_REMATCH[0]}"
        key="${BASH_REMATCH[1]}"
        value="$(env_value "$env_file" "$key")"
        result="${result//$token/$value}"
    done

    echo "$result"
}

# The db_name config value is a template that may reference {branch} and
# {branch_slug}; everything else would be circular (ports, db_name itself).
compute_db_name() {
    local branch="$1" branch_slug="$2"
    local -A mini=([branch]="$branch" [branch_slug]="$branch_slug")
    render_template "$(get_config db_name)" mini
}
