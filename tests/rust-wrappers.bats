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

cmd=${1:-}
if (($#)); then
    shift
fi

has_info=0
network=0
command_args=()
remaining=("$@")

while ((${#remaining[@]})); do
    arg=${remaining[0]}
    case $arg in
        --)
            remaining=("${remaining[@]:1}")
            break
            ;;
        +N)
            network=1
            remaining=("${remaining[@]:1}")
            ;;
        +P|+S|+I)
            [[ $arg == +I ]] && has_info=1
            remaining=("${remaining[@]:1}")
            ;;
        +R|+W|+T|+E)
            remaining=("${remaining[@]:2}")
            ;;
        +R?*|+W?*|+T?*|+E?*)
            remaining=("${remaining[@]:1}")
            ;;
        +A)
            command_args+=("${remaining[1]:?}")
            remaining=("${remaining[@]:2}")
            ;;
        +A?*)
            command_args+=("${arg:2}")
            remaining=("${remaining[@]:1}")
            ;;
        *)
            break
            ;;
    esac
done

quote_shell_words() {
    local arg quoted out='' sep=''

    for arg in "$@"; do
        printf -v quoted '%q' "$arg"
        out+="$sep$quoted"
        sep=' '
    done

    printf '%s' "$out"
}

if ((has_info)); then
    printf '%s\0' "$cmd" "$@" >"${FAKE_SKN_INFO_ARGS:?}"
    case ${FAKE_SKN_INFO_RESULT:-disabled} in
        disabled)
            printf 'skn: sandboxed command: %s\n' "$(quote_shell_words "$cmd" "${command_args[@]}" "${remaining[@]}")"
            echo 'skn: network disabled'
            echo 'skn: environment preserved'
            echo 'skn: equivalent invocation: fake'
            ;;
        enabled)
            printf 'skn: sandboxed command: %s\n' "$(quote_shell_words "$cmd" "${command_args[@]}" "${remaining[@]}")"
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

printf '%s\0' "$cmd" "$@" >"${FAKE_SKN_FINAL_ARGS:?}"
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

    cat >"$fake_bin/rust-analyzer" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$fake_bin/rust-analyzer"

    real_bin="$BATS_TEST_TMPDIR/real-bin"
    mkdir -p "$real_bin"
    cp "$fake_bin/cargo" "$real_bin/cargo"
    cp "$fake_bin/rust-analyzer" "$real_bin/rust-analyzer"
    REAL_FAKE_CARGO="$real_bin/cargo"
    REAL_FAKE_RUST_ANALYZER="$real_bin/rust-analyzer"
    export REAL_FAKE_CARGO REAL_FAKE_RUST_ANALYZER

    unset SKN_REAL_CARGO SKN_REAL_RUST_ANALYZER
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
    assert_args_contain "$args" "$fake_bin/cargo"
    assert_args_contain "$args" '+P'
    assert_args_contain "$args" '+W'
    assert_args_contain "$args" "$workspace"
    assert_args_contain "$args" '+E'
    assert_args_contain "$args" 'CARGO_NET_OFFLINE=true'
    assert_args_contain "$args" 'build'
}

@test 'skn-cargo allows network for selected dependency-management subcommands' {
    local subcommand

    export FAKE_SKN_INFO_RESULT=enabled

    for subcommand in fetch update add upgrade generate-lockfile search; do
        rm -f "$FAKE_SKN_FINAL_ARGS"

        run "$SKN_CARGO" +N "$subcommand"
        assert_success

        args="$BATS_TEST_TMPDIR/final-$subcommand.lines"
        write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
        assert_args_contain "$args" '+N'
        assert_args_contain "$args" "$subcommand"
        assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'
    done
}

@test 'skn-cargo leaves offline mode unset for allowed network and passes cargo +toolchain args through' {
    export FAKE_SKN_INFO_RESULT=enabled

    run "$SKN_CARGO" +N +nightly fetch
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" '+N'
    assert_args_contain "$args" '+nightly'
    assert_args_contain "$args" 'fetch'
    assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'

    rm -f "$FAKE_SKN_FINAL_ARGS"
    run "$SKN_CARGO" +N -- +Xtoolchain fetch
    assert_success

    args="$BATS_TEST_TMPDIR/final-reserved-looking-toolchain.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" '+Xtoolchain'
    assert_args_contain "$args" 'fetch'
    assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'
}

@test 'skn-cargo refuses network for build-like or absent subcommands' {
    local subcommand

    export FAKE_SKN_INFO_RESULT=enabled

    for subcommand in build run check test clippy install ''; do
        rm -f "$FAKE_SKN_FINAL_ARGS"

        if [[ -n $subcommand ]]; then
            run "$SKN_CARGO" +N "$subcommand"
            assert_status 2
            assert_output_contains "refusing +N"
            assert_output_contains 'fetch, update, add, upgrade, generate-lockfile, search'
            assert_output_contains "$subcommand"
        else
            run "$SKN_CARGO" +N
            assert_status 2
            assert_output_contains 'refusing +N without an allowed Cargo subcommand'
        fi

        [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
    done
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

@test 'skn-cargo requires SKN_REAL_CARGO when cargo resolves to the wrapper' {
    rm -f "$fake_bin/cargo"
    ln -s "$SKN_CARGO" "$fake_bin/cargo"

    run "$SKN_CARGO" build
    assert_status 2
    assert_output_contains 'cargo resolves to this wrapper'
    assert_output_contains 'SKN_REAL_CARGO'
}

@test 'skn-cargo uses SKN_REAL_CARGO when cargo is shadowed' {
    rm -f "$fake_bin/cargo"
    ln -s "$SKN_CARGO" "$fake_bin/cargo"
    export SKN_REAL_CARGO="$REAL_FAKE_CARGO"

    run "$SKN_CARGO" build
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" "$REAL_FAKE_CARGO"
    assert_args_contain_pair "$args" '+E' "CARGO=$REAL_FAKE_CARGO"
}

@test 'skn-cargo rejects SKN_REAL_CARGO pointing to itself' {
    export SKN_REAL_CARGO="$SKN_CARGO"

    run "$SKN_CARGO" build
    assert_status 2
    assert_output_contains 'SKN_REAL_CARGO points to this wrapper'
}

@test 'skn-rust-analyzer requires SKN_REAL_RUST_ANALYZER when rust-analyzer resolves to the wrapper' {
    rm -f "$fake_bin/rust-analyzer"
    ln -s "$SKN_RUST_ANALYZER" "$fake_bin/rust-analyzer"

    run "$SKN_RUST_ANALYZER" --stdio
    assert_status 2
    assert_output_contains 'rust-analyzer resolves to this wrapper'
    assert_output_contains 'SKN_REAL_RUST_ANALYZER'
}

@test 'skn-rust-analyzer uses SKN_REAL_RUST_ANALYZER when rust-analyzer is shadowed' {
    rm -f "$fake_bin/rust-analyzer"
    ln -s "$SKN_RUST_ANALYZER" "$fake_bin/rust-analyzer"
    export SKN_REAL_RUST_ANALYZER="$REAL_FAKE_RUST_ANALYZER"

    run "$SKN_RUST_ANALYZER" --stdio
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" "$REAL_FAKE_RUST_ANALYZER"
    assert_args_contain_pair "$args" '+E' "CARGO=$fake_bin/cargo"
}

@test 'skn-rust-analyzer rejects SKN_REAL_RUST_ANALYZER pointing to itself' {
    export SKN_REAL_RUST_ANALYZER="$SKN_RUST_ANALYZER"

    run "$SKN_RUST_ANALYZER" --stdio
    assert_status 2
    assert_output_contains 'SKN_REAL_RUST_ANALYZER points to this wrapper'
}

@test 'skn-rust-analyzer requires SKN_REAL_CARGO when cargo resolves to skn-cargo' {
    rm -f "$fake_bin/cargo"
    ln -s "$SKN_CARGO" "$fake_bin/cargo"

    run "$SKN_RUST_ANALYZER" --stdio
    assert_status 2
    assert_output_contains 'cargo resolves to skn-cargo'
    assert_output_contains 'SKN_REAL_CARGO'
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

@test 'skn-rust-analyzer refuses network access' {
    export FAKE_SKN_INFO_RESULT=enabled

    run "$SKN_RUST_ANALYZER" +N --stdio
    assert_status 2
    assert_output_contains 'refusing +N'
    assert_output_contains 'skn-cargo +N fetch'
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
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
    assert_args_contain "$args" "$fake_bin/rust-analyzer"
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
