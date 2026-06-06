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
    run env -u SKN_PATH_CHECK "$SKN" echo +S +N +E +A -n ++ hello

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
    assert_output_contains 'skn-info-mk2'
    assert_output_contains 'argc: 5'
    assert_output_contains '+R./missing-ro'
    assert_output_contains '+W./missing-w'
    assert_output_contains '+T./missing-t'
    assert_output_contains '++'
    assert_output_contains 'true'
    assert_output_not_contains 'network:'
    assert_output_not_contains 'environment:'
    assert_output_not_contains 'skn: resulting bwrap invocation:'
}

@test '+0 takes precedence over +S' {
    run bash -c 'env -u SKN_PATH_CHECK "$1" true +0 +S +R ./missing-ro | tr "\0" "\n"' _ "$SKN"

    assert_success
    assert_output_contains 'skn-info-mk2'
    assert_output_contains 'argc: 4'
    assert_output_contains '+S'
    assert_output_contains '+R./missing-ro'
    assert_output_contains '++'
    assert_output_contains 'true'
    assert_output_not_contains 'skn: resulting bwrap invocation:'
}

@test '+0 emits a directly replayable equivalent invocation' {
    run bash -s "$SKN" <<'EOF'
set -euo pipefail

skn=$1
expected=(cmd +E +N '+VFOO=bar' '+R./space path' ++ prep run)
format=
argc=
header_done=0

exec {info_fd}< <(
    env -u SKN_PATH_CHECK "$skn" cmd +0 +E +N +V FOO=bar +R './space path' +A prep run
)

while IFS= read -r -u "$info_fd" line; do
    [[ -n $line ]] || { header_done=1; break; }
    case $line in
        'format: '*) format=${line#'format: '} ;;
        'argc: '*) argc=${line#'argc: '} ;;
    esac
done

((header_done))
[[ $format == skn-info-mk2 ]]
[[ $argc == "${#expected[@]}" ]]

actual=()
for ((i = 0; i < 10#$argc; ++i)); do
    IFS= read -r -d '' -u "$info_fd" arg
    actual+=("$arg")
done

for ((i = 0; i < ${#expected[@]}; ++i)); do
    [[ ${actual[i]} == "${expected[i]}" ]]
done
EOF
    assert_success
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
argc=
header_done=0

exec {info_fd}< <(
    env -u SKN_PATH_CHECK "$skn" cmd +0 \
        +A '' \
        +A 'space arg' \
        +A $'line\narg' \
        ++ 'quote'\''"back\slash' '+Xafter' '-dash'
)

while IFS= read -r -u "$info_fd" line; do
    [[ -n $line ]] || { header_done=1; break; }
    case $line in
        'format: '*) format=${line#'format: '} ;;
        'argc: '*) argc=${line#'argc: '} ;;
    esac
done

((header_done))
[[ $format == skn-info-mk2 ]]
[[ $argc == $((${#expected[@]} + 1)) ]]

actual=()
IFS= read -r -d '' -u "$info_fd" arg
[[ $arg == cmd ]]
IFS= read -r -d '' -u "$info_fd" arg
[[ $arg == ++ ]]
for ((i = 2; i < 10#$argc; ++i)); do
    IFS= read -r -d '' -u "$info_fd" arg
    actual+=("$arg")
done

[[ ${#actual[@]} == $((${#expected[@]} - 1)) ]]
for ((i = 1; i < ${#expected[@]}; ++i)); do
    [[ ${actual[i - 1]} == "${expected[i]}" ]]
done
EOF
    assert_success
}

@test '+X expands skn options from a PATH helper' {
    fake_bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/skn-expansion-demo" <<EOF
#!/bin/bash
printf '%s\n' +R '$BATS_TEST_TMPDIR/read path' +W '$BATS_TEST_TMPDIR/write-path' +N +V FOO=bar +A prep
EOF
    chmod +x "$fake_bin/skn-expansion-demo"

    run env -u SKN_PATH_CHECK PATH="$fake_bin:$PATH" "$SKN" echo +S +Xdemo run

    assert_success
    assert_output_contains 'skn: sandboxed command: echo prep run'
    assert_output_contains 'skn: network enabled'
    assert_output_contains "--ro-bind $BATS_TEST_TMPDIR/read\\ path $BATS_TEST_TMPDIR/read\\ path"
    assert_output_contains "--bind $BATS_TEST_TMPDIR/write-path $BATS_TEST_TMPDIR/write-path"
    assert_output_contains '--setenv FOO bar'
    assert_output_not_contains '+X'
}

@test '+X expanded options appear in +0 machine info' {
    fake_bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/skn-expansion-demo" <<EOF
#!/bin/bash
printf '%s\n' +W '$BATS_TEST_TMPDIR/work' +E
EOF
    chmod +x "$fake_bin/skn-expansion-demo"

    run bash -c 'env -u SKN_PATH_CHECK PATH="$2:$PATH" "$1" cmd +0 +X demo arg | tr "\0" "\n"' _ "$SKN" "$fake_bin"

    assert_success
    assert_output_contains 'skn-info-mk2'
    assert_output_contains '+W'
    assert_output_contains "$BATS_TEST_TMPDIR/work"
    assert_output_contains '+E'
    assert_output_not_contains '+X'
}

@test '+X output paths are still checked during normal execution' {
    fake_bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/skn-expansion-demo" <<EOF
#!/bin/bash
printf '%s\n' +R '$BATS_TEST_TMPDIR/rejected'
EOF
    chmod +x "$fake_bin/skn-expansion-demo"

    run env SKN_PATH_CHECK=false PATH="$fake_bin:$PATH" "$SKN" true +X demo

    assert_status 2
    assert_output_contains 'SKN_PATH_CHECK rejected'
    assert_output_contains "$BATS_TEST_TMPDIR/rejected"
}

@test '+X rejects invalid names and reports missing helpers' {
    run env -u SKN_PATH_CHECK "$SKN" true +S +X ../demo
    assert_status 2
    assert_output_contains 'invalid expansion name'

    run env -u SKN_PATH_CHECK "$SKN" true +S +X missing
    assert_status 2
    assert_output_contains 'expansion missing failed'
    assert_output_contains 'skn-expansion-missing'
}

@test '+X runs expansion shell functions' {
    run bash -c 'skn-expansion-demo() { printf "%s\n" +N; }; export -f skn-expansion-demo; env -u SKN_PATH_CHECK PATH=/usr/bin:/bin "$1" true +S +X demo' _ "$SKN"

    assert_success
    assert_output_contains 'skn: network enabled'
    assert_output_contains '--share-net'
}

@test '+X rejects control options and command arguments from expansions' {
    fake_bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/skn-expansion-show" <<'EOF'
#!/bin/bash
printf '%s\n' +S
EOF
    chmod +x "$fake_bin/skn-expansion-show"

    run env -u SKN_PATH_CHECK PATH="$fake_bin:$PATH" "$SKN" true +S +X show
    assert_status 2
    assert_output_contains 'disallowed skn control option'
    assert_output_contains '+S'

    cat >"$fake_bin/skn-expansion-recurse" <<'EOF'
#!/bin/bash
printf '%s\n' +X other
EOF
    chmod +x "$fake_bin/skn-expansion-recurse"

    run env -u SKN_PATH_CHECK PATH="$fake_bin:$PATH" "$SKN" true +S +X recurse
    assert_status 2
    assert_output_contains 'disallowed skn control option'
    assert_output_contains '+X'

    cat >"$fake_bin/skn-expansion-arg" <<'EOF'
#!/bin/bash
printf '%s\n' +N command-arg
EOF
    chmod +x "$fake_bin/skn-expansion-arg"

    run env -u SKN_PATH_CHECK PATH="$fake_bin:$PATH" "$SKN" true +S +X arg
    assert_status 2
    assert_output_contains 'non-option argument'
    assert_output_contains 'command-arg'
}

@test '+X rejects incomplete expansion options' {
    fake_bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/skn-expansion-incomplete" <<'EOF'
#!/bin/bash
printf '%s\n' +R
EOF
    chmod +x "$fake_bin/skn-expansion-incomplete"

    run env -u SKN_PATH_CHECK PATH="$fake_bin:$PATH" "$SKN" true +S +X incomplete

    assert_status 2
    assert_output_contains 'without an argument'
    assert_output_contains '+R'
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

@test 'reserved-looking command arguments can be passed after ++' {
    run bash -c 'env -u SKN_PATH_CHECK "$1" cargo +0 ++ +Xtoolchain build | tr "\0" "\n"' _ "$SKN"

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

@test '+S shows SKN_RO_BINDS entries as optional read-only binds' {
    dir="$BATS_TEST_TMPDIR/ro-bind"
    missing="$BATS_TEST_TMPDIR/missing-ro-bind"

    run env -u SKN_PATH_CHECK SKN_RO_BINDS="$dir:$missing" "$SKN" true +S

    assert_success
    assert_output_contains "--ro-bind-try $dir $dir"
    assert_output_contains "--ro-bind-try $missing $missing"
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
