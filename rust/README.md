# Sandboxed wrappers for Cargo and rust-analyzer

Cargo dependencies can include build scripts and procedural macros.
Cargo and rust-analyzer assume that all of this build-time code is trusted.
Realistically, this is not always the case.

[rust-analyzer is particularly risky](https://rust-analyzer.github.io/book/security.html)
because it runs `cargo` autonomously in the background:
merely opening a workspace in an editor can end up executing
build-time code from the workspace or its dependencies.

The scripts in this directory reduce that exposure while keeping common Rust workflows usable.
They aim to behave like `cargo` and `rust-analyzer`,
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
  Cargo subcommands whose purpose is dependency resolution or retrieval may get network access.
  Common build-like subcommands (like `build` or `run`) are split into a networked prefetch phase
  followed by the requested command in an offline sandbox.

## Quick start

Assuming `skn` itself is installed
and normal `SKN_PATH_CHECK` setup is in place,
install the wrappers and their shared helper from this directory:
```sh
mkdir -p ~/.local/bin
install skn-* ~/.local/bin/
```

This installs `skn-cargo`, `skn-rust-analyzer`,
and `skn-expansion-cargo`, the helper used internally by both wrappers.
The install directory must be in `PATH`.
See the main [installation and setup instructions](../README.md#installation-and-basic-setup)
for basic `skn` setup.

Build, test, and run normally:
```sh
skn-cargo build
skn-cargo test
skn-cargo run
```

When dependencies are missing or the lockfile needs updating,
`skn-cargo` first runs a network-enabled `cargo fetch` phase.
If that succeeds, it runs the requested command offline,
so build scripts, proc macros, tests, and project subprocesses
run without network access.

Use `+S` to inspect the resulting sandbox setup without running the command:
```sh
skn-cargo +S build
skn-rust-analyzer +S
```

To make interactive shell use sandboxed by default,
you can alias Cargo:
```sh
alias cargo=skn-cargo
```

Editors and IDEs often ignore shell aliases;
for that case, see [Strict setup](#strict-setup).

## What the wrappers do

| Use | Behavior |
| --- | --- |
| `skn-cargo build`, `check`, `test`, `run`, … | Prefetch dependencies if needed, then run the requested command offline. |
| `skn-cargo fetch`, `update`, `add`, … | Allow network access automatically for dependency resolution or retrieval. |
| `skn-cargo +N ...` | Run one explicitly networked Cargo invocation. Build-time code may use the network. |
| `skn-rust-analyzer` | Run rust-analyzer and its Cargo subprocesses offline. `+N` is refused. |

The exact command policy is intentionally kept in the wrapper source.
Use `+S` to inspect a particular invocation.

## Common adjustments

Additional `skn` grants can be passed before the wrapped tool arguments.
For example:
```sh
skn-cargo +R ../local-dependency build
skn-cargo +T. test
```

Cargo’s own offline controls suppress automatic prefetch:
```sh
skn-cargo build --offline
skn-cargo build --frozen
CARGO_NET_OFFLINE=true skn-cargo build
```

Explicit `+N` opts out of the split fetch-then-offline workflow
and runs the requested Cargo command once with network access:
```sh
skn-cargo +N build
```

This keeps the filesystem sandbox,
but build scripts, proc macros, tests, and subprocesses may use the network.

If rust-analyzer reports missing dependencies,
fetch or build them first with `skn-cargo`,
then run rust-analyzer offline.

For other tools that should use the same Cargo workspace/cache filesystem grants,
use the same expansion helper that the wrappers use internally:
```sh
skn COMMAND +X cargo
```

This is useful for coding agents, linters, or project tools that need
workspace and Cargo-home access but have their own command behavior.
This expansion only adds filesystem, toolchain, and environment grants;
it does not add network policy.
The general `skn` option syntax is documented in the [usage guide](../USAGE.md#invoking-skn).

For simplicity and robustness, `skn-cargo` does not try to infer write grants
for administrative Cargo commands.
For example, `cargo login` needs explicit write access to Cargo configuration
or credential state, such as `+W ~/.cargo`.

`cargo install` follows the same general policy.
It runs offline by default;
`+N` opts into one networked invocation.
For a one-off install in a typical rustup setup,
give `cargo install` explicit write access:
```sh
skn-cargo +N +W ~/.cargo install CRATE --locked
```

Note that while the filesystem sandbox is in place,
the above does not split the operation into a networked fetch and offline build.
To `cargo install` a crate while maintaining the split,
obtain or update the source tree separately with network access,
fetch dependencies, then install from that local path offline:
```sh
cd PATH-TO-SOURCE
skn-cargo fetch --locked
skn-cargo +W ~/.cargo install --path . --locked
```
This keeps the build/install step offline,
but source acquisition is a separate manual step.

## Setup details

The wrappers require `skn` and `skn-expansion-cargo` in `PATH`.
`skn-expansion-cargo` and `skn-cargo` need Cargo.
`skn-rust-analyzer` needs both Cargo and rust-analyzer.
The corresponding real tools must be either in `PATH`
or set explicitly using the environment variables `SKN_REAL_CARGO` and `SKN_REAL_RUST_ANALYZER`.

Normal execution inherits `skn`’s path-check requirement;
see the `skn` usage guide’s [setup section](../USAGE.md#installation-and-setup).

### Strict setup

The least surprising setup is to install the wrappers under their own names,
as shown above.
A stricter setup keeps Cargo’s bin directory out of the regular `PATH`
and exposes it only through launcher scripts that ensure sandboxing.
This avoids accidentally running custom Cargo subcommands such as `cargo-upgrade`
directly and unsandboxed,
and works for editors and IDEs that ignore shell aliases.

Put launcher scripts in a directory that is in `PATH`, for example `~/bin`.
Do not put these launchers in Cargo home,
and do not overwrite rustup’s real proxies in `~/.cargo/bin` or `$CARGO_HOME/bin`.
The launchers assume that `skn`, `skn-cargo`, `skn-rust-analyzer`,
and `skn-expansion-cargo` are available in `PATH`.

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

## Sandbox reference

Automatic grants are visible with `+S` and are still checked by `SKN_PATH_CHECK`.

### Filesystem grants

The wrappers use `skn-expansion-cargo` for their Cargo workspace,
Cargo-home, and rustup-home filesystem grants.
You can inspect those grants directly with
```sh
skn-expansion-cargo
skn-expansion-cargo rust-analyzer
```

In a Cargo workspace, the default `cargo` profile grants
writable access to the workspace root when run there;
from a workspace member, it grants the workspace read-only,
the current directory writable,
and the workspace `target` directory writable.

The `rust-analyzer` profile grants the workspace read-only
and the workspace `target` directory writable.
It does not grant source directories writable.

Outside a Cargo workspace, the expansion emits no project grants.
Cargo-home and rustup-home grants are added when the corresponding directories exist:
Cargo home read-only,
Cargo’s `registry` and `git` cache subdirectories writable,
and rustup home read-only.

For `skn-cargo`, the expansion runs from Cargo’s effective working directory,
including any top-level `cargo -C DIR` option.
Project-creation commands add creation-specific grants:
`cargo new PATH` grants the parent directory,
and `cargo init` grants the target directory when it already exists,
or its parent otherwise.

### Network policy

`skn-cargo` gives dependency-management subcommands network access automatically.
Common build-like subcommands prefetch dependencies with network access,
then run the requested command offline.
Other identifiable Cargo subcommands run offline by default,
but may allow explicit `+N` when `skn-cargo` accepts the command shape.
The exact policy lists live near the top of [`skn-cargo`](skn-cargo).

The prefetch phase uses `cargo fetch` conservatively.
It may download more than the following command strictly needs.
The important property is that build scripts, proc macros, tests,
and project subprocesses run in the offline phase.

`skn-rust-analyzer` refuses network access.
It uses the `cargo:rust-analyzer` expansion profile,
so rust-analyzer can read the workspace and write Cargo build/cache state
without receiving write access to source directories.
Given current [rust-analyzer design](https://github.com/rust-lang/rust-analyzer/issues/22118),
rust-analyzer and its Cargo subprocesses need writable Cargo state.

### Security notes

The Rust wrappers pass `+E` to `skn` for compatibility with Rust toolchains,
Cargo configuration, and project-specific build setups.
Build scripts, proc macros, tests,
and related subprocesses may therefore be able to read environment variables containing secrets.

Cargo home is readable,
so Cargo configuration and credential files may be exposed.
Cargo registry and Git cache directories are writable,
so Cargo may persist changes to downloaded dependency state.
If Cargo registry credentials are needed,
prefer [global credential providers](https://doc.rust-lang.org/cargo/reference/registry-authentication.html)
over storing tokens directly in Cargo home.
