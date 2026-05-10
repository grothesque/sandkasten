#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2016

load 'helpers/common'

@test 'normal execution requires and honors SKN_PATH_CHECK' {
    run env -u SKN_PATH_CHECK "$SKN" true
    assert_status 2
    assert_output_contains 'SKN_PATH_CHECK'

    dir="$BATS_TEST_TMPDIR/rejected"
    mkdir -p "$dir"

    run env SKN_PATH_CHECK=false "$SKN" true +R "$dir"
    assert_status 2
    assert_output_contains 'rejected'
}

@test 'launch cwd is not implicitly exposed' {
    require_working_skn

    project="$BATS_TEST_TMPDIR/project"
    marker="$project/host-marker"
    mkdir -p "$project"
    touch "$marker"

    run bash -c 'cd "$1" && SKN_PATH_CHECK=true "$2" bash -- -c '\''test ! -e "$1"'\'' bash "$3"' _ "$project" "$SKN" "$marker"
    assert_success
}

@test 'file bind works without explicit parent directory setup' {
    require_working_skn

    file="$BATS_TEST_TMPDIR/deep/a/b/file.txt"
    mkdir -p "$(dirname "$file")"
    printf 'hello\n' >"$file"

    run env SKN_PATH_CHECK=true "$SKN" bash +R "$file" -- -c 'test -f "$1" && grep -qx hello "$1"' bash "$file"
    assert_success
}

@test '+W persists writes to an explicit writable bind' {
    require_working_skn

    dir="$BATS_TEST_TMPDIR/writable"
    mkdir -p "$dir"

    run env SKN_PATH_CHECK=true "$SKN" bash +W "$dir" -- -c 'printf data >"$1/file"' bash "$dir"
    assert_success
    assert_file_exists "$dir/file"
}

@test '+R exposes paths read-only' {
    require_working_skn

    dir="$BATS_TEST_TMPDIR/read-only"
    mkdir -p "$dir"
    printf 'hello\n' >"$dir/file"

    run env SKN_PATH_CHECK=true "$SKN" bash +R "$dir" -- -c 'grep -qx hello "$1/file" && ! printf data >"$1/new"' bash "$dir"
    assert_success
    assert_file_not_exists "$dir/new"
}

@test 'environment is cleared by default and can be set or preserved' {
    require_working_skn

    run env SECRET=host SKN_PATH_CHECK=true "$SKN" bash -- -c 'test -z "${SECRET+x}"'
    assert_success

    run env SECRET=host SKN_PATH_CHECK=true "$SKN" bash +V SECRET=explicit -- -c '[[ ${SECRET:-} == explicit ]]'
    assert_success

    run env SECRET=host SKN_PATH_CHECK=true "$SKN" bash +V SECRET -- -c '[[ ${SECRET:-} == host ]]'
    assert_success

    run env SECRET=host SKN_PATH_CHECK=true "$SKN" bash +V SECRET=explicit +V SECRET -- -c '[[ ${SECRET:-} == host ]]'
    assert_success

    run env -u SECRET SKN_PATH_CHECK=true "$SKN" bash +V SECRET=explicit +V SECRET -- -c 'test -z "${SECRET+x}"'
    assert_success

    run env -u OPTIONAL SKN_PATH_CHECK=true "$SKN" bash +V OPTIONAL -- -c 'test -z "${OPTIONAL+x}"'
    assert_success

    run env path=host SKN_PATH_CHECK=true "$SKN" bash +V path +R . -- -c '[[ ${path:-} == host ]]'
    assert_success

    run env SECRET=host SKN_PASS_VARS=SECRET:ABSENT SKN_PATH_CHECK=true "$SKN" bash -- -c '
        [[ ${SECRET:-} == host ]]
        test -z "${ABSENT+x}"
    '
    assert_success

    run env SECRET=host SKN_PATH_CHECK=true "$SKN" bash +E -- -c '[[ ${SECRET:-} == host ]]'
    assert_success

    run env SECRET=host SKN_PATH_CHECK=true "$SKN" bash +E +V SECRET=explicit +V SECRET -- -c '[[ ${SECRET:-} == host ]]'
    assert_success

    run env path=host SKN_PATH_CHECK=true "$SKN" bash +E +R . -- -c '[[ ${path:-} == host ]]'
    assert_success
}

@test '+E and +V preserve original values for Bash special variables' {
    require_working_skn

    run env BASH_VERSION=caller SKN_PATH_CHECK=true "$SKN" /usr/bin/env +E
    assert_success
    assert_output_contains 'BASH_VERSION=caller'

    run env BASH_VERSION=caller SKN_PATH_CHECK=true "$SKN" /usr/bin/env +V BASH_VERSION
    assert_success
    assert_output_contains 'BASH_VERSION=caller'
}

@test 'nested skn inherits path-check bypass and read-only bind baseline' {
    require_working_skn

    dir="$BATS_TEST_TMPDIR/ro-baseline"
    mkdir -p "$dir"
    printf 'hello\n' >"$dir/file"

    run env SKN_PATH_CHECK=true SKN_RO_BINDS="$dir" "$SKN" bash +R "$SKN" -- -c '
        [[ ${SKN_PATH_CHECK:-} == true ]]
        [[ ${SKN_RO_BINDS:-} == "$2" ]]
        "$1" /bin/bash -- -c '\''grep -qx hello "$1/file"'\'' /bin/bash "$2"
    ' bash "$SKN" "$dir"
    assert_success
}

@test 'nested skn cannot make an outer read-only bind writable' {
    require_working_skn

    dir="$BATS_TEST_TMPDIR/outer-read-only"
    mkdir -p "$dir"

    run env SKN_PATH_CHECK=true "$SKN" bash +R "$SKN" +R "$dir" -- -c '
        "$1" /bin/bash +W "$2" -- -c '\''! printf data >"$1/new"'\'' /bin/bash "$2"
    ' bash "$SKN" "$dir"
    assert_success
    assert_file_not_exists "$dir/new"
}

@test '+T with nested +W discards ordinary writes but preserves explicitly writable subtree' {
    require_working_transient_overlay

    dir="$BATS_TEST_TMPDIR/transient-project"
    mkdir -p "$dir/out"

    run env SKN_PATH_CHECK=true "$SKN" bash +T "$dir" +W "$dir/out" -- -c '
        printf transient >"$1/transient"
        printf persistent >"$1/out/persistent"
        test -f "$1/transient"
        test -f "$1/out/persistent"
    ' bash "$dir"
    assert_success
    assert_file_not_exists "$dir/transient"
    assert_file_exists "$dir/out/persistent"
}

@test '+T rejects files in normal execution' {
    file="$BATS_TEST_TMPDIR/not-a-directory"
    printf 'hello\n' >"$file"

    run env SKN_PATH_CHECK=true "$SKN" true +T "$file"
    assert_status 2
    assert_output_contains '+T'
    assert_output_contains 'directory'
}

@test 'synthetic sandbox root is read-only after setup' {
    require_working_skn

    run env SKN_PATH_CHECK=true "$SKN" bash -- -c '! mkdir /skn-should-not-create-this'
    assert_success
}
