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
see [Installation and basic setup](#installation-and-basic-setup).

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
For it to work,
the [`bwrap`](https://github.com/containers/bubblewrap) command must be available.

To try it out, run from the Sandkasten directory:
```sh
export SKN_PATH_CHECK=./skn-baseline-path-check
./skn wc +R. -l README.md    # will succeed
./skn touch +R. README.md    # will fail
```

Note that the first argument must be the command to be run,
optionally followed by skn options and then command arguments.
Here, `wc` and `touch` are the commands,
`+R.` is an skn option,
and `-l README.md` or `README.md` are command arguments.

Running `wc -l README.md` will succeed,
but `touch README.md` will fail because the current directory was bound read-only with `+R.`.
If `+W.` was used instead, touch would succeed as well.

To inspect the sandbox, add `+S`.
This prints the sandbox plan, including the `bwrap` command that would be run,
allowing sandbox inspection before use.

To explore the sandbox interactively, replace the command with a shell:
```sh
./skn bash +R.
```

The environment variable `SKN_PATH_CHECK` names a path-check command.
`skn` calls it once for each path passed via `+R`, `+W`, or `+T`,
with the path as its sole argument.
This is a guardrail against accidentally exposing too much of the host filesystem.
There is deliberately no built-in default:
if the variable is missing or mistyped,
`skn` fails instead of silently running without this guardrail.
The included [`skn-baseline-path-check`](skn-baseline-path-check) is a baseline checker for typical personal use.

## Installation and basic setup

Copy `skn`, the included baseline path checker,
and the optional `with-tty` helper to a directory on `PATH`, for example:
```sh
mkdir -p ~/.local/bin
install skn skn-baseline-path-check with-tty ~/.local/bin/
```

Then add basic setup to your shell startup file:
```sh
export SKN_PATH_CHECK=skn-baseline-path-check
export SKN_RO_BINDS="$HOME/.local/bin"
```

In order to provide a usable minimal default sandbox,
`skn` makes essential parts of the host filesystem such as `/usr` readable in the sandbox by default.
Likewise, a few essential environment variables such as `PATH`, `HOME`, `USER`,
and terminal/locale settings are passed through by default,
while the rest of the environment is cleared.

This base sandbox is intentionally cautious
and may need a few additional read-only binds for user-installed tools.
This is done by setting the environment variable `SKN_RO_BINDS`
to a colon-separated list of absolute paths.
In particular, if a command in `PATH` is installed outside the default binds,
make sure that all necessary files are available inside the sandbox.

The included checker rejects broad or surprising path binds specified by `+R`, `+W`, or `+T`;
use it unchanged if that policy fits, otherwise adapt or replace it.
See [Installation and setup](USAGE.md#installation-and-setup) and [Path checks](USAGE.md#path-checks).

## Documentation

- [Using Sandkasten](USAGE.md): setup, full invocation syntax,
  `with-tty` use, configuration, sandbox model, and threat model.
- [Sandkasten recipes](EXAMPLES.md): practical Python, npm, Rust,
  and other workflows.

## Companion tools and workflows

This project includes `skn`-based wrappers for the Rust development tools
[Cargo](https://doc.rust-lang.org/cargo/) and
[rust-analyzer](https://rust-analyzer.github.io/).
They support a cautious workflow: dependency fetching may use network access,
while builds and analysis run offline by default; see the [Rust wrappers README](rust/README.md).

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
