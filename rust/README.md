# Sandboxed wrappers for Cargo and rust-analyzer

Cargo dependencies can include build scripts and procedural macros.
Cargo and rust-analyzer assume that all of this build-time code is trusted.
Realistically, this is not always the case.

[rust-analyzer is particularly risky](https://rust-analyzer.github.io/book/security.html)
because it runs `cargo` autonomously in the background:
merely opening a workspace in an editor can end up executing
build-time code from the workspace or its dependencies.

The scripts in this directory reduce that exposure while keeping common Rust workflows usable.
They behave roughly like `cargo` and `rust-analyzer`,
except that they run under [Sandkasten (`skn`)](../README.md)
and add suitable `skn` options automatically
based on the command line and the directory from which they are run:

- `skn-cargo` runs Cargo in a mostly automatic sandbox,
  with network access subject to command-specific restrictions.
- `skn-rust-analyzer` runs rust-analyzer in a sandbox,
  with network access disabled.

The wrappers apply two complementary policies automatically:

- **Minimize filesystem exposure.**
  They grant each command access only to the workspace and tool state it needs.
- **Separate network access from code execution.**
  Commands whose purpose is dependency resolution or retrieval may get network access.
  Common build-like commands are split into a networked prefetch phase
  followed by the requested command in an offline sandbox.

## Typical workflow

Build, test, and run normally:
```sh
skn-cargo build
skn-cargo test
skn-cargo run
```

When dependencies are missing or the lockfile needs updating,
`skn-cargo` first runs a network-enabled `cargo fetch` phase.
If that succeeds, it runs the requested command offline.

Additional `skn` grants can be passed before the wrapped tool arguments.
For example:
```sh
skn-cargo +R ../local-dependency build
skn-cargo +T. test
```

Explicit `+N` opts out of this split and runs one networked Cargo invocation:
```sh
skn-cargo +N build    # Build scripts and proc macros may use the network.
```

Use `+S` to inspect the resulting sandbox setup:
```sh
skn-cargo +S build
skn-rust-analyzer +S
```

The general `skn` option syntax is documented in the [usage guide](../USAGE.md#invoking-skn).

## Setup

### Requirements

The wrappers require `skn` in `PATH`.
`skn-cargo` needs Cargo.
`skn-rust-analyzer` needs both Cargo and rust-analyzer.
The corresponding real tools must be either in `PATH`
or set explicitly using `SKN_REAL_CARGO` and `SKN_REAL_RUST_ANALYZER`.

Normal execution inherits `skn`’s path-check requirement;
see the usage guide’s [setup section](../USAGE.md#setup).

### Simple setup

The least surprising setup is to install the wrappers under their own names:
```sh
mkdir -p ~/.local/bin
install rust/skn-cargo ~/.local/bin/skn-cargo
install rust/skn-rust-analyzer ~/.local/bin/skn-rust-analyzer
```

Then use aliases or editor-specific configuration where desired:
```sh
alias cargo=skn-cargo
```

This keeps the real Cargo and rust-analyzer commands available
under their normal installation paths,
while making the sandboxed wrappers explicit.

### Strict setup

A more robust setup is to keep Cargo’s bin directory out of the regular `PATH`
and expose it only through launcher scripts that ensure sandboxing.
This avoids accidentally running custom Cargo subcommands such as `cargo-upgrade`
directly and unsandboxed.
Shell aliases are also often ignored by editors and IDEs
when they launch `cargo` or `rust-analyzer`.

Put launcher scripts in a directory that is in `PATH`, for example `~/bin`.
Do not put these launchers in Cargo home,
and do not overwrite rustup’s real proxies in `~/.cargo/bin` or `$CARGO_HOME/bin`.

A strict `cargo` launcher can look like this:
```sh
#!/bin/sh
# Run skn-cargo with Cargo’s bin directory available only inside the sandbox.

cargo_home=${CARGO_HOME:-${HOME:?HOME is not set}/.cargo}
cargo_bin="$cargo_home/bin"

case ":$PATH:" in
    *:"$cargo_bin":*)
        echo "error: $cargo_bin is already in PATH" >&2
        exit 2
        ;;
esac

export SKN_REAL_CARGO="$cargo_bin/cargo"

exec skn-cargo +V "PATH=$cargo_bin:$PATH" "$@"
```

A strict `rust-analyzer` launcher should name the real tools explicitly:
```sh
#!/bin/sh
# Run rust-analyzer sandboxed.

cargo_home=${CARGO_HOME:-${HOME:?HOME is not set}/.cargo}
cargo_bin="$cargo_home/bin"

export SKN_REAL_CARGO="$cargo_bin/cargo"
export SKN_REAL_RUST_ANALYZER="$cargo_bin/rust-analyzer"
exec skn-rust-analyzer "$@"
```

If Cargo or rust-analyzer comes from a system package manager or another installation,
set `SKN_REAL_CARGO` and `SKN_REAL_RUST_ANALYZER` to those real paths instead.

## Sandbox details

Automatic grants are visible with `+S` and are still checked by `SKN_PATH_CHECK`.

`skn-cargo` gives dependency-management subcommands such as `fetch` and `update`
network access automatically.
Common build-like subcommands such as `build`, `check`, `clippy`, `doc`,
`test`, `bench`, and `run` automatically prefetch dependencies with network
access, then run the requested command offline.
Other identifiable Cargo subcommands run offline by default,
but may allow explicit `+N` when `skn-cargo` accepts the command shape.
The exact policy lists live near the top of [`skn-cargo`](skn-cargo).

The prefetch phase uses `cargo fetch` conservatively.
Cargo does not currently provide a stable command for “fetch exactly what this
particular build would fetch without executing build code”, so the prefetch may
download more than the following command strictly needs.
The important property is that build scripts, proc macros, tests,
and project subprocesses run in the offline phase.

Cargo’s own offline controls suppress automatic prefetch:
```sh
skn-cargo build --offline
skn-cargo build --frozen
CARGO_NET_OFFLINE=true skn-cargo build
```

`skn-cargo +N ...` is the relaxed escape hatch.
It runs the requested Cargo invocation once with network enabled,
so build scripts, proc macros, tests, and subprocesses may use the network.
The filesystem sandbox still applies.

`skn-rust-analyzer` follows the same separation in the conservative direction:
it refuses network access.
If dependencies are missing, fetch or build them first with `skn-cargo`,
then run rust-analyzer offline.
Given current [rust-analyzer design](https://github.com/rust-lang/rust-analyzer/issues/22118),
rust-analyzer and its Cargo subprocesses need writable workspace state.

`skn-cargo` grants the detected Cargo workspace writable access.
Outside a workspace, it does not bind the current directory for general commands.
Project-creation commands get narrower grants:
`cargo new PATH` grants the parent directory,
and `cargo init` grants the target directory when it already exists,
or its parent otherwise.

`skn-cargo` refuses the ordinary networked form of `cargo install CRATE`
without `+N`, because it downloads code and builds it in one step.
If you intentionally want that less restrictive workflow,
use `skn-cargo +N install CRATE`.

`skn-rust-analyzer` runs rust-analyzer itself inside the sandbox.
Cargo, rustc, build scripts, proc macros, tests,
and other subprocesses launched by rust-analyzer inherit that sandbox.
It grants the detected Cargo workspace writable access;
if no workspace is found from the current directory,
it binds the current directory read-only so rust-analyzer can still start.
Both wrappers bind Cargo home writable and rustup home read-only when those directories exist.

The Rust wrappers pass `+E` to `skn` for compatibility with Rust toolchains,
Cargo configuration, and project-specific build setups.
Build scripts, proc macros, tests,
and related subprocesses may therefore be able to read environment variables containing secrets.
A writable Cargo home may expose registry credentials
and allow persistent changes to Cargo configuration and cache state.
If Cargo registry credentials are needed,
prefer [global credential providers](https://doc.rust-lang.org/cargo/reference/registry-authentication.html)
over storing tokens directly in Cargo home.
