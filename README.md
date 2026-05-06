# Sandkasten: quick-and-proper Bubblewrap sandboxes

Sandkasten (`skn`) is a shell-friendly frontend to
[bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`).
It runs commands in a strict sandbox that can be selectively relaxed.
For example:
```sh
skn untrusted +R. +W artifacts -o artifacts/result
```

This invocation runs `untrusted` with:
- read-only access to the current directory (in addition to essential system mounts such as `/usr`),
- write access to `artifacts`,
- no network access.

`skn` options start with `+`, making them easy to mix with the wrapped command’s own arguments.
In the example above, `+R.` and `+W artifacts` are handled by `skn`, while `-o artifacts/result` is passed to `untrusted`.

This convention works well for aliases and wrappers:

```sh
alias untrusted='skn /not/in/path/untrusted'
```

The alias remains usable like the original command,
while sandbox controls can still be added when needed.
To run `untrusted arg` with network access, use:
```sh
untrusted +N arg
```

`+S` prints the `bwrap` command that would be run,
allowing sandbox inspection before use.

## Overview

By default, the sandbox has:

- no network access
- a private `/tmp`
- a mostly cleared environment
- only minimal read-only access to host system/runtime files
- no access to the rest of the host filesystem unless explicitly configured

The suite also includes integrations for common tools:

- [`rust/skn-cargo`](rust/README.md) runs Cargo in the sandbox
- [`rust/skn-rust-analyzer`](rust/README.md) runs rust-analyzer in the sandbox

The Rust wrappers are meant to make a common workflow convenient:
fetch dependencies with network access, then build, test, and analyze offline.

## Requirements

- Bash
- bubblewrap (`bwrap`)
- common Unix tools such as `realpath` and `dirname`

Additional integrations have their own requirements:

- [Rust wrappers](rust/README.md)

## Quick examples

```sh
skn make
skn cargo +P +W . -- build
skn make +T .
skn curl +N -- https://example.com/
```

The launch current directory is not exposed automatically.
Use `+R`, `+W`, or `+T` when the command needs access to the current directory or another project path.

## How invocation works

```sh
skn COMMAND [skn-options] [--] [COMMAND-args...]
```

The command to execute comes before `skn` options.
This unusual ordering is intentional:
it makes shell aliases and small wrappers convenient while keeping sandbox controls in their own `+` option namespace.

For example:

```sh
alias foo='skn foo'
```

Then `foo +W ../data run` expands to `skn foo +W ../data run`,
so `skn` can consume `+W ../data` before passing `run` to `foo`.

`skn` parses only the initial `+` option prefix after `COMMAND`.
If the wrapped command needs an argument that looks like a `skn` option,
pass it after another command argument or use `--`.
Unrecognized `+` options with uppercase names are reserved for future `skn` options while this prefix is being parsed.

## Options summary

This is the user-facing interface at a glance.
Run `skn --help` for the exact command reference.

```text
+R PATH         bind PATH read-only into the sandbox
+W PATH         bind PATH writable into the sandbox
+T PATH         bind directory PATH transient-writable; writes are discarded
+E VAR=VALUE    set environment VAR to VALUE inside the sandbox
+A ARG          prepend ARG to COMMAND arguments
+N              enable network access
+P              preserve caller environment instead of clearing it
+S              show the sandbox plan after parsing, then exit
+I              show only the parsed skn info header, then exit
--              stop parsing skn options
```

Bind options take effect in the order they are given.
For example, `+T . +W ./out` makes the current directory transient-writable,
then makes `./out` persistently writable on top of it;
reversing the options makes `./out` part of the transient overlay.

`+S` is useful for inspecting the sandbox plan without running the command.
It prints the sandboxed command, network and environment mode,
an equivalent `skn` invocation, and the resulting `bwrap` invocation.
To inspect the sandbox manually, copy the equivalent invocation,
replace the sandboxed command with `bash`, and adjust or remove command arguments after `--`.
`+I` is intended for wrappers that only need the parsed `skn:` metadata header.
Neither mode runs path checks or validates bind paths.

## Sandbox model

`skn` tries to expose enough of the host system read-only for ordinary system commands to run,
while avoiding access to unrelated user data.

In broad strokes:

- system/runtime files are bound read-only
- a small amount of system configuration is bound read-only when useful
- DNS and common TLS certificate configuration are added only with `+N`
- user/project files are not visible unless explicitly bound with `+R`, `+W`, `+T`,
  or trusted configuration such as `SKN_RO_BINDS`
- the synthetic sandbox filesystem is remounted read-only after setup
- persistent writes are limited to explicit `+W` binds
- non-persistent writes are limited to the private `/tmp` and explicit `+T` overlays

The exact built-in bind list is intentionally an implementation detail;
inspect `./skn` or use `+S` when you need to see the current plan.

By default, the environment is mostly cleared.
Use `+E` to pass specific values or `+P` to preserve the caller environment.
Be careful with `+P`:
environment variables often contain secrets or host-specific paths.

Network access is disabled by default.
Use `+N` to enable it.
Host-specific name overrides such as `/etc/hosts` are not exposed automatically;
bind trusted configuration explicitly if a command needs it.

## Path checks

Except in `+S` show mode or `+I` info mode, `skn` requires `SKN_PATH_CHECK` to be set.
It names a command used to validate paths before they are exposed through `+R`, `+W`, or `+T`.

The command is executed directly, without shell evaluation,
with the checked path as its only argument.
For example:

```sh
export SKN_PATH_CHECK="$HOME/bin/is-ok-for-untrusted"
```

For testing, you can disable path checking with:

```sh
export SKN_PATH_CHECK=true
```

A path-check command is deliberately policy-specific.
A typical policy might allow project directories under `~/src` and temporary directories under `/tmp`,
but reject `$HOME` itself.
The checker is responsible for applying the full path policy,
including any desired canonicalization or symlink dereferencing.

## Transient writable overlays

`+T PATH` exposes an existing directory as a transient writable overlay.
Initial reads come from the host directory, but writes, deletes,
and replacements are stored in temporary sandbox storage and discarded when the sandbox exits.

This is useful for tools that insist on writing to a cache or source tree even when you do not want host data modified.

`+T` is not a snapshot:
concurrent host-side changes to the underlying directory are not hidden or made coherent,
and reads can still expose secrets from that directory.
Writes consume temporary sandbox storage.
It also depends on `bubblewrap` and kernel overlayfs support,
and may be unavailable with setuid bubblewrap.

## Environment configuration

Additional read-only binds can be configured with a colon-separated environment variable:

```sh
export SKN_RO_BINDS="$HOME/.rustup:$HOME/.cargo/bin"
```

`SKN_RO_BINDS` paths are treated as trusted user configuration and are not checked by `SKN_PATH_CHECK`.
Use this for stable setup, not for per-command access grants;
use `+R` for those.

## Threat model and non-goals

`skn` is intended to reduce accidental exposure when running untrusted project code,
build scripts, proc macros, tests, language servers, and similar tools.
It is especially useful for preventing easy access to unrelated files in your home directory and for disabling network access by default.

It is not a complete security solution.
In particular:

- it relies on the kernel and bubblewrap behaving correctly
- it does not defend against kernel vulnerabilities or sandbox escapes
- it does not make malicious code safe to run with secrets deliberately bound into the sandbox
- `+P` preserves the caller environment, which may expose secrets through environment variables
- persistent writable bind mounts allow sandboxed code to modify those paths

Use it as a pragmatic containment layer, not as a guarantee that hostile code is harmless.

## Installing

Install `skn` under its own command name:

```text
skn
```

For integration-specific installation and usage notes, see the [Rust wrappers](rust/README.md) README.

## Testing

Run the test suite with:

```sh
./tests/run
```

See [`tests/README.md`](tests/README.md) for details.
