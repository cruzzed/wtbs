#!/usr/bin/env bash
# Run the bats suite — or any experiment — inside a Landlock sandbox (landrun).
#
#   tests/landrun.sh                 # the full bats suite, sandboxed
#   tests/landrun.sh <cmd...>        # any other command, same sandbox
#
# Profile (deny by default; widen only with a comment here explaining why):
#   --rox the repo ........ tests read and execute wtbs.sh / strap scripts,
#                            but can never modify the checkout
#   --rox /usr /bin /lib .. trusted system binaries (bash, git, coreutils)
#   --rwx scratch dir ..... TMPDIR + HOME point here; the ONLY writable path.
#                            Execute is required because tests copy strap
#                            scripts into mktemp dirs and run the copies.
#   --rw  /dev/null ....... every script redirects here; harmless device node
#   no network flags ...... all TCP/UNIX-socket access is denied
#   --best-effort ......... degrade gracefully on older Landlock ABIs
#
# This makes the project rule "never target the real checkout, home directory,
# or user services" mechanical instead of disciplinary.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/wtbs-sandbox.XXXXXX")"
mkdir -p "$SCRATCH/home"
# The sandbox HOME is empty; git needs an identity for the many tests that
# commit. The unsandboxed suite reads it from the machine's ~/.gitconfig, so
# seeding the same here keeps sandboxed and plain runs equivalent.
cat > "$SCRATCH/home/.gitconfig" <<'EOF'
[user]
	name = wtbs sandbox test
	email = sandbox-test@example.com
EOF
cleanup() {
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

if [[ $# -eq 0 ]]; then
    set -- "$REPO_ROOT/node_modules/.bin/bats" "$REPO_ROOT/tests/bats"
fi

exec landrun \
    --best-effort \
    --rox "$REPO_ROOT" \
    --rox /usr \
    --rox /bin \
    --rox /lib \
    --rox /lib64 \
    --ro /etc \
    --ro "$HOME" \
    --rwx "$SCRATCH" \
    --rw /dev/null \
    --ro /dev/zero \
    --ro /dev/urandom \
    --env HOME="$SCRATCH/home" \
    --env TMPDIR="$SCRATCH" \
    -- "$@"
