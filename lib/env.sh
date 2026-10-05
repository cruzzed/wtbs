#!/usr/bin/env bash
set -euo pipefail

# Read a value from a KEY=VALUE .env file. Handles optional quotes.
# Returns an empty string (and exit code 0) when the file or key is missing.
env_value() {
    local file="$1"
    local key="$2"
    if [[ ! -f "$file" ]]; then
        return 0
    fi
    grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | sed -E "s/^${key}=//" | sed -E "s/^['\"](.*)['\"]$/\1/" | tr -d '\r' || true
}

# Copy an array of files from source_dir to dest_dir. Missing files are skipped silently.
copy_files() {
    local source_dir="$1"
    local dest_dir="$2"
    shift 2
    local files=("$@")
    local file rel_dir

    for file in "${files[@]}"; do
        [[ -f "$source_dir/$file" ]] || continue
        rel_dir="$(dirname "$file")"
        mkdir -p "$dest_dir/$rel_dir"
        cp "$source_dir/$file" "$dest_dir/$file"
    done
}

# Update or append a key in an .env file.
update_env_key() {
    local file="$1"
    local key="$2"
    local value="$3"
    # Escape sed replacement metachars; values may contain / (paths, URLs) or &.
    local escaped_value="${value//\\/\\\\}"
    escaped_value="${escaped_value//&/\\&}"
    if grep -qE "^${key}=" "$file" 2>/dev/null; then
        sed -i -E "s|^${key}=.*|${key}=${escaped_value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

# Export every KEY=VALUE pair from an .env file into the environment.
# Best-effort: blank lines and comments are skipped, an optional `export `
# prefix is accepted, and matching surrounding quotes are stripped. Values are
# not re-interpreted (no variable expansion), unlike `source`.
export_env_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        line="${line#export }"
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        if [[ "$value" =~ ^\".*\"$ || "$value" =~ ^\'.*\'$ ]]; then
            value="${value:1:${#value}-2}"
        fi
        export "$key=$value"
    done < "$file"
}
