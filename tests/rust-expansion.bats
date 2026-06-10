#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2016

load 'helpers/common'

setup() {
    fake_bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/cargo" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ ${1:-} == locate-project ]]; then
    case ${FAKE_CARGO_LOCATE:-success} in
        success)
            printf '%s\n' "${FAKE_WORKSPACE_MANIFEST:?}"
            ;;
        fail)
            exit 101
            ;;
        *)
            echo "fake cargo: unknown FAKE_CARGO_LOCATE" >&2
            exit 99
            ;;
    esac
else
    echo "fake cargo: unexpected command: $*" >&2
    exit 99
fi
EOF
    chmod +x "$fake_bin/cargo"
}

@test 'skn-expansion-cargo emits narrow workspace grants without preparing by default' {
    workspace="$BATS_TEST_TMPDIR/workspace"
    member="$workspace/crate-a"
    home="$BATS_TEST_TMPDIR/home"
    mkdir -p "$member" "$home"
    rm -rf -- "$home/.cargo" "$home/.rustup"
    touch "$workspace/Cargo.toml"

    expected=$(printf '%s\n' \
        +R "$workspace" \
        +W "$workspace/Cargo.lock" \
        +W "$workspace/target" \
        +W "$member")

    run env -u SKN_EXPANSION_MODE -u SKN_REAL_CARGO -u CARGO_HOME -u RUSTUP_HOME \
        HOME="$home" \
        PATH="$fake_bin:$PATH" \
        FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml" \
        bash -c 'cd -- "$1" && "$2"' _ "$member" "$SKN_EXPANSION_CARGO"

    assert_success
    [[ $output == "$expected" ]]
    assert_file_not_exists "$workspace/Cargo.lock"
    assert_file_not_exists "$workspace/target"
}

@test 'skn-expansion-cargo prepare mode creates workspace prerequisites' {
    workspace="$BATS_TEST_TMPDIR/prepare-workspace"
    member="$workspace/crate-a"
    home="$BATS_TEST_TMPDIR/prepare-home"
    mkdir -p "$member" "$home"
    rm -rf -- "$home/.cargo" "$home/.rustup"
    touch "$workspace/Cargo.toml"

    run env -u SKN_REAL_CARGO -u CARGO_HOME -u RUSTUP_HOME \
        SKN_EXPANSION_MODE=prepare \
        HOME="$home" \
        PATH="$fake_bin:$PATH" \
        FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml" \
        bash -c 'cd -- "$1" && "$2"' _ "$member" "$SKN_EXPANSION_CARGO"

    assert_success
    assert_file_exists "$workspace/Cargo.lock"
    assert_file_exists "$workspace/target"
}

@test 'skn-expansion-cargo prepare mode does not touch through a dangling lockfile symlink' {
    workspace="$BATS_TEST_TMPDIR/symlink-workspace"
    member="$workspace/crate-a"
    home="$BATS_TEST_TMPDIR/symlink-home"
    outside="$BATS_TEST_TMPDIR/outside"
    mkdir -p "$member" "$home" "$outside"
    rm -rf -- "$home/.cargo" "$home/.rustup"
    touch "$workspace/Cargo.toml"
    ln -s "$outside/Cargo.lock" "$workspace/Cargo.lock"

    run env -u SKN_REAL_CARGO -u CARGO_HOME -u RUSTUP_HOME \
        SKN_EXPANSION_MODE=prepare \
        HOME="$home" \
        PATH="$fake_bin:$PATH" \
        FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml" \
        bash -c 'cd -- "$1" && "$2"' _ "$member" "$SKN_EXPANSION_CARGO"

    assert_success
    [[ -L $workspace/Cargo.lock ]]
    assert_file_not_exists "$outside/Cargo.lock"
    assert_file_exists "$workspace/target"
}

@test 'skn-expansion-cargo no-lockfile profile avoids lockfile creation and grant' {
    workspace="$BATS_TEST_TMPDIR/no-lockfile-workspace"
    member="$workspace/crate-a"
    home="$BATS_TEST_TMPDIR/no-lockfile-home"
    mkdir -p "$member" "$home"
    rm -rf -- "$home/.cargo" "$home/.rustup"
    touch "$workspace/Cargo.toml"

    expected=$(printf '%s\n' \
        +R "$workspace" \
        +W "$workspace/target" \
        +W "$member")

    run env -u SKN_REAL_CARGO -u CARGO_HOME -u RUSTUP_HOME \
        HOME="$home" \
        PATH="$fake_bin:$PATH" \
        FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml" \
        bash -c 'cd -- "$1" && "$2" no-lockfile' _ "$member" "$SKN_EXPANSION_CARGO"

    assert_success
    [[ $output == "$expected" ]]
    assert_file_not_exists "$workspace/Cargo.lock"
    assert_file_not_exists "$workspace/target"
}


@test 'skn-expansion-cargo grants the workspace root writable when run there' {
    workspace="$BATS_TEST_TMPDIR/workspace"
    home="$BATS_TEST_TMPDIR/home"
    mkdir -p "$workspace" "$home"
    rm -rf -- "$home/.cargo" "$home/.rustup"
    touch "$workspace/Cargo.toml"

    expected=$(printf '%s\n' +W "$workspace")

    run env -u SKN_REAL_CARGO -u CARGO_HOME -u RUSTUP_HOME \
        HOME="$home" \
        PATH="$fake_bin:$PATH" \
        FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml" \
        bash -c 'cd -- "$1" && "$2"' _ "$workspace" "$SKN_EXPANSION_CARGO"

    assert_success
    [[ $output == "$expected" ]]
    assert_file_not_exists "$workspace/target"
}

@test 'skn-expansion-cargo rust-analyzer profile grants read-only workspace plus target' {
    workspace="$BATS_TEST_TMPDIR/workspace"
    member="$workspace/crate-a"
    home="$BATS_TEST_TMPDIR/home"
    mkdir -p "$member" "$home"
    rm -rf -- "$home/.cargo" "$home/.rustup"
    touch "$workspace/Cargo.toml"

    expected=$(printf '%s\n' \
        +R "$workspace" \
        +W "$workspace/target")

    run env -u SKN_REAL_CARGO -u CARGO_HOME -u RUSTUP_HOME \
        HOME="$home" \
        PATH="$fake_bin:$PATH" \
        FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml" \
        bash -c 'cd -- "$1" && "$2" rust-analyzer' _ "$member" "$SKN_EXPANSION_CARGO"

    assert_success
    [[ $output == "$expected" ]]
    assert_file_not_exists "$workspace/target"

    run env -u SKN_REAL_CARGO -u CARGO_HOME -u RUSTUP_HOME \
        HOME="$home" \
        PATH="$fake_bin:$PATH" \
        FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml" \
        bash -c 'cd -- "$1" && "$2" rust-analyzer' _ "$workspace" "$SKN_EXPANSION_CARGO"

    assert_success
    [[ $output == "$expected" ]]
}

@test 'skn-expansion-cargo emits narrow tool home grants when homes exist' {
    workspace="$BATS_TEST_TMPDIR/workspace"
    member="$workspace/crate-a"
    home="$BATS_TEST_TMPDIR/home"
    cargo_home="$BATS_TEST_TMPDIR/custom-cargo-home"
    rustup_home="$BATS_TEST_TMPDIR/custom-rustup-home"
    mkdir -p "$member" "$home" "$cargo_home" "$rustup_home"
    touch "$workspace/Cargo.toml"

    run env -u SKN_REAL_CARGO \
        HOME="$home" \
        CARGO_HOME="$cargo_home" \
        RUSTUP_HOME="$rustup_home" \
        PATH="$fake_bin:$PATH" \
        FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml" \
        bash -c 'cd -- "$1" && "$2"' _ "$member" "$SKN_EXPANSION_CARGO"

    assert_success
    assert_output_contains $'+V\n'"CARGO_HOME=$cargo_home"
    assert_output_contains $'+R\n'"$cargo_home"
    assert_output_contains $'+W\n'"$cargo_home/registry"
    assert_output_contains $'+W\n'"$cargo_home/git"
    assert_output_contains $'+V\n'"RUSTUP_HOME=$rustup_home"
    assert_output_contains $'+R\n'"$rustup_home"
    assert_file_not_exists "$cargo_home/registry"
    assert_file_not_exists "$cargo_home/git"
}

@test 'skn-expansion-cargo prepare mode creates tool cache directories' {
    workspace="$BATS_TEST_TMPDIR/tool-prepare-workspace"
    member="$workspace/crate-a"
    home="$BATS_TEST_TMPDIR/tool-prepare-home"
    cargo_home="$BATS_TEST_TMPDIR/tool-prepare-cargo-home"
    rustup_home="$BATS_TEST_TMPDIR/tool-prepare-rustup-home"
    mkdir -p "$member" "$home" "$cargo_home" "$rustup_home"
    touch "$workspace/Cargo.toml"

    run env -u SKN_REAL_CARGO \
        SKN_EXPANSION_MODE=prepare \
        HOME="$home" \
        CARGO_HOME="$cargo_home" \
        RUSTUP_HOME="$rustup_home" \
        PATH="$fake_bin:$PATH" \
        FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml" \
        bash -c 'cd -- "$1" && "$2"' _ "$member" "$SKN_EXPANSION_CARGO"

    assert_success
    assert_file_exists "$cargo_home/registry"
    assert_file_exists "$cargo_home/git"
}

@test 'skn-expansion-cargo rejects invalid expansion mode' {
    project="$BATS_TEST_TMPDIR/invalid-mode-workspace"
    home="$BATS_TEST_TMPDIR/invalid-mode-home"
    mkdir -p "$project" "$home"
    touch "$project/Cargo.toml"

    run env -u SKN_REAL_CARGO -u CARGO_HOME -u RUSTUP_HOME \
        SKN_EXPANSION_MODE=maybe \
        HOME="$home" \
        PATH="$fake_bin:$PATH" \
        FAKE_WORKSPACE_MANIFEST="$project/Cargo.toml" \
        bash -c 'cd -- "$1" && "$2"' _ "$project" "$SKN_EXPANSION_CARGO"

    assert_status 2
    assert_output_contains 'invalid SKN_EXPANSION_MODE'
}

@test 'skn-expansion-cargo emits no project grants outside workspaces' {
    project="$BATS_TEST_TMPDIR/not-a-workspace"
    home="$BATS_TEST_TMPDIR/home"
    mkdir -p "$project" "$home"
    rm -rf -- "$home/.cargo" "$home/.rustup"

    run env -u SKN_REAL_CARGO -u CARGO_HOME -u RUSTUP_HOME \
        HOME="$home" \
        PATH="$fake_bin:$PATH" \
        FAKE_CARGO_LOCATE=fail \
        bash -c 'cd -- "$1" && "$2"' _ "$project" "$SKN_EXPANSION_CARGO"

    assert_success
    [[ -z $output ]]
    assert_file_not_exists "$project/target"
}

@test 'skn +X cargo uses skn-expansion-cargo from PATH' {
    workspace="$BATS_TEST_TMPDIR/workspace"
    member="$workspace/crate-a"
    home="$BATS_TEST_TMPDIR/home"
    mkdir -p "$member" "$home"
    rm -rf -- "$home/.cargo" "$home/.rustup"
    touch "$workspace/Cargo.toml"

    run env -u SKN_PATH_CHECK -u SKN_REAL_CARGO -u CARGO_HOME -u RUSTUP_HOME \
        HOME="$home" \
        PATH="$REPO_ROOT/rust:$fake_bin:$PATH" \
        FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml" \
        bash -c 'cd -- "$1" && "$2" true +S +X cargo' _ "$member" "$SKN"

    assert_success
    assert_output_contains "--ro-bind $workspace $workspace"
    assert_output_contains "--bind $workspace/target $workspace/target"
    assert_output_contains "--bind $member $member"
    assert_file_not_exists "$workspace/target"
}

@test 'skn +X cargo:rust-analyzer uses the rust-analyzer profile' {
    workspace="$BATS_TEST_TMPDIR/workspace"
    member="$workspace/crate-a"
    home="$BATS_TEST_TMPDIR/home"
    mkdir -p "$member" "$home"
    rm -rf -- "$home/.cargo" "$home/.rustup"
    touch "$workspace/Cargo.toml"

    run env -u SKN_PATH_CHECK -u SKN_REAL_CARGO -u CARGO_HOME -u RUSTUP_HOME \
        HOME="$home" \
        PATH="$REPO_ROOT/rust:$fake_bin:$PATH" \
        FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml" \
        bash -c 'cd -- "$1" && "$2" true +S +X cargo:rust-analyzer' _ "$member" "$SKN"

    assert_success
    assert_output_contains "--ro-bind $workspace $workspace"
    assert_output_contains "--bind $workspace/target $workspace/target"
    assert_output_not_contains "--bind $member $member"
    assert_file_not_exists "$workspace/target"
}
