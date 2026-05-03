# skn Rust wrappers

This directory contains Rust tool integrations for [`skn`](../README.md):

- `skn-cargo` runs Cargo in the sandbox.
- `skn-rust-analyzer` runs rust-analyzer in the sandbox.

The wrappers are meant to make a common workflow convenient:
fetch dependencies with network access, then build, test, and analyze offline.

## Requirements

- [`skn`](../README.md)
- Cargo
- rust-analyzer, for `skn-rust-analyzer`

These wrappers inherit `skn`’s requirement that `SKN_PATH_CHECK` be set;
see [`skn` path checks](../README.md#path-checks).

## Fetch with network, build offline

Use `skn-cargo` directly or through a shell alias:

```sh
alias cargo=skn-cargo
```

Fetch dependencies with network access:

```sh
skn-cargo +N fetch
```

Then build offline:

```sh
skn-cargo build
```

Without `+N`, `skn-cargo` sets `CARGO_NET_OFFLINE=true` inside the sandbox.
Cargo arguments are otherwise passed through unchanged.

For compatibility with toolchains and project-specific Cargo configuration,
the Rust wrappers pass `+P` to `skn` and therefore preserve the caller environment by default.
Be aware that untrusted build scripts, proc macros, tests,
and related subprocesses may be able to read environment variables containing secrets.
They also bind Cargo home writable when it exists, which may expose Cargo credentials or allow persistent changes to Cargo configuration/cache state.
If you need Cargo registry credentials, prefer configuring Cargo to retrieve tokens on demand from an external credential provider instead of storing tokens directly in Cargo home.
For example, Cargo supports `registry.global-credential-providers`,
which can invoke a password manager or other helper to supply tokens when needed.

With `+N`, network access is enabled and `CARGO_NET_OFFLINE` is not set:

```sh
skn-cargo +N update
skn-cargo +N install ripgrep
```

When `skn-cargo` detects a Cargo workspace, it binds that workspace writable.
Outside a detected workspace, it does not implicitly bind the current directory,
so commands such as `cargo new foo` fail unless you explicitly grant writable access,
for example with `skn-cargo +W. new foo`.

Use `+T` when a directory should appear writable but host changes should be discarded.
For example, `skn-cargo +T ~/.cargo build` lets Cargo and subprocesses write to a transient Cargo home overlay for that run,
and `skn-cargo +T . test` lets tools write in the project tree without keeping their changes.
`+T` still allows reads from the underlying directory, so it does not hide secrets.

## rust-analyzer

`skn-rust-analyzer` runs rust-analyzer itself inside the sandbox.
Cargo, rustc, build scripts, proc macros, tests, and other subprocesses launched by rust-analyzer inherit that sandbox.

This is preferable to trying to force every Cargo subprocess through a Cargo wrapper,
because rust-analyzer uses several Cargo lookup modes depending on the operation and discovered toolchain.

Typical use:

```sh
skn-rust-analyzer
```

As with `skn-cargo`, network is disabled by default and `CARGO_NET_OFFLINE=true` is set.
Use `+N` if rust-analyzer should have network access:

```sh
skn-rust-analyzer +N
```

The detected Cargo workspace is bound writable because rust-analyzer and Cargo need to write target files and other workspace-local state.
If no Cargo workspace is detected from the current directory,
the current directory is bound read-only so rust-analyzer can still start with its usual no-workspace behavior without giving write access to an arbitrary launch directory.
In both cases, the path is checked by `skn`.

## Installing and using wrappers

The least surprising setup is to install the wrappers under their own command names:

```text
skn-cargo          # from rust/skn-cargo
skn-rust-analyzer  # from rust/skn-rust-analyzer
```

Then use aliases or editor-specific configuration where desired:

```sh
alias cargo=skn-cargo
alias cargo-fetch='skn-cargo +N fetch'
alias cargo-update='skn-cargo +N update'
```

Avoid installing wrappers in a way that shadows the real `cargo` or `rust-analyzer` unless you are prepared to handle transparency issues.
IDEs and tools may ignore shell aliases, use `$CARGO`, prefer `$CARGO_HOME/bin/cargo`,
or otherwise resolve tools differently from an interactive shell.
