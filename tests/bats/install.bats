#!/usr/bin/env bats

setup() {
    # Install from a mode-controlled copy of the repo: this environment may
    # normalize the executable bits of untracked files, and install.sh must
    # preserve modes regardless of where it runs from.
    export SRC_COPY="$(mktemp -d)/wtbs"
    cp -R "$BATS_TEST_DIRNAME/../.." "$SRC_COPY"
    rm -rf "$SRC_COPY/.git" "$SRC_COPY/node_modules"
    chmod 755 "$SRC_COPY/wtbs.sh" "$SRC_COPY/install.sh"
    chmod 755 "$SRC_COPY"/straps/*/create "$SRC_COPY"/straps/*/destroy \
        "$SRC_COPY"/straps/*/db-clone "$SRC_COPY"/straps/*/db-drop \
        "$SRC_COPY"/straps/valet/valet-site \
        "$SRC_COPY"/straps/ngrok/share "$SRC_COPY"/straps/ngrok/ngrok-guard
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share"
}

teardown() {
    rm -rf "$SRC_COPY" "$HOME"
}

@test "install.sh copies files to ~/.local/share and ~/.local/bin" {
    run "$SRC_COPY/install.sh"
    [ "$status" -eq 0 ]
    [ -x "$HOME/.local/bin/wtbs" ]
    [ -d "$HOME/.local/share/wtbs" ]
    [ -x "$HOME/.local/share/wtbs/wtbs.sh" ]
}

@test "install.sh keeps a worktree-bootstrap shim for transition" {
    run "$SRC_COPY/install.sh"
    [ "$status" -eq 0 ]
    [ -x "$HOME/.local/bin/worktree-bootstrap" ]
    run "$HOME/.local/bin/worktree-bootstrap" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"now called wtbs"* ]]
    [[ "$output" == *"Usage: wtbs"* ]]
}

@test "install.sh installs the bundled straps with executable scripts" {
    run "$SRC_COPY/install.sh"
    [ "$status" -eq 0 ]
    local share="$HOME/.local/share/wtbs"
    [ -f "$share/straps/mysql/strap.yml" ]
    [ -f "$share/straps/sqlite/strap.yml" ]
    [ -f "$share/straps/postgres/strap.yml" ]
    [ -f "$share/straps/valet/strap.yml" ]
    [ -f "$share/straps/ngrok/strap.yml" ]
    [ -f "$share/straps/auto-ports/README.md" ]
    [ -x "$share/straps/mysql/create" ]
    [ -x "$share/straps/mysql/destroy" ]
    [ -x "$share/straps/mysql/db-clone" ]
    [ -x "$share/straps/postgres/db-drop" ]
    [ -x "$share/straps/sqlite/create" ]
    [ -x "$share/straps/valet/create" ]
    [ -x "$share/straps/valet/valet-site" ]
    [ -x "$share/straps/ngrok/share" ]
    [ -x "$share/straps/ngrok/ngrok-guard" ]
    [ -x "$share/straps/auto-ports/create" ]
    [ -x "$share/straps/auto-ports/destroy" ]
}
