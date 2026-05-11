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
skn-cargo fetch
```

Then build offline:

```sh
skn-cargo build
```

`skn-cargo` enables network access automatically for known dependency-management subcommands,
such as `fetch`, because these commands are not expected to execute project code.
It refuses explicit `+N` for known build-like or code-executing subcommands,
such as `build`, because they may execute build scripts, proc macros,
tests, or other project code with network access.
Other identifiable subcommands, including custom subcommands such as `cargo-upgrade`,
run offline by default with `CARGO_NET_OFFLINE=true`, but may use explicit `+N`.
The exact policy lists live in `net_auto_subcommands` and `net_deny_subcommands` near the top of `rust/skn-cargo`.
The no-subcommand default and invocations whose subcommand cannot be safely identified also run offline by default and refuse explicit `+N`.
Cargo arguments are otherwise passed through unchanged, except that leading arguments in `skn`’s current or reserved uppercase `+` option namespace must be passed after `--`.

For compatibility with toolchains and project-specific Cargo configuration,
the Rust wrappers pass `+E` to `skn` and therefore preserve the caller environment by default.
Be aware that untrusted build scripts, proc macros, tests,
and related subprocesses may be able to read environment variables containing secrets.
They also bind Cargo home writable when it exists, which may expose Cargo credentials or allow persistent changes to Cargo configuration/cache state.
This bind, and the read-only rustup home bind when present,
are passed as explicit `skn` options so they are visible with `+S` and checked by `skn`.
If you need Cargo registry credentials, prefer configuring Cargo to retrieve tokens on demand from an external credential provider instead of storing tokens directly in Cargo home.
For example, Cargo supports `registry.global-credential-providers`,
which can invoke a password manager or other helper to supply tokens when needed.

For auto-networked dependency-management commands, network access is enabled and the wrapper does not set `CARGO_NET_OFFLINE`:

```sh
skn-cargo fetch
```

Because the wrappers preserve the caller environment, an already-inherited `CARGO_NET_OFFLINE` value still applies even when `skn-cargo` enables network access.
If you intentionally need network for a subcommand that is on neither policy list,
pass `+N` explicitly, for example `skn-cargo +N upgrade`.
If you intentionally need to bypass the policy for a denied Cargo operation,
invoke `skn` with the real Cargo command, for example `skn "$SKN_REAL_CARGO" +N ...` in strict PATH setups.

`cargo install` is intentionally not allowed with `+N`, because it downloads and builds code in one step.
When source is available, use a two-stage local-source workflow instead:
fetch or update dependencies with network access, then install from the local path offline,
for example `skn-cargo fetch --locked` followed by `skn-cargo install --path . --locked`.
For crates already present in Cargo’s cache, `skn-cargo install --offline --locked CRATE` may also work.

Use `+S` to show the generated sandbox command without running Cargo:

```sh
skn-cargo +S build
```

When `skn-cargo` detects a Cargo workspace, it binds that workspace writable.
Cargo’s top-level `-C DIR` option is honored for this workspace detection.
Outside a detected workspace, it does not implicitly bind the current directory for general commands.
For Cargo project creation commands, it grants only the location needed for the new package:
`cargo new PATH` binds the parent directory writable, and `cargo init [PATH]` binds the target directory when it already exists or the parent otherwise.
These automatic grants are still checked by `skn` like explicit `+W` options.

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

Unlike `skn-cargo` dependency-management commands, `skn-rust-analyzer` disables network by default and sets `CARGO_NET_OFFLINE=true`.
Like `skn` itself, it accepts `+N` syntactically, but then refuses it because rust-analyzer can execute project code through Cargo subprocesses.
Fetch dependencies separately, then run rust-analyzer offline:

```sh
skn-cargo fetch
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

Then use an alias or editor-specific configuration where desired:

```sh
alias cargo=skn-cargo
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
`skn-cargo` uses a bounded recursion-depth guard to let ordinary recursive Cargo calls from custom subcommands work while still turning wrapper loops into clear errors instead of hangs.
The limit is configurable for unusual workflows.

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
