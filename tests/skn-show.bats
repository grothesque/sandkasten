#!/usr/bin/env bats
# shellcheck shell=bash

load 'helpers/common'

@test '+S skips path checks and filesystem validation' {
    run env -u SKN_PATH_CHECK "$SKN" true +S +R ./missing-ro +W ./missing-w +T ./missing-t

    assert_success
    assert_output_contains 'skn: sandboxed command: true'
    assert_output_contains 'skn: network disabled'
    assert_output_contains 'skn: environment mostly cleared'
    assert_output_contains 'skn: equivalent invocation:'
    assert_output_contains 'skn: resulting bwrap invocation:'
    assert_output_contains '--ro-bind'
    assert_output_contains '--bind'
    assert_output_contains '--tmp-overlay'
}

@test '+S reports network, preserved environment, and prepended command args' {
    run env -u SKN_PATH_CHECK "$SKN" echo +S +N +P +A -n -- hello

    assert_success
    assert_output_contains 'skn: sandboxed command: echo -n hello'
    assert_output_contains 'skn: network enabled'
    assert_output_contains 'skn: environment preserved'
    assert_output_contains 'skn: equivalent invocation:'
    assert_output_contains '--share-net'
}

@test '+I prints only the info header and skips path checks and filesystem validation' {
    run env -u SKN_PATH_CHECK "$SKN" true +I +R ./missing-ro +W ./missing-w +T ./missing-t

    assert_success
    assert_output_contains 'skn: sandboxed command: true'
    assert_output_contains 'skn: network disabled'
    assert_output_contains 'skn: environment mostly cleared'
    assert_output_contains 'skn: equivalent invocation:'
    assert_output_not_contains 'skn: resulting bwrap invocation:'
    assert_output_not_contains '--ro-bind'
    assert_output_not_contains '--bind'
    assert_output_not_contains '--tmp-overlay'
}

@test '+I takes precedence over +S' {
    run env -u SKN_PATH_CHECK "$SKN" true +I +S +R ./missing-ro

    assert_success
    assert_output_contains 'skn: sandboxed command: true'
    assert_output_contains 'skn: equivalent invocation:'
    assert_output_not_contains 'skn: resulting bwrap invocation:'
}

@test '+S still rejects malformed skn options' {
    run env -u SKN_PATH_CHECK "$SKN" true +S +E 1BAD=value
    assert_failure
    assert_output_contains 'Invalid environment variable name'

    run env -u SKN_PATH_CHECK "$SKN" true +S +W
    assert_failure
    assert_output_contains 'Missing argument for +W'
}

@test 'option-looking command is diagnosed as misplaced skn option' {
    run "$SKN" +T. bash

    assert_failure
    assert_output_contains "COMMAND comes before skn options; got '+T.' as COMMAND"
}

@test 'unknown uppercase skn options are reserved' {
    run env -u SKN_PATH_CHECK "$SKN" true +I +Qfuture

    assert_failure
    assert_output_contains 'Unknown or reserved skn option: +Qfuture'
    assert_output_contains 'use -- before command arguments that start with +<uppercase>'
}

@test 'reserved-looking command arguments can be passed after --' {
    run env -u SKN_PATH_CHECK "$SKN" cargo +I -- +Xtoolchain build

    assert_success
    assert_output_contains 'skn: sandboxed command: cargo +Xtoolchain build'
}

@test 'lowercase plus command arguments still stop skn option parsing' {
    run env -u SKN_PATH_CHECK "$SKN" cargo +I +nightly build

    assert_success
    assert_output_contains 'skn: sandboxed command: cargo +nightly build'
}

@test '+S preserves user bind ordering' {
    dir="$BATS_TEST_TMPDIR/project"
    mkdir -p "$dir/out"

    run env -u SKN_PATH_CHECK "$SKN" true +S +T "$dir" +W "$dir/out"
    assert_success

    overlay_line=$(printf '%s\n' "$output" | line_number_matching '--overlay-src')
    bind_line=$(printf '%s\n' "$output" | line_number_matching "--bind $dir/out $dir/out")

    [[ -n $overlay_line ]]
    [[ -n $bind_line ]]
    [[ $overlay_line -lt $bind_line ]]
}
