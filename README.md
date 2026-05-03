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

The default sandbox has:

- no network access
- a private `/tmp`
- a mostly cleared environment
- read-only access to `/usr` and selected `/etc` files
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
- writable bind mounts allow sandboxed code to modify those paths

Use it as a pragmatic containment layer, not as a guarantee that hostile code is harmless.

## `skn` usage

```sh
skn COMMAND [skn-options] [--] [COMMAND-args...]
```

Examples:

```sh
skn make
skn cargo +P +W . -- build
skn curl +N -- https://example.com/
```

The command to execute comes before `skn` options.
This unusual ordering is intentional:
it makes shell aliases and small wrappers convenient while keeping sandbox controls close to the command they affect.
`skn` options use a leading `+` to put them in a separate namespace from ordinary command options and to signal that they add something to the sandbox,
such as network access, a bind, or an environment variable.

For example:

```sh
alias foo='skn foo'
```

Then `foo +W ../data run` expands to `skn foo +W ../data run`,
so `skn` can consume `+W ../data` before passing the remaining arguments to `foo`.

### Options

```text
+R PATH         bind PATH read-only into the sandbox
+W PATH         bind PATH writable into the sandbox
+E VAR=VALUE    set environment VAR to VALUE inside the sandbox
+A ARG          prepend ARG to COMMAND arguments
+N              enable network access
+P              preserve caller environment instead of clearing it
--              stop parsing skn options
```

By default, network access is disabled.
Use `+N` to enable it.

By default, the environment is mostly cleared.
Use `+E` to pass specific values or `+P` to preserve the caller environment.

## Path checks

`skn` requires `SKN_PATH_CHECK` to be set.
It names a command used to validate paths before they are exposed through `+R` or `+W`.

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
including any desired canonicalization or symlink dereferencing;
`skn` deliberately does not hardcode those policy decisions.

## Environment-configured binds

Additional persistent binds can be configured with colon-separated environment variables:

```sh
export SKN_RO_BINDS="$HOME/.rustup:$HOME/.cargo/bin"
export SKN_BINDS="$HOME/.cargo"
```

- `SKN_RO_BINDS` paths are bound read-only.
- `SKN_BINDS` paths are bound writable.

Paths from these variables are not checked by `SKN_PATH_CHECK`;
they are treated as trusted configuration chosen by the user.

## Installing

Install `skn` under its own command name:

```text
skn
```

For integration-specific installation and usage notes, see the [Rust wrappers](rust/README.md) README.

## Notes

- `skn` intentionally has a small interface.
- `skn` options use uppercase letters with a leading `+` so they are less likely to collide with wrapped command options.
- `+P` is useful for compatibility, but it may expose secrets from the caller’s environment.
- Network access is opt-in with `+N`.
- The synthetic sandbox filesystem is remounted read-only after setup. Writable access is limited to `/tmp` and explicit writable binds such as `+W` and `SKN_BINDS`; writes elsewhere should fail rather than appear to succeed transiently.
- The launch current directory is not bound or selected explicitly by `skn`. If it is unavailable inside the sandbox, `bwrap` handles this using its documented fallback behavior (`$HOME` if available, otherwise `/`). Use `+R` or `+W` when the command needs access to the current directory or another checked path.
