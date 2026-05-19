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
    run env -u SKN_PATH_CHECK "$SKN" echo +S +N +E +A -n -- hello

    assert_success
    assert_output_contains 'skn: sandboxed command: echo -n hello'
    assert_output_contains 'skn: network enabled'
    assert_output_contains 'skn: environment preserved'
    assert_output_contains 'skn: equivalent invocation:'
    assert_output_contains '--share-net'
}

@test '+S shows default namespace and optional system bind setup' {
    local path

    run env -u SKN_PATH_CHECK "$SKN" true +S

    assert_success
    assert_output_contains '--unshare-all'
    assert_output_contains '--hostname skn'
    assert_output_contains '--ro-bind /usr /usr'

    for path in /bin /sbin /etc/alternatives /etc/manpath.config /etc/man_db.conf /etc/man.conf; do
        assert_output_contains "--ro-bind-try $path $path"
    done
}

@test '+S only includes DNS and CA root binds when network is enabled' {
    local path

    run env -u SKN_PATH_CHECK "$SKN" true +S

    assert_success
    assert_output_not_contains '/etc/resolv.conf'
    assert_output_not_contains '/etc/ssl/certs'
    assert_output_not_contains '/etc/hosts'

    run env -u SKN_PATH_CHECK "$SKN" true +S +N

    assert_success
    for path in /etc/resolv.conf /etc/ssl/certs /etc/ssl/cert.pem; do
        assert_output_contains "--ro-bind-try $path $path"
    done
    assert_output_not_contains '/etc/hosts'
}

@test '+0 prints machine-readable info and skips path checks and filesystem validation' {
    run bash -c 'env -u SKN_PATH_CHECK "$1" true +0 +R ./missing-ro +W ./missing-w +T ./missing-t | tr "\0" "\n"' _ "$SKN"

    assert_success
    assert_output_contains 'skn-info-mk1'
    assert_output_contains 'network'
    assert_output_contains 'disabled'
    assert_output_contains 'environment'
    assert_output_contains 'cleared'
    assert_output_contains 'argc: 1'
    assert_output_contains 'true'
    assert_output_not_contains 'skn: resulting bwrap invocation:'
}

@test '+0 takes precedence over +S' {
    run bash -c 'env -u SKN_PATH_CHECK "$1" true +0 +S +R ./missing-ro | tr "\0" "\n"' _ "$SKN"

    assert_success
    assert_output_contains 'skn-info-mk1'
    assert_output_contains 'argc: 1'
    assert_output_contains 'true'
    assert_output_not_contains 'skn: resulting bwrap invocation:'
}

@test '+0 preserves parsed argv exactly' {
    run bash -s "$SKN" <<'EOF'
set -euo pipefail

skn=$1
expected=(
    cmd
    ''
    'space arg'
    $'line\narg'
    'quote'\''"back\slash'
    '+Xafter'
    '-dash'
)

format=
network=
argc=
header_done=0

exec {info_fd}< <(
    env -u SKN_PATH_CHECK "$skn" cmd +0 \
        +A '' \
        +A 'space arg' \
        +A $'line\narg' \
        -- 'quote'\''"back\slash' '+Xafter' '-dash'
)

while IFS= read -r -u "$info_fd" line; do
    [[ -n $line ]] || { header_done=1; break; }
    case $line in
        'format: '*) format=${line#'format: '} ;;
        'network: '*) network=${line#'network: '} ;;
        'argc: '*) argc=${line#'argc: '} ;;
    esac
done

((header_done))
[[ $format == skn-info-mk1 ]]
[[ $network == disabled ]]
[[ $argc == "${#expected[@]}" ]]

actual=()
for ((i = 0; i < 10#$argc; ++i)); do
    IFS= read -r -d '' -u "$info_fd" arg
    actual+=("$arg")
done

[[ ${#actual[@]} == ${#expected[@]} ]]
for ((i = 0; i < ${#expected[@]}; ++i)); do
    [[ ${actual[i]} == "${expected[i]}" ]]
done
EOF
    assert_success
}

@test '+S still rejects malformed skn options' {
    run env -u SKN_PATH_CHECK "$SKN" true +S +V 1BAD=value
    assert_status 2
    assert_output_contains 'environment variable name'

    run env -u SKN_PATH_CHECK "$SKN" true +S +V 1BAD
    assert_status 2
    assert_output_contains 'environment variable name'

    run env -u SKN_PATH_CHECK "$SKN" true +S +W
    assert_status 2
    assert_output_contains 'missing argument'
    assert_output_contains '+W'
}

@test 'option-looking command is diagnosed as misplaced skn option' {
    run "$SKN" +T. bash

    assert_status 2
    assert_output_contains 'COMMAND'
    assert_output_contains '+T.'
}

@test 'unknown uppercase skn options are reserved' {
    run env -u SKN_PATH_CHECK "$SKN" true +0 +Qfuture

    assert_status 2
    assert_output_contains 'reserved'
    assert_output_contains '+Qfuture'
}

@test 'reserved-looking command arguments can be passed after --' {
    run bash -c 'env -u SKN_PATH_CHECK "$1" cargo +0 -- +Xtoolchain build | tr "\0" "\n"' _ "$SKN"

    assert_success
    assert_output_contains 'cargo'
    assert_output_contains '+Xtoolchain'
    assert_output_contains 'build'
}

@test 'lowercase plus command arguments still stop skn option parsing' {
    run bash -c 'env -u SKN_PATH_CHECK "$1" cargo +0 +nightly build | tr "\0" "\n"' _ "$SKN"

    assert_success
    assert_output_contains 'cargo'
    assert_output_contains '+nightly'
    assert_output_contains 'build'
}

@test '+S accepts absolute SKN_RO_BINDS entries' {
    dir="$BATS_TEST_TMPDIR/ro-bind"

    run env -u SKN_PATH_CHECK SKN_RO_BINDS="$dir" "$SKN" true +S

    assert_success
    assert_output_contains "--ro-bind $dir $dir"
}

@test 'SKN_RO_BINDS rejects relative paths' {
    run env -u SKN_PATH_CHECK SKN_RO_BINDS=relative "$SKN" true +S

    assert_status 2
    assert_output_contains 'SKN_RO_BINDS'
    assert_output_contains 'absolute'
}

@test '+S shows variables requested with +V and SKN_PASS_VARS' {
    run env -u SKN_PATH_CHECK FROM_OPTION=option FROM_CONFIG=config \
        SKN_PASS_VARS=FROM_CONFIG:ABSENT "$SKN" true +S +V FROM_OPTION +V EXPLICIT=value

    assert_success
    assert_output_contains '--setenv SKN_PASS_VARS FROM_CONFIG:ABSENT'
    assert_output_contains '--setenv FROM_CONFIG config'
    assert_output_contains '--setenv FROM_OPTION option'
    assert_output_contains '--setenv EXPLICIT value'
}

@test 'bare +V pass-through is a no-op when the full environment is preserved' {
    run env -u SKN_PATH_CHECK FROM_OPTION=option FROM_CONFIG=config \
        SKN_PASS_VARS=FROM_CONFIG "$SKN" true +S +E +V FROM_OPTION +V EXPLICIT=value

    assert_success
    assert_output_contains 'skn: environment preserved'
    assert_output_not_contains '--setenv FROM_CONFIG config'
    assert_output_not_contains '--setenv FROM_OPTION option'
    assert_output_contains '--setenv EXPLICIT value'
}

@test 'SKN_PASS_VARS rejects empty entries and assignments' {
    run env -u SKN_PATH_CHECK SKN_PASS_VARS=FOO: "$SKN" true +S
    assert_status 2
    assert_output_contains 'SKN_PASS_VARS'
    assert_output_contains 'empty'

    run env -u SKN_PATH_CHECK SKN_PASS_VARS=FOO=bar "$SKN" true +S
    assert_status 2
    assert_output_contains 'SKN_PASS_VARS'
    assert_output_contains 'variable names'
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
