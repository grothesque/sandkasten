#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031

load 'helpers/common'

setup() {
    fake_bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"

    FAKE_SKN_INFO_ARGS="$BATS_TEST_TMPDIR/skn-info.args"
    FAKE_SKN_FINAL_ARGS="$BATS_TEST_TMPDIR/skn-final.args"
    FAKE_SKN_FINAL_ARGS_PREFIX="$BATS_TEST_TMPDIR/skn-final"
    FAKE_CARGO_LOCATE_CWD="$BATS_TEST_TMPDIR/cargo-locate.cwd"
    export FAKE_SKN_INFO_ARGS FAKE_SKN_FINAL_ARGS FAKE_SKN_FINAL_ARGS_PREFIX FAKE_CARGO_LOCATE_CWD

    cat >"$fake_bin/skn" <<'EOF'
#!/bin/bash
set -euo pipefail

has_info=0
for arg in "$@"; do
    [[ $arg == +0 ]] && has_info=1
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

final_status=${FAKE_SKN_FINAL_STATUS:-0}
if [[ -n ${FAKE_SKN_FINAL_ARGS_PREFIX:-} ]]; then
    count_file="$FAKE_SKN_FINAL_ARGS_PREFIX.count"
    if [[ -e $count_file ]]; then
        count=$(<"$count_file")
    else
        count=0
    fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    printf '%s\0' "$@" >"$FAKE_SKN_FINAL_ARGS_PREFIX.$count.args"

    if [[ ${FAKE_SKN_FINAL_FAIL_AT:-} == "$count" ]]; then
        final_status=${FAKE_SKN_FINAL_FAIL_STATUS:-64}
    fi
fi

printf '%s\0' "$@" >"${FAKE_SKN_FINAL_ARGS:?}"

if ((final_status != 0)); then
    exit "$final_status"
fi

if [[ ${1##*/} == rustc ]]; then
    for arg in "$@"; do
        if [[ $arg == --print ]]; then
            print_seen=1
        elif [[ ${print_seen:-0} == 1 && $arg == sysroot ]]; then
            [[ -z ${FAKE_SKN_SYSROOT:-} ]] || printf '%s\n' "$FAKE_SKN_SYSROOT"
            exit "$final_status"
        fi
    done
fi

exit "$final_status"
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
    unset FAKE_SKN_FINAL_FAIL_AT FAKE_SKN_FINAL_FAIL_STATUS FAKE_SKN_SYSROOT
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

run_skn_cargo_in() {
    local cwd=$1
    shift

    run bash -c 'cd "$1" && shift && "$@"' _ "$cwd" "$SKN_CARGO" "$@"
}

read_final_args() {
    args="$BATS_TEST_TMPDIR/$1.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
}

read_final_invocation_args() {
    local index=$1
    local name=$2

    args="$BATS_TEST_TMPDIR/$name.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS_PREFIX.$index.args" "$args"
}

assert_final_invocation_count() {
    local expected=$1
    local actual=0

    [[ ! -e $FAKE_SKN_FINAL_ARGS_PREFIX.count ]] || actual=$(<"$FAKE_SKN_FINAL_ARGS_PREFIX.count")
    if [[ $actual != "$expected" ]]; then
        printf 'expected final invocation count %s, got %s\n' "$expected" "$actual" >&2
        return 1
    fi
}

@test 'skn-cargo adds offline mode and narrow workspace grants when network is disabled' {
    workspace="$BATS_TEST_TMPDIR/workspace"
    member="$workspace/member"
    mkdir -p "$member"
    touch "$workspace/Cargo.toml"
    export FAKE_CARGO_LOCATE=success
    export FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml"

    run_skn_cargo_in "$member" build
    assert_success

    info_args="$BATS_TEST_TMPDIR/info.lines"
    write_args_lines "$FAKE_SKN_INFO_ARGS" "$info_args"
    assert_args_contain "$info_args" '+0'

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" 'cargo'
    assert_args_contain "$args" '+E'
    assert_args_contain_pair "$args" '+R' "$workspace"
    assert_args_contain_pair "$args" '+W' "$workspace/target"
    assert_args_contain_pair "$args" '+W' "$member"
    assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
    assert_args_not_contain_env "$args" CARGO
    assert_args_not_contain_env "$args" PATH
    assert_args_contain "$args" 'build'
}

@test 'skn-cargo creates missing workspace lockfile for dependency resolution' {
    workspace="$BATS_TEST_TMPDIR/lockfile-workspace"
    member="$workspace/member"
    mkdir -p "$member"
    touch "$workspace/Cargo.toml"
    export FAKE_CARGO_LOCATE=success
    export FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml"

    run_skn_cargo_in "$member" fetch
    assert_success
    assert_file_exists "$workspace/Cargo.lock"

    read_final_args final-lockfile
    assert_args_contain_pair "$args" '+W' "$workspace/Cargo.lock"
}

@test 'skn-cargo grants lockfile for unclassified subcommands' {
    workspace="$BATS_TEST_TMPDIR/unclassified-lockfile-workspace"
    member="$workspace/member"
    mkdir -p "$member"
    touch "$workspace/Cargo.toml"
    export FAKE_CARGO_LOCATE=success
    export FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml"

    run_skn_cargo_in "$member" remove serde
    assert_success
    assert_file_exists "$workspace/Cargo.lock"

    read_final_args final-unclassified-lockfile
    assert_args_contain_pair "$args" '+W' "$workspace/Cargo.lock"
}

@test 'skn-cargo does not create workspace lockfile when lock updates are forbidden' {
    workspace="$BATS_TEST_TMPDIR/locked-lockfile-workspace"
    member="$workspace/member"
    mkdir -p "$member"
    touch "$workspace/Cargo.toml"
    export FAKE_CARGO_LOCATE=success
    export FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml"

    run_skn_cargo_in "$member" fetch --locked
    assert_success
    assert_file_not_exists "$workspace/Cargo.lock"

    read_final_args final-locked-lockfile
    assert_args_not_contain "$args" "$workspace/Cargo.lock"
}

@test 'skn-cargo auto-prefetches cargo build before running build offline' {
    workspace="$BATS_TEST_TMPDIR/prefetch-workspace"
    member="$workspace/member"
    mkdir -p "$member"
    touch "$workspace/Cargo.toml"
    export FAKE_CARGO_LOCATE=success
    export FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml"

    run_skn_cargo_in "$member" +V RUSTFLAGS=-Dwarnings +T "$workspace" build
    assert_success
    assert_final_invocation_count 2

    read_final_invocation_args 1 fetch
    assert_args_contain "$args" '+N'
    assert_args_contain_pair "$args" '+R' "$workspace"
    assert_args_contain_pair "$args" '+W' "$workspace/target"
    assert_args_contain_pair "$args" '+W' "$member"
    assert_args_contain "$args" 'fetch'
    assert_args_not_contain "$args" 'build'
    assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'
    assert_args_contain "$args" '+VRUSTFLAGS=-Dwarnings'
    assert_args_contain "$args" "+T$workspace"
    target_line=$(line_number_matching "$workspace/target" <"$args")
    transient_line=$(line_number_matching "+T$workspace" <"$args")
    [[ -n $target_line && -n $transient_line ]]
    ((target_line < transient_line))

    read_final_invocation_args 2 build
    assert_args_not_contain "$args" '+N'
    assert_args_contain_pair "$args" '+R' "$workspace"
    assert_args_contain_pair "$args" '+W' "$workspace/target"
    assert_args_contain_pair "$args" '+W' "$member"
    assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
    assert_args_contain "$args" '+VRUSTFLAGS=-Dwarnings'
    assert_args_contain "$args" "+T$workspace"
    target_line=$(line_number_matching "$workspace/target" <"$args")
    transient_line=$(line_number_matching "+T$workspace" <"$args")
    [[ -n $target_line && -n $transient_line ]]
    ((target_line < transient_line))
    assert_args_contain "$args" 'build'
}

@test 'skn-cargo auto-prefetches common build-like subcommands before running them offline' {
    local subcommand

    for subcommand in check clippy doc test bench run; do
        rm -f "$FAKE_SKN_FINAL_ARGS" "$FAKE_SKN_FINAL_ARGS_PREFIX.count"
        run "$SKN_CARGO" "$subcommand"
        assert_success
        assert_final_invocation_count 2

        read_final_invocation_args 1 "fetch-$subcommand"
        assert_args_contain "$args" '+N'
        assert_args_contain "$args" 'fetch'
        assert_args_not_contain "$args" "$subcommand"
        assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'

        read_final_invocation_args 2 "$subcommand"
        assert_args_not_contain "$args" '+N'
        assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
        assert_args_contain "$args" "$subcommand"
    done
}

@test 'skn-cargo auto-prefetches built-in build-like aliases without expanding them' {
    local cargo_alias

    for cargo_alias in b c d t r; do
        rm -f "$FAKE_SKN_FINAL_ARGS" "$FAKE_SKN_FINAL_ARGS_PREFIX.count"
        run "$SKN_CARGO" "$cargo_alias"
        assert_success
        assert_final_invocation_count 2

        read_final_invocation_args 1 "fetch-alias-$cargo_alias"
        assert_args_contain "$args" '+N'
        assert_args_contain "$args" 'fetch'
        assert_args_not_contain "$args" "$cargo_alias"
        assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'

        read_final_invocation_args 2 "alias-$cargo_alias"
        assert_args_not_contain "$args" '+N'
        assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
        assert_args_contain "$args" "$cargo_alias"
    done
}

@test 'skn-cargo +S shows both auto-prefetch sandboxes' {
    local fetch_line build_line

    run env PATH="$REPO_ROOT:$PATH" SKN_REAL_CARGO="$REAL_FAKE_CARGO" "$SKN_CARGO" +S build
    assert_success

    assert_output_contains "skn: sandboxed command: $REAL_FAKE_CARGO fetch"
    assert_output_contains "skn: sandboxed command: $REAL_FAKE_CARGO build"
    assert_output_contains 'skn: network enabled'
    assert_output_contains 'skn: network disabled'
    assert_output_contains 'CARGO_NET_OFFLINE=true'

    fetch_line=$(printf '%s\n' "$output" | line_number_matching "skn: sandboxed command: $REAL_FAKE_CARGO fetch")
    build_line=$(printf '%s\n' "$output" | line_number_matching "skn: sandboxed command: $REAL_FAKE_CARGO build")
    [[ -n $fetch_line && -n $build_line ]]
    ((fetch_line < build_line))
}

@test 'skn-cargo uses inspect expansion mode for +S' {
    cat >"$fake_bin/skn-expansion-cargo" <<'EOF'
#!/bin/bash
printf '%s\n' "${SKN_EXPANSION_MODE:-unset}" >"${EXPANSION_MODE_FILE:?}"
EOF
    chmod +x "$fake_bin/skn-expansion-cargo"

    run env PATH="$REPO_ROOT:$PATH" \
        SKN_REAL_CARGO="$REAL_FAKE_CARGO" \
        EXPANSION_MODE_FILE="$BATS_TEST_TMPDIR/skn-cargo-show.mode" \
        "$SKN_CARGO" +S build

    assert_success
    [[ $(<"$BATS_TEST_TMPDIR/skn-cargo-show.mode") == inspect ]]
}

@test 'skn-cargo uses prepare expansion mode for execution' {
    cat >"$fake_bin/skn-expansion-cargo" <<'EOF'
#!/bin/bash
printf '%s\n' "${SKN_EXPANSION_MODE:-unset}" >"${EXPANSION_MODE_FILE:?}"
EOF
    chmod +x "$fake_bin/skn-expansion-cargo"

    run env EXPANSION_MODE_FILE="$BATS_TEST_TMPDIR/skn-cargo-execute.mode" "$SKN_CARGO" build

    assert_success
    [[ $(<"$BATS_TEST_TMPDIR/skn-cargo-execute.mode") == prepare ]]
}

@test 'wrappers prepare user expansions but not for show mode' {
    grant="$BATS_TEST_TMPDIR/user-expansion-grant"
    mode_file="$BATS_TEST_TMPDIR/user-expansion.modes"
    mkdir -p "$grant"
    export USER_EXPANSION_GRANT="$grant" USER_EXPANSION_MODE_FILE="$mode_file"

    cat >"$fake_bin/skn-expansion-user" <<'EOF'
#!/bin/bash
printf '%s\n' "${SKN_EXPANSION_MODE:-inspect}" >>"${USER_EXPANSION_MODE_FILE:?}"
printf '%s\n' +R "${USER_EXPANSION_GRANT:?}"
EOF
    chmod +x "$fake_bin/skn-expansion-user"

    run "$SKN_CARGO" +X user build
    assert_success
    assert_final_invocation_count 2
    [[ $(<"$mode_file") == $'inspect\nprepare' ]]

    read_final_invocation_args 1 fetch-user-expansion
    assert_args_contain "$args" "+R$grant"
    assert_args_not_contain "$args" '+Xuser'

    rm -f "$mode_file" "$FAKE_SKN_FINAL_ARGS_PREFIX.count"
    run "$SKN_CARGO" +S +X user build
    assert_success
    [[ $(<"$mode_file") == inspect ]]
}

@test 'wrapper policy checks see options emitted by expansions' {
    cat >"$fake_bin/skn-expansion-net" <<'EOF'
#!/bin/bash
printf '%s\n' +N
EOF
    chmod +x "$fake_bin/skn-expansion-net"

    run "$SKN_RUST_ANALYZER" +X net --stdio
    assert_status 2
    assert_output_contains 'refusing +N'

    cat >"$fake_bin/skn-expansion-offline" <<'EOF'
#!/bin/bash
printf '%s\n' +V CARGO_NET_OFFLINE=false
EOF
    chmod +x "$fake_bin/skn-expansion-offline"

    run "$SKN_CARGO" +X offline build
    assert_status 2
    assert_output_contains 'do not pass CARGO_NET_OFFLINE through skn +V'
}

@test 'skn-cargo constructs conservative cargo fetch arguments from cargo build' {
    workspace="$BATS_TEST_TMPDIR/fetch-args-workspace"
    mkdir -p "$workspace"
    touch "$workspace/Cargo.toml"
    export FAKE_CARGO_LOCATE=success
    export FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml"

    run "$SKN_CARGO" +nightly -Z unstable-options -C "$workspace" \
        --config net.git-fetch-with-cli=true -q build \
        --manifest-path Cargo.toml --target wasm32-unknown-unknown \
        --features serde --message-format=json
    assert_success
    assert_final_invocation_count 2

    read_final_invocation_args 1 fetch-build-args
    assert_args_contain "$args" '+nightly'
    assert_args_contain "$args" '-Z'
    assert_args_contain "$args" 'unstable-options'
    assert_args_contain "$args" '-C'
    assert_args_contain "$args" "$workspace"
    assert_args_contain "$args" 'fetch'
    assert_args_contain "$args" '--config'
    assert_args_contain "$args" 'net.git-fetch-with-cli=true'
    assert_args_contain "$args" '-q'
    assert_args_contain "$args" '--manifest-path'
    assert_args_contain "$args" 'Cargo.toml'
    assert_args_contain "$args" '--target'
    assert_args_contain "$args" 'wasm32-unknown-unknown'
    assert_args_not_contain "$args" 'build'
    assert_args_not_contain "$args" '--features'
    assert_args_not_contain "$args" 'serde'
    assert_args_not_contain "$args" '--message-format=json'
}

@test 'skn-cargo does not auto-prefetch cargo build when network or offline intent is explicit' {
    local words args
    local -a argv

    for words in '+N build' 'build --offline' 'build --frozen' '--offline build' '--frozen build' 'build --help' 'build -h'; do
        rm -f "$FAKE_SKN_FINAL_ARGS" "$FAKE_SKN_FINAL_ARGS_PREFIX.count"
        read -r -a argv <<<"$words"
        run "$SKN_CARGO" "${argv[@]}"
        assert_success
        assert_final_invocation_count 1

        args="$BATS_TEST_TMPDIR/final-no-prefetch-${words// /-}.lines"
        write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
        assert_args_contain "$args" 'build'
        if [[ $words == +N* ]]; then
            assert_args_contain "$args" '+N'
            assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'
        else
            assert_args_not_contain "$args" '+N'
            assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
        fi
    done

    rm -f "$FAKE_SKN_FINAL_ARGS" "$FAKE_SKN_FINAL_ARGS_PREFIX.count"
    run env CARGO_NET_OFFLINE=true "$SKN_CARGO" build
    assert_success
    assert_final_invocation_count 1
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-env-offline-build.lines"
    assert_args_not_contain "$BATS_TEST_TMPDIR/final-env-offline-build.lines" '+N'
    assert_args_contain_pair "$BATS_TEST_TMPDIR/final-env-offline-build.lines" '+V' 'CARGO_NET_OFFLINE=true'
}

@test 'skn-cargo skips auto-prefetch for supported top-level Cargo options that fetch cannot replay' {
    local words args
    local -a argv

    for words in '--version build' '--list build' '--explain E0308 build'; do
        rm -f "$FAKE_SKN_FINAL_ARGS" "$FAKE_SKN_FINAL_ARGS_PREFIX.count"
        read -r -a argv <<<"$words"
        run "$SKN_CARGO" "${argv[@]}"
        assert_success
        assert_final_invocation_count 1

        args="$BATS_TEST_TMPDIR/final-no-prefetch-${words// /-}.lines"
        write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
        assert_args_not_contain "$args" '+N'
        assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
    done
}

@test 'skn-cargo skips auto-prefetch for non-build commands with offline or help intent' {
    local words args
    local -a argv

    for words in 'test --offline' 'clippy --help'; do
        rm -f "$FAKE_SKN_FINAL_ARGS" "$FAKE_SKN_FINAL_ARGS_PREFIX.count"
        read -r -a argv <<<"$words"
        run "$SKN_CARGO" "${argv[@]}"
        assert_success
        assert_final_invocation_count 1

        args="$BATS_TEST_TMPDIR/final-no-prefetch-${words// /-}.lines"
        write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
        assert_args_not_contain "$args" '+N'
        assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
    done
}

@test 'skn-cargo still auto-prefetches when --help belongs to the program being run' {
    run "$SKN_CARGO" run -- --help
    assert_success
    assert_final_invocation_count 2

    read_final_invocation_args 1 fetch-run-help
    assert_args_contain "$args" '+N'
    assert_args_contain "$args" 'fetch'
    assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'

    read_final_invocation_args 2 run-help
    assert_args_not_contain "$args" '+N'
    assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
    assert_args_contain "$args" 'run'
    assert_args_contain "$args" '--help'
}

@test 'skn-cargo stops if build prefetch fails' {
    export FAKE_SKN_FINAL_STATUS=37

    run "$SKN_CARGO" build
    assert_status 37
    assert_final_invocation_count 1

    read_final_invocation_args 1 failed-fetch
    assert_args_contain "$args" '+N'
    assert_args_contain "$args" 'fetch'
    assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'
}

@test 'skn-cargo honors top-level -C for workspace detection' {
    parent="$BATS_TEST_TMPDIR/cargo-c-parent"
    launch="$parent/launch"
    workspace="$parent/workspace"
    mkdir -p "$launch" "$workspace"
    touch "$workspace/Cargo.toml"
    export FAKE_CARGO_LOCATE=success
    export FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml"

    run_skn_cargo_in "$launch" -C ../workspace build
    assert_success

    [[ $(<"$FAKE_CARGO_LOCATE_CWD") == "$workspace" ]]

    read_final_args final-c
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

    run_skn_cargo_in "$launch" build -C ../workspace
    assert_success

    [[ $(<"$FAKE_CARGO_LOCATE_CWD") == "$launch" ]]

    read_final_args final-c-after
    assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
    assert_args_contain "$args" 'build'
    assert_args_contain "$args" '-C'
    assert_args_contain "$args" '../workspace'
}

@test 'skn-cargo binds cargo new parent directory writable outside workspaces' {
    launch="$BATS_TEST_TMPDIR/new-launch"
    mkdir -p "$launch"

    run_skn_cargo_in "$launch" new foo
    assert_success
    read_final_args final-new
    assert_args_contain_pair "$args" '+W' "$launch"
}

@test 'skn-cargo binds cargo new parent relative to top-level -C' {
    parent="$BATS_TEST_TMPDIR/new-c-parent"
    launch="$parent/launch"
    cargo_dir="$parent/cargo-dir"
    crates_dir="$cargo_dir/crates"
    mkdir -p "$launch" "$crates_dir"

    run_skn_cargo_in "$launch" -C ../cargo-dir new --lib --name foo crates/foo
    assert_success
    read_final_args final-new-c
    assert_args_contain_pair "$args" '+W' "$crates_dir"
}

@test 'skn-cargo binds cargo init target directory or parent writable' {
    launch="$BATS_TEST_TMPDIR/init-launch"
    existing="$launch/existing"
    mkdir -p "$existing"

    run_skn_cargo_in "$launch" init existing
    assert_success
    read_final_args final-init-existing
    assert_args_contain_pair "$args" '+W' "$existing"

    rm -f "$FAKE_SKN_FINAL_ARGS"
    run_skn_cargo_in "$launch" init missing
    assert_success
    read_final_args final-init-missing
    assert_args_contain_pair "$args" '+W' "$launch"

    rm -f "$FAKE_SKN_FINAL_ARGS"
    run_skn_cargo_in "$launch" init --help
    assert_success
    read_final_args final-init-help
    assert_args_not_contain "$args" "$launch"
}

@test 'skn-cargo enables network automatically for safe registry and dependency subcommands' {
    local subcommand args

    for subcommand in fetch info metadata tree vendor; do
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

@test 'skn-cargo does not auto-enable network when Cargo offline intent is explicit' {
    local words args
    local -a argv

    for words in 'fetch --offline' 'fetch --frozen' '--offline fetch' '--frozen fetch'; do
        rm -f "$FAKE_SKN_FINAL_ARGS"
        read -r -a argv <<<"$words"
        run "$SKN_CARGO" "${argv[@]}"
        assert_success

        args="$BATS_TEST_TMPDIR/final-offline-intent-${words// /-}.lines"
        write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
        assert_args_not_contain "$args" '+N'
        assert_args_contain "$args" 'fetch'
    done

    rm -f "$FAKE_SKN_FINAL_ARGS"
    run env CARGO_NET_OFFLINE=true "$SKN_CARGO" fetch
    assert_success
    args="$BATS_TEST_TMPDIR/final-cargo-net-offline-true.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_not_contain "$args" '+N'
    assert_args_contain "$args" 'fetch'

    rm -f "$FAKE_SKN_FINAL_ARGS"
    run env CARGO_NET_OFFLINE=false "$SKN_CARGO" fetch
    assert_success
    args="$BATS_TEST_TMPDIR/final-cargo-net-offline-false.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" '+N'
}

@test 'skn-cargo allows explicit network for an auto-networked subcommand' {
    run "$SKN_CARGO" +N fetch
    assert_success

    args="$BATS_TEST_TMPDIR/final-fetch.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" '+N'
    assert_args_contain "$args" 'fetch'
    assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'
}

@test 'skn-cargo rejects ambiguous CARGO_NET_OFFLINE passed through skn +V' {
    run "$SKN_CARGO" +V CARGO_NET_OFFLINE=true build
    assert_status 2
    assert_output_contains 'do not pass CARGO_NET_OFFLINE through skn +V'
    [[ -e $FAKE_SKN_INFO_ARGS ]]
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]

    rm -f "$FAKE_SKN_INFO_ARGS"
    run "$SKN_CARGO" +VCARGO_NET_OFFLINE build
    assert_status 2
    assert_output_contains 'do not pass CARGO_NET_OFFLINE through skn +V'
    [[ -e $FAKE_SKN_INFO_ARGS ]]
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
}

@test 'skn-cargo still allows unrelated environment through skn +V' {
    run "$SKN_CARGO" +V RUSTFLAGS=-Dwarnings build
    assert_success

    args="$BATS_TEST_TMPDIR/final-v-rustflags.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" '+VRUSTFLAGS=-Dwarnings'
    assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
}

@test 'skn-cargo allows explicit network for neutral subcommands but keeps them offline by default' {
    run "$SKN_CARGO" upgrade
    assert_success
    args="$BATS_TEST_TMPDIR/final-upgrade-offline.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_not_contain "$args" '+N'
    assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
    assert_args_contain "$args" 'upgrade'

    rm -f "$FAKE_SKN_FINAL_ARGS"
    run "$SKN_CARGO" +N upgrade
    assert_success
    args="$BATS_TEST_TMPDIR/final-upgrade-network.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" '+N'
    assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'
    assert_args_contain "$args" 'upgrade'
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
    run "$SKN_CARGO" +N ++ +Xtoolchain fetch
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

    run "$SKN_CARGO" +nightly --config net.git-fetch-with-cli=true fetch
    assert_success
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-config.lines"
    assert_args_contain "$BATS_TEST_TMPDIR/final-config.lines" '+N'

    run "$SKN_CARGO" --color=always --config=foo=bar fetch --target wasm32-unknown-unknown
    assert_success
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-fetch-args.lines"
    assert_args_contain "$BATS_TEST_TMPDIR/final-fetch-args.lines" '+N'

    run "$SKN_CARGO" -Z unstable-options fetch
    assert_success
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-z.lines"
    assert_args_contain "$BATS_TEST_TMPDIR/final-z.lines" '+N'

    run "$SKN_CARGO" -C . fetch
    assert_success
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-c-fetch.lines"
    assert_args_contain "$BATS_TEST_TMPDIR/final-c-fetch.lines" '+N'

    run "$SKN_CARGO" -C. fetch
    assert_success
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-c-attached-fetch.lines"
    assert_args_contain "$BATS_TEST_TMPDIR/final-c-attached-fetch.lines" '+N'
}

@test 'skn-cargo allows explicit network for a denied subcommand after Cargo top-level options' {
    run "$SKN_CARGO" +N --locked -q build
    assert_success
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-build-locked.lines"
    assert_args_contain "$BATS_TEST_TMPDIR/final-build-locked.lines" '+N'
    assert_args_not_contain "$BATS_TEST_TMPDIR/final-build-locked.lines" 'CARGO_NET_OFFLINE=true'

    rm -f "$FAKE_SKN_FINAL_ARGS"
    run "$SKN_CARGO" +N -C . build
    assert_success
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$BATS_TEST_TMPDIR/final-build-c.lines"
    assert_args_contain "$BATS_TEST_TMPDIR/final-build-c.lines" '+N'
    assert_args_not_contain "$BATS_TEST_TMPDIR/final-build-c.lines" 'CARGO_NET_OFFLINE=true'
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

@test 'skn-cargo runs cargo install offline by default' {
    local words install_args="$BATS_TEST_TMPDIR/final-install-default.lines"
    local -a argv

    for words in 'install cargo-edit' 'install --git=https://example.invalid/repo.git'; do
        rm -f "$FAKE_SKN_FINAL_ARGS"
        read -r -a argv <<<"$words"
        run "$SKN_CARGO" "${argv[@]}"
        assert_success
        write_args_lines "$FAKE_SKN_FINAL_ARGS" "$install_args"
        assert_args_contain_pair "$install_args" '+V' 'CARGO_NET_OFFLINE=true'
    done
}

@test 'skn-cargo allows explicit network for cargo install' {
    run "$SKN_CARGO" +N install cargo-edit
    assert_success

    args="$BATS_TEST_TMPDIR/final-install-network.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" '+N'
    assert_args_contain "$args" 'install'
    assert_args_contain "$args" 'cargo-edit'
    assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'
}

@test 'skn-cargo still permits clearly local or offline cargo install forms' {
    local words install_args="$BATS_TEST_TMPDIR/final-install.lines"
    local -a argv

    for words in 'install --list' 'install --path . --locked' 'install --offline cargo-edit'; do
        rm -f "$FAKE_SKN_FINAL_ARGS"
        read -r -a argv <<<"$words"
        run "$SKN_CARGO" "${argv[@]}"
        assert_success
        write_args_lines "$FAKE_SKN_FINAL_ARGS" "$install_args"
        assert_args_contain_pair "$install_args" '+V' 'CARGO_NET_OFFLINE=true'
    done
}

@test 'skn-cargo allows explicit network for denied aliases, denied subcommands, or absent subcommands' {
    local subcommand args

    for subcommand in b c d r t build; do
        rm -f "$FAKE_SKN_FINAL_ARGS"
        run "$SKN_CARGO" +N "$subcommand"
        assert_success
        args="$BATS_TEST_TMPDIR/final-network-$subcommand.lines"
        write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
        assert_args_contain "$args" '+N'
        assert_args_contain "$args" "$subcommand"
        assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'
    done

    rm -f "$FAKE_SKN_FINAL_ARGS"
    run "$SKN_CARGO" +N
    assert_success
    args="$BATS_TEST_TMPDIR/final-network-no-subcommand.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" '+N'
    assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'

    rm -f "$FAKE_SKN_FINAL_ARGS"
    run "$SKN_CARGO" +N --version
    assert_success
    args="$BATS_TEST_TMPDIR/final-network-version.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" '+N'
    assert_args_contain "$args" '--version'
    assert_args_not_contain "$args" 'CARGO_NET_OFFLINE=true'
}

@test 'skn-cargo adds narrow home binds as explicit skn options when present' {
    mkdir -p "$HOME/.cargo" "$HOME/.rustup"

    run "$SKN_CARGO" build
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain_pair "$args" '+R' "$HOME/.cargo"
    assert_args_contain_pair "$args" '+W' "$HOME/.cargo/registry"
    assert_args_contain_pair "$args" '+W' "$HOME/.cargo/git"
    assert_args_contain_pair "$args" '+R' "$HOME/.rustup"
    assert_file_exists "$HOME/.cargo/registry"
    assert_file_exists "$HOME/.cargo/git"
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

@test 'skn-cargo recursion depth guard allows the last permitted level and rejects the next one' {
    export SKN_REAL_CARGO="$REAL_FAKE_CARGO"

    run env SKN_CARGO_WRAPPER_DEPTH=4 "$SKN_CARGO" build
    assert_success

    args="$BATS_TEST_TMPDIR/final-depth-ok.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" "$REAL_FAKE_CARGO"

    rm -f "$FAKE_SKN_INFO_ARGS" "$FAKE_SKN_FINAL_ARGS"

    run env SKN_CARGO_WRAPPER_DEPTH=5 "$SKN_CARGO" build
    assert_status 2
    assert_output_contains 'recursive Cargo wrapper invocation'
    assert_output_contains 'depth exceeded'
    [[ ! -e $FAKE_SKN_INFO_ARGS ]]
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
}

@test 'skn-cargo recursive strict PATH loops stop at the configured depth' {
    rm -f "$fake_bin/cargo"
    ln -s "$SKN_CARGO" "$fake_bin/cargo"

    run env SKN_CARGO_WRAPPER_MAX_DEPTH=2 "$fake_bin/cargo" build
    assert_status 2
    assert_output_contains 'recursive Cargo wrapper invocation'
    assert_output_contains 'depth exceeded'
    [[ -e $FAKE_SKN_INFO_ARGS ]]
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
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

    run env PATH="$REPO_ROOT:$REPO_ROOT/rust:$fake_bin:$PATH" "$SKN_RUST_ANALYZER" --stdio
    assert_status 2
    assert_output_contains 'recursive Cargo wrapper invocation'
    [[ ! -e $FAKE_SKN_INFO_ARGS ]]
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
}

@test 'Rust wrappers surface skn +0 failures and malformed output' {
    export FAKE_SKN_INFO_RESULT=fail
    export FAKE_SKN_INFO_STATUS=37

    run "$SKN_CARGO" build
    assert_status 2
    assert_output_contains 'parsing skn +0 output'
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]

    export FAKE_SKN_INFO_RESULT=malformed
    run "$SKN_RUST_ANALYZER" --stdio
    assert_status 2
    assert_output_contains 'parsing skn +0 output'
}

@test 'Rust wrappers reject user +0 before prefetch or final execution' {
    run "$SKN_CARGO" +0 build
    assert_status 2
    assert_output_contains '+0 is an skn-only option and may only be given once'
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
    assert_final_invocation_count 0

    run "$SKN_RUST_ANALYZER" +0 --stdio
    assert_status 2
    assert_output_contains '+0 is an skn-only option and may only be given once'
    [[ ! -e $FAKE_SKN_FINAL_ARGS ]]
    assert_final_invocation_count 0
}

@test 'skn-rust-analyzer refuses network access' {
    run "$SKN_RUST_ANALYZER" +N --stdio
    assert_status 2
    assert_output_contains 'refusing +N'
    [[ ! -e $FAKE_CARGO_LOCATE_CWD ]]
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

@test 'skn-rust-analyzer prefetches project dependencies before launching offline' {
    run "$SKN_RUST_ANALYZER" +R /tmp --stdio
    assert_success
    assert_final_invocation_count 3

    read_final_invocation_args 1 project-fetch
    assert_args_contain "$args" 'cargo'
    assert_args_contain "$args" '+E'
    assert_args_contain "$args" '+R/tmp'
    assert_args_contain "$args" '+N'
    assert_args_contain_pair "$args" '+X' 'cargo'
    assert_args_contain "$args" 'fetch'

    read_final_invocation_args 2 sysroot-discovery
    assert_args_contain "$args" 'rustc'
    assert_args_contain_pair "$args" '+X' 'cargo:no-lockfile'
    assert_args_contain "$args" '--print'
    assert_args_contain "$args" 'sysroot'

    read_final_invocation_args 3 rust-analyzer-final
    assert_args_contain "$args" 'rust-analyzer'
    assert_args_contain_pair "$args" '+X' 'cargo:rust-analyzer'
    assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
}

@test 'skn-rust-analyzer continues when project prefetch fails' {
    export FAKE_SKN_FINAL_FAIL_AT=1

    run "$SKN_RUST_ANALYZER" --stdio
    assert_success
    assert_final_invocation_count 3

    read_final_invocation_args 1 project-fetch
    assert_args_contain "$args" 'cargo'
    assert_args_contain "$args" 'fetch'

    read_final_invocation_args 3 rust-analyzer-final
    assert_args_contain "$args" 'rust-analyzer'
    assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
}

@test 'skn-rust-analyzer prefetches sysroot dependencies when rust-src is present' {
    sysroot="$BATS_TEST_TMPDIR/sysroot"
    library="$sysroot/lib/rustlib/src/rust/library"
    mkdir -p "$library"
    touch "$library/Cargo.toml"
    export FAKE_SKN_SYSROOT="$sysroot"

    run "$SKN_RUST_ANALYZER" --stdio
    assert_success
    assert_final_invocation_count 4

    read_final_invocation_args 3 sysroot-fetch
    assert_args_contain "$args" 'cargo'
    assert_args_contain "$args" '+N'
    assert_args_contain_pair "$args" '+X' 'cargo:no-lockfile'
    assert_args_contain_pair "$args" '+R' "$sysroot"
    assert_args_contain_pair "$args" '+V' '__CARGO_TEST_CHANNEL_OVERRIDE_DO_NOT_USE_THIS=nightly'
    assert_args_contain_pair "$args" '+V' "RUSTUP_TOOLCHAIN=$sysroot"
    assert_args_contain "$args" 'fetch'
    assert_args_contain "$args" '--locked'
    assert_args_contain_pair "$args" '--manifest-path' "$library/Cargo.toml"

    read_final_invocation_args 4 rust-analyzer-final
    assert_args_contain "$args" 'rust-analyzer'
    assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
}

@test 'skn-rust-analyzer uses the cargo rust-analyzer expansion profile' {
    workspace="$BATS_TEST_TMPDIR/ra-workspace"
    member="$workspace/member"
    mkdir -p "$member"
    touch "$workspace/Cargo.toml"
    export FAKE_CARGO_LOCATE=success
    export FAKE_WORKSPACE_MANIFEST="$workspace/Cargo.toml"

    run bash -c 'cd "$1" && "$2" --stdio' _ "$member" "$SKN_RUST_ANALYZER"
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_contain "$args" 'rust-analyzer'
    assert_args_contain_pair "$args" '+X' 'cargo:rust-analyzer'
    assert_args_not_contain "$args" "$member"
    assert_args_contain_pair "$args" '+V' 'CARGO_NET_OFFLINE=true'
}

@test 'skn-rust-analyzer adds no cwd grant outside Cargo workspaces' {
    launch="$BATS_TEST_TMPDIR/no-workspace"
    mkdir -p "$launch"
    export FAKE_CARGO_LOCATE=fail

    run bash -c 'cd "$1" && "$2" --stdio' _ "$launch" "$SKN_RUST_ANALYZER"
    assert_success

    args="$BATS_TEST_TMPDIR/final.lines"
    write_args_lines "$FAKE_SKN_FINAL_ARGS" "$args"
    assert_args_not_contain "$args" "$launch"
}
