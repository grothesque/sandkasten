# Sandkasten: quick-and-proper Bubblewrap sandboxes

Sandkasten (`skn`) is a shell-oriented frontend to
[bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`).
It runs commands in a restricted sandbox, built on Linux namespaces and bind mounts,
that can be selectively relaxed.

A primary use case is defense in depth against supply-chain attacks:
running project tools, build scripts, tests, language servers, coding agents,
and package-ecosystem tools with only the filesystem, environment, and network access they actually need.

For example:
```sh
mkdir -p artifacts
skn untrusted +R. +W artifacts -o artifacts/result
```

This invocation runs `untrusted` with

- read-only access to the current directory (in addition to essential system mounts such as `/usr`),
- write access to `artifacts`,
- no network access.

Normal execution requires a configured `SKN_PATH_CHECK`; this is explained further below.

`skn` options start with `+`, making them easy to mix with the wrapped command’s own arguments.
In the example above, `+R.` and `+W artifacts` are handled by `skn`, while `-o artifacts/result` is passed to `untrusted`.

This convention works well for aliases and wrappers:
```sh
alias untrusted='skn /not/in/path/untrusted'
```

The alias remains usable like the original command,
while sandbox controls can still be added when needed.
To run `untrusted arg` with network access, use
```sh
untrusted +N arg
```

`+S` prints the sandbox plan, including the `bwrap` command that would be run,
allowing sandbox inspection before use.

## Default sandbox

By default, the sandbox has

- no network access,
- a private `/tmp`,
- a neutral hostname (`skn`),
- a mostly cleared environment,
- only minimal read-only access to host system/runtime files,
- no access to the rest of the host filesystem unless explicitly configured.

## Companion tools and workflows

This project includes `skn`-based wrappers for the Rust development tools
[Cargo](https://doc.rust-lang.org/cargo/) and
[rust-analyzer](https://rust-analyzer.github.io/).
They support a cautious workflow: fetch dependencies with network access,
then build and analyze offline; see the [Rust wrappers README](rust/README.md).

Sandkasten is also the recommended outer sandbox for [Sandburg](https://github.com/grothesque/sandburg),
an extension for [Pi](https://pi.dev/), an LLM coding-agent harness.
Sandburg constrains the agent’s built-in tools, while Sandkasten constrains the agent process itself.
Together, they provide a defense-in-depth setup for coding-agent use.

## Installation

`skn` is a simple Bash script.
Besides [bubblewrap](https://github.com/containers/bubblewrap),
it requires only common Unix tools such as `realpath` and `dirname`.
The optional `with-tty` helper is also a Bash script and requires `tmux`.

Install `skn`, and optionally `with-tty`, in any directory on `PATH`.
For example:
```sh
mkdir -p ~/.local/bin
install skn with-tty ~/.local/bin
```

Copying is simplest; symlinking from a checkout is also fine.
If needed, add the install directory to `PATH` in a shell startup file.

`skn` and `with-tty` can also be run directly from a checkout.

The Rust wrappers have their own requirements and installation notes;
see the [Rust wrappers README](rust/README.md).

## First run

To explore the default sandbox with the shipped example path checker, start a shell:
```sh
SKN_PATH_CHECK=./example-path-check ./skn bash +R.
```

The current directory is visible read-only because of `+R.`,
`/tmp` is private and writable, and network access is disabled.
