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

Except in `+S` show mode or `+I` info mode, these wrappers inherit `skn`’s requirement that `SKN_PATH_CHECK` be set;
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
Cargo arguments are otherwise passed through unchanged, except that leading arguments in `skn`’s current or reserved uppercase `+` option namespace must be passed after `--`.

With `+N`, `skn-cargo` only allows `fetch`, `update`, `add`,
`upgrade`, `generate-lockfile`, and `search`.
Other subcommands, including `build`, `check`, `test`, `run`,
`doc`, `install`, custom subcommands other than `upgrade`,
and the no-subcommand default, are refused because they may execute build scripts,
proc macros, tests, or other project code with network access.

For compatibility with toolchains and project-specific Cargo configuration,
the Rust wrappers pass `+P` to `skn` and therefore preserve the caller environment by default.
Be aware that untrusted build scripts, proc macros, tests,
and related subprocesses may be able to read environment variables containing secrets.
They also bind Cargo home writable when it exists, which may expose Cargo credentials or allow persistent changes to Cargo configuration/cache state.
This bind, and the read-only rustup home bind when present,
are passed as explicit `skn` options so they are visible with `+S` and checked by `skn`.
If you need Cargo registry credentials, prefer configuring Cargo to retrieve tokens on demand from an external credential provider instead of storing tokens directly in Cargo home.
For example, Cargo supports `registry.global-credential-providers`,
which can invoke a password manager or other helper to supply tokens when needed.

With `+N`, network access is enabled and the wrapper does not set `CARGO_NET_OFFLINE`:

```sh
skn-cargo +N update
skn-cargo +N add serde
skn-cargo +N search serde
```

Because the wrappers preserve the caller environment, an already-inherited `CARGO_NET_OFFLINE` value still applies even with `+N`.
If you intentionally need a different networked Cargo operation,
bypass this policy explicitly by invoking `skn` with the real Cargo command,
for example `skn "$SKN_REAL_CARGO" +N ...` in strict PATH setups.

`cargo install` is intentionally not allowed with `+N`, because it downloads and builds code in one step.
When source is available, use a two-stage local-source workflow instead:
fetch or update dependencies with network access, then install from the local path offline,
for example `skn-cargo +N fetch --locked` followed by `skn-cargo install --path . --locked`.
For crates already present in Cargo’s cache, `skn-cargo install --offline --locked CRATE` may also work.

Use `+S` to show the generated sandbox command without running Cargo:

```sh
skn-cargo +S build
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
Unlike `skn` itself, `skn-rust-analyzer` refuses `+N`, because rust-analyzer can execute project code through Cargo subprocesses.
Fetch dependencies separately, then run rust-analyzer offline:

```sh
skn-cargo +N fetch
skn-rust-analyzer
```

Use `+S` to show the generated sandbox command without starting rust-analyzer:

```sh
skn-rust-analyzer +S
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

### Strict PATH mode

For untrusted-work environments, you may choose to shadow Cargo and rust-analyzer from an earlier `PATH` directory so editors and IDEs that ignore shell aliases still find the wrappers:

```text
~/bin/skn-strict/cargo          -> skn-cargo
~/bin/skn-strict/rust-analyzer  -> skn-rust-analyzer
```

Do not overwrite rustup’s real proxies in `$CARGO_HOME/bin`;
put symlinks or small launcher scripts in an earlier directory instead.
In this mode, set explicit real-tool commands so the wrappers do not recurse back into themselves:

```sh
export SKN_REAL_CARGO="$HOME/.cargo/bin/cargo"
export SKN_REAL_RUST_ANALYZER="$HOME/.cargo/bin/rust-analyzer"
PATH="$HOME/bin/skn-strict:$PATH" editor
```

Strict PATH mode requires these explicit real-tool settings.
The wrappers use simple recursion guards to turn symlink or launcher-script loops into clear errors instead of hangs.
For example, `cargo -> skn-cargo` and `cargo` scripts that run `exec skn-cargo "$@"` are rejected once they re-enter the wrapper.

`skn-cargo` runs `${SKN_REAL_CARGO:-cargo}`.
If `SKN_REAL_CARGO` is set, it also sets `CARGO` to that value inside the sandbox;
otherwise it does not override `CARGO` and any inherited value remains visible,
though Cargo normally sets `CARGO` for its own subprocesses.
`skn-rust-analyzer` runs `${SKN_REAL_RUST_ANALYZER:-rust-analyzer}` and always sets `CARGO=${SKN_REAL_CARGO:-cargo}` inside the sandbox,
because rust-analyzer uses `CARGO` to find Cargo.
The `SKN_REAL_*` values are used literally as command names or paths;
absolute paths are recommended in strict PATH setups.

If you use launcher scripts to add local sandbox grants, put the real-tool override in the launcher, for example:

```sh
#!/bin/sh
exec env SKN_REAL_CARGO="$HOME/.cargo/bin/cargo" \
    skn-cargo +W "$HOME/.cargo-symlink-target" "$@"
```

Strict PATH mode is useful for avoiding accidental vanilla Cargo use,
but it is not perfectly transparent.
Some tools use absolute paths, `$CARGO`, rustup directly, or editor-specific tool configuration.
The named-wrapper setup remains the least surprising default.
