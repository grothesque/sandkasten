#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031

load 'helpers/common'

setup() {
    fake_bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"

    FAKE_SKN_INFO_ARGS="$BATS_TEST_TMPDIR/skn-info.args"
    FAKE_SKN_FINAL_ARGS="$BATS_TEST_TMPDIR/skn-final.args"
    export FAKE_SKN_INFO_ARGS FAKE_SKN_FINAL_ARGS

    cat >"$fake_bin/skn" <<'EOF'
#!/bin/bash
set -euo pipefail

has_info=0
for arg in "$@"; do
    if [[ $arg == +I ]]; then
        has_info=1
        break
    fi
done

if ((has_info)); then
    printf '%s\0' "$@" >"${FAKE_SKN_INFO_ARGS:?}"
    case ${FAKE_SKN_INFO_RESULT:-disabled} in
        disabled)
            echo 'skn: sandboxed command: fake'
            echo 'skn: network disabled'
            echo 'skn: environment preserved'
            echo 'skn: equivalent invocation: fake'
            ;;
        enabled)
            echo 'skn: sandboxed command: fake'
            echo 'skn: network enabled'
            echo 'skn: environment preserved'
            echo 'skn: equivalent invocation: fake'
            ;;
        malformed)
            echo 'skn: sandboxed command: fake'
            echo 'not a skn header line'
            ;;
        fail)
            exit "${FAKE_SKN_INFO_STATUS:-37}"
            ;;
        *)
            echo "fake skn: unknown FAKE_SKN_INFO_RESULT" >&2
            exit 99
            ;;
    esac
    exit 0
fi

printf '%s\0' "$@" >"${FAKE_SKN_FINAL_ARGS:?}"
exit "${FAKE_SKN_FINAL_STATUS:-0}"
EOF
    chmod +x "$fake_bin/skn"

    cat >"$fake_bin/cargo" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ ${1:-} == locate-project ]]; then
    case ${FAKE_CARGO_LOCATE:-fail} in
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
    exit 0
fi

echo "fake cargo: unexpected invocation: $*" >&2
exit 99
EOF
    chmod +x "$fake_bin/cargo"

    export PATH="$fake_bin:$PATH"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    unset CARGO_HOME RUSTUP_HOME
    export FAKE_SKN_INFO_RESULT=disabled
    export FAKE_CARGO_LOCATE=fail
}

write_args_lines() {
    local source=$1
    local dest=$2

    tr '\0' '\n' <"$source" >"$dest"
}

assert_args_contain() {
    local lines=$1
    local expected=$2

    if ! grep -Fx -- "$expected" "$lines" >/dev/null; then
        printf 'expected args to contain: %s\n' "$expected" >&2
        printf 'args:\n' >&2
        sed 's/^/  /' "$lines" >&2
        return 1
    fi
}

assert_args_not_contain() {
    local lines=$1
    local unexpected=$2

    if grep -Fx -- "$unexpected" "$lines" >/dev/null; then
        printf 'expected args not to contain: %s\n' "$unexpected" >&2
        printf 'args:\n' >&2
        sed 's/^/  /' "$lines" >&2
        return 1
    fi
}

assert_args_contain_pair() {
    local lines=$1
    local expected_option=$2
    local expected_path=$3
    local -a argv
    local i

    mapfile -t argv <"$lines"
    for ((i = 0; i + 1 < ${#argv[@]}; ++i)); do
        if [[ ${argv[i]} == "$expected_option" && ${argv[i + 1]} == "$expected_path" ]]; then
            return 0
        fi
    done

    printf 'expected args to contain pair: %s %s\n' "$expected_option" "$expected_path" >&2
    printf 'args:\n' >&2
    sed 's/^/  /' "$lines" >&2
    return 1
}

@test 'skn-cargo adds offline mode and writable workspace when network is disabled' {
    workspace="$BATS_TEST_TMPDIR/workspace"
    mkdir -p "$workspace"
    touch "$workspace/Cargo.toml"
    export FAKE_CARGO_LOCATE=success
    export FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml"

    run "$SKN_CARGO" build
    assert_success

    info_args="$BATS_TEST_TMPDIR/info.lines"
    write_args_lines "$FAKE_SKN_INFO_ARGS" "$info_args"
    assert_args_contain "$info_args" '+I'

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" 'cargo'
    assert_args_contain "$args" '+P'
    assert_args_contain "$args" '+W'
    assert_args_contain "$args" "$workspace"
    assert_args_contain "$args" '+E'
    assert_args_contain "$args" 'CARGO_NET_OFFLINE=true'
    assert_args_contain "$args" 'build'
}

@test 'skn-cargo leaves offline mode unset for enabled network and passes cargo +toolchain args through' {
    export FAKE_SKN_INFO_RESULT=enabled

    run "$SKN_CARGO" +N +nightly build
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" '+N'
    assert_args_contain "$args" '+nightly'
    assert_args_contain "$args" 'build'
    assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'
}

@test 'skn-cargo adds home binds as explicit skn options when present' {
    mkdir -p "$HOME/.cargo" "$HOME/.rustup"

    run "$SKN_CARGO" build
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain_pair "$args" '+W' "$HOME/.cargo"
    assert_args_contain_pair "$args" '+R' "$HOME/.rustup"
}

@test 'Rust wrappers surface skn +I failures and malformed headers' {
    export FAKE_SKN_INFO_RESULT=fail
    export FAKE_SKN_INFO_STATUS=37

    run "$SKN_CARGO" build
    assert_status 37
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]

    export FAKE_SKN_INFO_RESULT=malformed
    run "$SKN_RUST_ANALYZER" --stdio
    assert_status 2
    assert_output_contains 'internal error parsing skn +I output'
}

@test 'Rust wrappers handle unset home-related variables' {
    run env -u HOME -u CARGO_HOME -u RUSTUP_HOME PATH="$PATH" \
        FAKE_SKN_INFO_ARGS="$FAKE_SKN_INFO_ARGS" \
        FAKE_SKN_FINAL_ARGS="$FAKE_SKN_FINAL_ARGS" \
        FAKE_SKN_INFO_RESULT=disabled \
        FAKE_CARGO_LOCATE=fail \
        "$SKN_CARGO" build
    assert_success

    rm -f "$FAKE_SKN_FINAL_ARGS"

    run env -u HOME -u CARGO_HOME -u RUSTUP_HOME PATH="$PATH" \
        FAKE_SKN_INFO_ARGS="$FAKE_SKN_INFO_ARGS" \
        FAKE_SKN_FINAL_ARGS="$FAKE_SKN_FINAL_ARGS" \
        FAKE_SKN_INFO_RESULT=disabled \
        FAKE_CARGO_LOCATE=fail \
        "$SKN_RUST_ANALYZER" --stdio
    assert_success
}

@test 'skn-rust-analyzer binds detected workspaces writable' {
    workspace="$BATS_TEST_TMPDIR/ra-workspace"
    mkdir -p "$workspace"
    touch "$workspace/Cargo.toml"
    export FAKE_CARGO_LOCATE=success
    export FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml"

    run "$SKN_RUST_ANALYZER" --stdio
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" 'rust-analyzer'
    assert_args_contain "$args" '+W'
    assert_args_contain "$args" "$workspace"
    assert_args_contain "$args" 'CARGO_NET_OFFLINE=true'
}

@test 'skn-rust-analyzer falls back to read-only cwd outside Cargo workspaces' {
    launch="$BATS_TEST_TMPDIR/no-workspace"
    mkdir -p "$launch"
    export FAKE_CARGO_LOCATE=fail

    run bash -c 'cd "$1" && "$2" --stdio' _ "$launch" "$SKN_RUST_ANALYZER"
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" '+R'
    assert_args_contain "$args" "$launch"
    assert_args_not_contain "$args" '+W'
}
