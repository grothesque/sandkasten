# Sandkasten: low-friction, inspectable per-command sandboxes

Sandkasten (`skn`) runs shell commands in a restricted sandbox
(built on Linux namespaces and bind mounts)
that can be selectively relaxed.
It is a frontend to [bubblewrap](https://github.com/containers/bubblewrap),
but unlike `bwrap`, the `skn` interface is optimized for interactive shell use.

A primary use case is defense in depth against supply-chain attacks:
running project tools, build scripts, tests, language servers, coding agents,
and package-ecosystem tools with only the filesystem, environment, and network access they actually need.

For example:
```sh
mkdir -p build
skn make +T. +W build
```

This runs `make` with

- the default sandbox (see next section),
- persistent write access to the `build` directory,
- temporary overlay access to the current directory: `make` can modify/delete files there,
  but incidental build by-products outside `build` are only visible to `make` itself
  and disappear when it finishes.

`skn` options start with `+`, making them easy to mix with the wrapped command’s own arguments.
In the example above, `+T.` and `+W build` are handled by `skn`;
any later make targets or options would be passed to `make`.

This convention works well for aliases and wrappers:
```sh
alias untrusted='skn /usr/local/bin/untrusted'
```

Such an alias remains usable like the original command,
while sandbox controls can still be added when needed.
To run `untrusted arg` with network access, use
```sh
untrusted +N arg
```

Normal execution requires a configured path check;
see [Installation](#installation).

## Default sandbox

By default, the sandbox has

- no network access,
- a private `/tmp`,
- a neutral hostname (`skn`),
- a mostly cleared environment,
- only minimal read-only access to host system/runtime files,
- no access to the rest of the host filesystem unless explicitly configured.

## Try it without installing

`skn` is a Bash script.
To try it out, run from the Sandkasten directory:
```sh
export SKN_PATH_CHECK=./skn-baseline-path-check
./skn wc +R. -l README.md
./skn touch +R. README.md
```
For the above to work,
the [`bwrap`](https://github.com/containers/bubblewrap) command must be available.

Note that the first argument must be the command to be run,
optionally followed by skn options and then command arguments.
Here, `wc` and `touch` are the commands,
`+R.` is an skn option,
and `-l README.md` or `README.md` are command arguments.

Running `wc -l README.md` will succeed,
but `touch README.md` will fail because the current directory was bound read-only with `+R.`.
If that was changed to `+W.`, touch would succeed as well.

To inspect the sandbox, add `+S`.
This prints the sandbox plan, including the `bwrap` command that would be run,
allowing sandbox inspection before use.

To explore the sandbox interactively, replace the command with a shell:
```sh
./skn bash +R.
```

`SKN_PATH_CHECK` names a path-check command.
`skn` calls it before accepting paths passed to `+R`, `+W`, or `+T`;
this is a guardrail against accidentally exposing too much of the host filesystem.
There is deliberately no built-in default:
if the variable is missing or mistyped,
`skn` fails instead of silently running without this guardrail.
The included [`skn-baseline-path-check`](skn-baseline-path-check) is a baseline checker for typical personal use.

## Installation

`skn` is a single-file Bash script.
It requires the [`bwrap`](https://github.com/containers/bubblewrap) command.

Install `skn`, the included baseline path checker,
and the optional `with-tty` helper in a directory on `PATH`:
```sh
mkdir -p ~/.local/bin
install skn skn-baseline-path-check with-tty ~/.local/bin/
```
Ensure `~/.local/bin` is on `PATH`, or use another install directory that is.

Then add basic setup to your shell startup file:
```sh
export SKN_PATH_CHECK=skn-baseline-path-check
export SKN_RO_BINDS="$HOME/.local/bin"
```

`SKN_RO_BINDS` makes installed helpers such as `with-tty` visible inside sandboxes.
If you install them somewhere else, bind that directory instead.
Missing `SKN_RO_BINDS` entries are ignored.

The included checker rejects broad or surprising path grants;
use it unchanged if that policy fits, otherwise adapt or replace it.
See [Setup](USAGE.md#setup) and [Path checks](USAGE.md#path-checks).

## Documentation

- [Using Sandkasten](USAGE.md): setup, full invocation syntax,
  `with-tty` use, configuration, sandbox model, and threat model.
- [Sandkasten recipes](EXAMPLES.md): practical Python, npm, Rust,
  and other workflows.

## Companion tools and workflows

This project includes `skn`-based wrappers for the Rust development tools
[Cargo](https://doc.rust-lang.org/cargo/) and
[rust-analyzer](https://rust-analyzer.github.io/).
They support a cautious workflow: fetch dependencies with network access,
then build and analyze offline; see the [Rust wrappers README](rust/README.md).

Sandkasten can also serve as an outer sandbox for coding-agent harnesses.
For example, it is the recommended outer sandbox for
[Sandburg](https://github.com/grothesque/sandburg),
an extension for [Pi](https://pi.dev/), an LLM coding-agent harness.
Sandburg constrains the agent’s built-in tools,
while Sandkasten constrains the harness process itself.
Together, they provide a defense-in-depth setup for coding-agent use.

## Security note

Sandkasten is a pragmatic containment layer,
not a complete security solution.
It relies on the kernel and bubblewrap;
read-only binds still expose data for reading;
and network access can exfiltrate exposed data.
See the full [threat model and non-goals](USAGE.md#threat-model-and-non-goals).
