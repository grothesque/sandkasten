#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SKN="$REPO_ROOT/skn"
SKN_CARGO="$REPO_ROOT/rust/skn-cargo"
SKN_RUST_ANALYZER="$REPO_ROOT/rust/skn-rust-analyzer"
PATH="$REPO_ROOT:$PATH"
export REPO_ROOT SKN SKN_CARGO SKN_RUST_ANALYZER PATH

assert_success() {
    if [[ $status -ne 0 ]]; then
        printf 'expected success, got status %s\n' "$status" >&2
        printf 'output:\n%s\n' "$output" >&2
        return 1
    fi
}

assert_status() {
    local expected=$1

    if [[ $status -ne $expected ]]; then
        printf 'expected status %s, got %s\n' "$expected" "$status" >&2
        printf 'output:\n%s\n' "$output" >&2
        return 1
    fi
}

assert_output_contains() {
    local needle=$1

    if [[ $output != *"$needle"* ]]; then
        printf 'expected output to contain: %s\n' "$needle" >&2
        printf 'output:\n%s\n' "$output" >&2
        return 1
    fi
}

assert_output_not_contains() {
    local needle=$1

    if [[ $output == *"$needle"* ]]; then
        printf 'expected output not to contain: %s\n' "$needle" >&2
        printf 'output:\n%s\n' "$output" >&2
        return 1
    fi
}

assert_file_exists() {
    local path=$1

    if [[ ! -e $path ]]; then
        printf 'expected file to exist: %s\n' "$path" >&2
        return 1
    fi
}

assert_file_not_exists() {
    local path=$1

    if [[ -e $path ]]; then
        printf 'expected file not to exist: %s\n' "$path" >&2
        return 1
    fi
}

require_working_skn() {
    command -v bwrap >/dev/null 2>&1 || skip 'bwrap not installed'

    if ! SKN_PATH_CHECK=true "$SKN" true >/dev/null 2>&1; then
        skip 'bwrap/skn is not usable in this environment'
    fi
}

require_working_transient_overlay() {
    local dir

    require_working_skn
    dir="$BATS_TEST_TMPDIR/overlay-probe"
    mkdir -p "$dir"

    if ! SKN_PATH_CHECK=true "$SKN" true +T "$dir" >/dev/null 2>&1; then
        skip '+T transient overlays are not usable in this environment'
    fi
}

line_number_matching() {
    local pattern=$1

    awk -v pattern="$pattern" 'index($0, pattern) { print NR; exit }'
}
