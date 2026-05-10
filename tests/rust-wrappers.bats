#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031

load 'helpers/common'

setup() {
    fake_bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"

    FAKE_SKN_INFO_ARGS="$BATS_TEST_TMPDIR/skn-info.args"
    FAKE_SKN_FINAL_ARGS="$BATS_TEST_TMPDIR/skn-final.args"
    FAKE_CARGO_LOCATE_CWD="$BATS_TEST_TMPDIR/cargo-locate.cwd"
    export FAKE_SKN_INFO_ARGS FAKE_SKN_FINAL_ARGS FAKE_CARGO_LOCATE_CWD

    cat >"$fake_bin/skn" <<'EOF'
#!/bin/bash
set -euo pipefail

has_info=0
for arg in "$@"; do
    [[ $arg == +I ]] && has_info=1
done

if ((has_info)); then
    printf '%s\0' "$@" >"${FAKE_SKN_INFO_ARGS:?}"
    case ${FAKE_SKN_INFO_RESULT:-real} in
        real)
            exec "${REPO_ROOT:?}/skn" "$@"
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
    [[ -z ${FAKE_CARGO_LOCATE_CWD:-} ]] || printf '%s\n' "$PWD" >"$FAKE_CARGO_LOCATE_CWD"

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
    export FAKE_SKN_INFO_RESULT=real
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

assert_args_not_contain_env() {
    local lines=$1
    local name=$2

    if grep -E "^${name}=" "$lines" >/dev/null; then
        printf 'expected args not to contain environment assignment for: %s\n' "$name" >&2
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
    assert_args_contain "$args" '+E'
    assert_args_contain_pair "$args" '+W' "$workspace"
    assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
    assert_args_not_contain_env "$args" CARGO
    assert_args_not_contain_env "$args" PATH
    assert_args_contain "$args" 'build'
}

@test 'skn-cargo honors top-level -C for workspace detection' {
    parent="$BATS_TEST_TMPDIR/cargo-c-parent"
    launch="$parent/launch"
    workspace="$parent/workspace"
    mkdir -p "$launch" "$workspace"
    touch "$workspace/Cargo.toml"
    export FAKE_CARGO_LOCATE=success
    export FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml"

    run bash -c 'cd "$1" && "$2" -C ../workspace build' _ "$launch" "$SKN_CARGO"
    assert_success

    [[ $(<"$FAKE_CARGO_LOCATE_CWD") == "$workspace" ]]

    args="$BATS_TEST_TMPDIR/final-c.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain_pair "$args" '+W' "$workspace"
    assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
    assert_args_contain "$args" '-C'
    assert_args_contain "$args" '../workspace'
    assert_args_contain "$args" 'build'
}

@test 'skn-cargo treats -C after the Cargo subcommand as a command argument' {
    parent="$BATS_TEST_TMPDIR/cargo-c-after-parent"
    launch="$parent/launch"
    workspace="$parent/workspace"
    mkdir -p "$launch" "$workspace"
    touch "$workspace/Cargo.toml"
    export FAKE_CARGO_LOCATE=success
    export FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml"

    run bash -c 'cd "$1" && "$2" build -C ../workspace' _ "$launch" "$SKN_CARGO"
    assert_success

    [[ $(<"$FAKE_CARGO_LOCATE_CWD") == "$launch" ]]

    args="$BATS_TEST_TMPDIR/final-c-after.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
    assert_args_contain "$args" 'build'
    assert_args_contain "$args" '-C'
    assert_args_contain "$args" '../workspace'
}

@test 'skn-cargo enables network automatically for selected dependency-management subcommands' {
    local subcommand

    for subcommand in fetch update add generate-lockfile search; do
        rm -f "$FAKE_SKN_FINAL_ARGS"

        run "$SKN_CARGO" "$subcommand"
        assert_success

        args="$BATS_TEST_TMPDIR/final-auto-$subcommand.lines"
        write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
        assert_args_contain "$args" '+N'
        assert_args_contain "$args" "$subcommand"
        assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'
    done
}

@test 'skn-cargo allows explicit network for selected dependency-management subcommands' {
    local subcommand

    for subcommand in fetch update add generate-lockfile search; do
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

@test 'skn-cargo allows network after Cargo top-level options' {
    run "$SKN_CARGO" +N --locked fetch
    assert_success
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-locked.lines"
    assert_args_not_contain "$BATS_TEST_TMPDIR/final-locked.lines" 'CARGO_NET_OFFLINE=true'

    run "$SKN_CARGO" -q --color always fetch
    assert_success
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-color.lines"
    assert_args_contain "$BATS_TEST_TMPDIR/final-color.lines" '+N'

    run "$SKN_CARGO" +nightly --config net.git-fetch-with-cli=true update
    assert_success
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-config.lines"
    assert_args_contain "$BATS_TEST_TMPDIR/final-config.lines" '+N'

    run "$SKN_CARGO" --color=always --config=foo=bar search serde
    assert_success
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-search.lines"
    assert_args_contain "$BATS_TEST_TMPDIR/final-search.lines" '+N'

    run "$SKN_CARGO" -Z unstable-options fetch
    assert_success
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-z.lines"
    assert_args_contain "$BATS_TEST_TMPDIR/final-z.lines" '+N'

    run "$SKN_CARGO" -C . fetch
    assert_success
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-c-fetch.lines"
    assert_args_contain "$BATS_TEST_TMPDIR/final-c-fetch.lines" '+N'

    run "$SKN_CARGO" -C. update
    assert_success
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-c-attached-update.lines"
    assert_args_contain "$BATS_TEST_TMPDIR/final-c-attached-update.lines" '+N'
}

@test 'skn-cargo refuses network for build-like subcommands after Cargo top-level options' {
    run "$SKN_CARGO" +N --locked -q build
    assert_status 2
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]

    run "$SKN_CARGO" +N +nightly --color always test
    assert_status 2
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]

    run "$SKN_CARGO" +N -C . build
    assert_status 2
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
}

@test 'skn-cargo falls back to offline mode when it cannot identify the subcommand without +N' {
    run "$SKN_CARGO" --future-option fetch
    assert_success
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-unknown-option.lines"
    assert_args_not_contain "$BATS_TEST_TMPDIR/final-unknown-option.lines" '+N'
    assert_args_contain_pair "$BATS_TEST_TMPDIR/final-unknown-option.lines" '+V' 'CARGO_NET_OFFLINE=true'
}

@test 'skn-cargo refuses network for Cargo script mode and unknown top-level options' {
    run "$SKN_CARGO" +N -Zscript fetch
    assert_status 2
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]

    run "$SKN_CARGO" +N -Z script fetch
    assert_status 2
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]

    run "$SKN_CARGO" +N --future-option fetch
    assert_status 2
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]

    run "$SKN_CARGO" +N -C
    assert_status 2
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
}

@test 'skn-cargo refuses network for build-like or absent subcommands' {
    local subcommand

    for subcommand in build run check test clippy install ''; do
        rm -f "$FAKE_SKN_FINAL_ARGS"

        run "$SKN_CARGO" +N "$subcommand"
        assert_status 2
        [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
    done

    run "$SKN_CARGO" +N --version
    assert_status 2
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
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

@test 'skn-cargo uses SKN_REAL_CARGO and exports CARGO only when set' {
    export SKN_REAL_CARGO="$REAL_FAKE_CARGO"

    run "$SKN_CARGO" build
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" "$REAL_FAKE_CARGO"
    assert_args_contain_pair "$args" '+V' "CARGO=$REAL_FAKE_CARGO"
    assert_args_not_contain_env "$args" PATH
}

@test 'skn-cargo fails when strict PATH symlinks cargo to the wrapper' {
    rm -f "$fake_bin/cargo"
    ln -s "$SKN_CARGO" "$fake_bin/cargo"

    run "$fake_bin/cargo" build
    assert_status 2
    assert_output_contains 'recursive Cargo wrapper invocation'
    [[ -e $FAKE_SKN_INFO_ARGS ]]
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
}

@test 'skn-cargo fails when strict PATH launches the wrapper from a script' {
    cat >"$fake_bin/cargo" <<EOF
#!/bin/bash
exec "$SKN_CARGO" "\$@"
EOF
    chmod +x "$fake_bin/cargo"

    run "$fake_bin/cargo" build
    assert_status 2
    assert_output_contains 'recursive Cargo wrapper invocation'
    [[ -e $FAKE_SKN_INFO_ARGS ]]
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
}

@test 'skn-cargo strict PATH works when SKN_REAL_CARGO is set' {
    rm -f "$fake_bin/cargo"
    ln -s "$SKN_CARGO" "$fake_bin/cargo"
    export SKN_REAL_CARGO="$REAL_FAKE_CARGO"

    run "$fake_bin/cargo" build
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" "$REAL_FAKE_CARGO"
    assert_args_contain_pair "$args" '+V' "CARGO=$REAL_FAKE_CARGO"
}

@test 'skn-rust-analyzer uses SKN_REAL_RUST_ANALYZER and defaults CARGO to cargo' {
    export SKN_REAL_RUST_ANALYZER="$REAL_FAKE_RUST_ANALYZER"

    run "$SKN_RUST_ANALYZER" --stdio
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" "$REAL_FAKE_RUST_ANALYZER"
    assert_args_contain_pair "$args" '+V' 'CARGO=cargo'
    assert_args_not_contain_env "$args" PATH
}

@test 'skn-rust-analyzer uses SKN_REAL_CARGO for Cargo env' {
    export SKN_REAL_CARGO="$REAL_FAKE_CARGO"

    run "$SKN_RUST_ANALYZER" --stdio
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain_pair "$args" '+V' "CARGO=$REAL_FAKE_CARGO"
}

@test 'skn-rust-analyzer recursion guard fails clearly' {
    run env SKN_RUST_ANALYZER_WRAPPER_ACTIVE=1 "$SKN_RUST_ANALYZER" --stdio
    assert_status 2
    assert_output_contains 'recursive rust-analyzer wrapper invocation'
    assert_output_contains 'SKN_REAL_RUST_ANALYZER'
    [[ ! -e $FAKE_SKN_INFO_ARGS ]]
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
}

@test 'skn-rust-analyzer fails when Cargo resolves to skn-cargo without SKN_REAL_CARGO' {
    rm -f "$fake_bin/cargo"
    ln -s "$SKN_CARGO" "$fake_bin/cargo"

    run "$SKN_RUST_ANALYZER" --stdio
    assert_status 2
    [[ ! -e $FAKE_SKN_INFO_ARGS ]]
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
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
    assert_output_contains 'parsing skn +I output'
}

@test 'skn-rust-analyzer refuses network access' {
    run "$SKN_RUST_ANALYZER" +N --stdio
    assert_status 2
    assert_output_contains 'refusing +N'
    assert_output_contains 'skn-cargo fetch'
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
}

@test 'Rust wrappers handle unset home-related variables' {
    run env -u HOME -u CARGO_HOME -u RUSTUP_HOME PATH="$PATH" \
        FAKE_SKN_INFO_ARGS="$FAKE_SKN_INFO_ARGS" \
        FAKE_SKN_FINAL_ARGS="$FAKE_SKN_FINAL_ARGS" \
        FAKE_SKN_INFO_RESULT=real \
        FAKE_CARGO_LOCATE=fail \
        "$SKN_CARGO" build
    assert_success

    rm -f "$FAKE_SKN_FINAL_ARGS"

    run env -u HOME -u CARGO_HOME -u RUSTUP_HOME PATH="$PATH" \
        FAKE_SKN_INFO_ARGS="$FAKE_SKN_INFO_ARGS" \
        FAKE_SKN_FINAL_ARGS="$FAKE_SKN_FINAL_ARGS" \
        FAKE_SKN_INFO_RESULT=real \
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
    assert_args_contain_pair "$args" '+W' "$workspace"
    assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
}

@test 'skn-rust-analyzer falls back to read-only cwd outside Cargo workspaces' {
    launch="$BATS_TEST_TMPDIR/no-workspace"
    mkdir -p "$launch"
    export FAKE_CARGO_LOCATE=fail

    run bash -c 'cd "$1" && "$2" --stdio' _ "$launch" "$SKN_RUST_ANALYZER"
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain_pair "$args" '+R' "$launch"
    assert_args_not_contain "$args" '+W'
}
