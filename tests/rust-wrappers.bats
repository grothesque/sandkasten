#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031

load 'helpers/common'

setup() {
    fake_bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"

    FAKE_SKN_SHOW_ARGS="$BATS_TEST_TMPDIR/skn-show.args"
    FAKE_SKN_FINAL_ARGS="$BATS_TEST_TMPDIR/skn-final.args"
    export FAKE_SKN_SHOW_ARGS FAKE_SKN_FINAL_ARGS

    cat >"$fake_bin/skn" <<'EOF'
#!/bin/bash
set -euo pipefail

has_show=0
for arg in "$@"; do
    if [[ $arg == +S ]]; then
        has_show=1
        break
    fi
done

if ((has_show)); then
    printf '%s\0' "$@" >"${FAKE_SKN_SHOW_ARGS:?}"
    case ${FAKE_SKN_SHOW_RESULT:-disabled} in
        disabled)
            echo 'skn: command: fake'
            echo 'skn: network disabled'
            echo 'skn: environment preserved'
            echo 'skn: bwrap command:'
            ;;
        enabled)
            echo 'skn: command: fake'
            echo 'skn: network enabled'
            echo 'skn: environment preserved'
            echo 'skn: bwrap command:'
            ;;
        malformed)
            echo 'skn: command: fake'
            echo 'not a skn header line'
            ;;
        fail)
            exit "${FAKE_SKN_SHOW_STATUS:-37}"
            ;;
        *)
            echo "fake skn: unknown FAKE_SKN_SHOW_RESULT" >&2
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
    export FAKE_SKN_SHOW_RESULT=disabled
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

@test 'skn-cargo adds offline mode and writable workspace when network is disabled' {
    workspace="$BATS_TEST_TMPDIR/workspace"
    mkdir -p "$workspace"
    touch "$workspace/Cargo.toml"
    export FAKE_CARGO_LOCATE=success
    export FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml"

    run "$SKN_CARGO" build
    assert_success

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
    export FAKE_SKN_SHOW_RESULT=enabled

    run "$SKN_CARGO" +N +nightly build
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" '+N'
    assert_args_contain "$args" '+nightly'
    assert_args_contain "$args" 'build'
    assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'
}

@test 'Rust wrappers surface skn +S failures and malformed headers' {
    export FAKE_SKN_SHOW_RESULT=fail
    export FAKE_SKN_SHOW_STATUS=37

    run "$SKN_CARGO" build
    assert_status 37
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]

    export FAKE_SKN_SHOW_RESULT=malformed
    run "$SKN_RUST_ANALYZER" --stdio
    assert_status 2
    assert_output_contains 'internal error parsing skn +S output'
}

@test 'Rust wrappers handle unset home-related variables' {
    run env -u HOME -u CARGO_HOME -u RUSTUP_HOME PATH="$PATH" \
        FAKE_SKN_SHOW_ARGS="$FAKE_SKN_SHOW_ARGS" \
        FAKE_SKN_FINAL_ARGS="$FAKE_SKN_FINAL_ARGS" \
        FAKE_SKN_SHOW_RESULT=disabled \
        FAKE_CARGO_LOCATE=fail \
        "$SKN_CARGO" build
    assert_success

    rm -f "$FAKE_SKN_FINAL_ARGS"

    run env -u HOME -u CARGO_HOME -u RUSTUP_HOME PATH="$PATH" \
        FAKE_SKN_SHOW_ARGS="$FAKE_SKN_SHOW_ARGS" \
        FAKE_SKN_FINAL_ARGS="$FAKE_SKN_FINAL_ARGS" \
        FAKE_SKN_SHOW_RESULT=disabled \
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
