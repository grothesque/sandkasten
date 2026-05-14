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

Install `skn` in any directory on `PATH`.
For example:
```sh
mkdir -p ~/.local/bin
install skn ~/.local/bin
```

Copying is simplest; symlinking from a checkout is also fine.
If needed, add the install directory to `PATH` in a shell startup file.

`skn` can also be run directly from a checkout.

The Rust wrappers have their own requirements and installation notes;
see the [Rust wrappers README](rust/README.md).

## First run

To explore the default sandbox without configuring a path checker yet, start a shell:
```sh
SKN_PATH_CHECK=true ./skn bash +R.
```

The current directory is visible read-only because of `+R.`,
`/tmp` is private and writable, and network access is disabled.

`SKN_PATH_CHECK=true` disables path policy and is convenient for first experiments.
Before routine use, configure a real `SKN_PATH_CHECK`; see [Path checks](#path-checks).

## Invoking `skn`

```sh
skn COMMAND [skn-options] [--] [COMMAND-args...]
```

`COMMAND` comes before `skn` options.
This keeps aliases and wrappers transparent while putting sandbox controls in the separate `+` option namespace:
```sh
alias foo='skn foo'
foo +W ../data run
```
The above expands to `skn foo +W ../data run`, so `skn` handles `+W ../data`
and passes `run` to `foo`.

`skn` parses only the initial run of `+` options after `COMMAND`.
The first non-option argument ends that run and is passed on to `COMMAND`.
Unrecognized uppercase `+` forms are reserved for future `skn` options.
Use `--` to explicitly cease parsing of skn options and pass the remainder to `COMMAND`.
For example, in `skn echo -- +R`, `+R` is passed to `echo`.

Options:
```text
+R PATH       bind PATH read-only into the sandbox
+W PATH       bind PATH writable into the sandbox
+T PATH       bind directory PATH transient-writable; writes are discarded
+V VAR        pass environment VAR into the sandbox if it is set
+V VAR=VALUE  set environment VAR to VALUE inside the sandbox
+A ARG        prepend ARG to COMMAND arguments
+N            enable network access
+E            preserve caller environment instead of clearing it
+S            show the sandbox plan after parsing, then exit
+I            show only the parsed skn info header, then exit
--            stop parsing skn options
```

Bind options are order-sensitive.
For example, `+T. +W ./out` makes the current directory transient-writable,
then keeps `./out` persistent;
reversing the options makes `./out` part of the transient overlay.

`+A` is mainly for aliases and wrappers that need fixed command arguments
while still allowing callers to add `skn` options:
```sh
alias foo-json='skn foo +A --format +A json'
foo-json +R. input
```
This runs `foo --format json input` with read-only access to the current directory.

`skn` starts the sandbox in a new terminal session,
so programs that open `/dev/tty` directly may fail even when ordinary stdin/stdout works.
For such interactive programs, consider running `tmux` inside the sandbox,
for example `skn tmux +R. new-session`.

Run `skn` without arguments to output a usage message and exit.

`skn` recognizes the following environment variables:

- `SKN_PATH_CHECK` names the mandatory path-check command for normal execution.
- `SKN_RO_BINDS` adds trusted additional read-only binds.
- `SKN_PASS_VARS` names environment variables to pass when set.

See [Configuration](#configuration) for details.

### Transient writable overlays

Use `+T PATH` when an existing directory should appear writable but changes should be discarded.
Initial reads come from the host directory; writes, deletes,
and replacements go to temporary sandbox storage and vanish when the sandbox exits.

`+T` is useful for tools that insist on writing to a cache or source tree even when host data should not be modified.

`+T` is not a snapshot and does not hide host data:
concurrent host-side changes to the underlying directory are not hidden or made coherent,
and reads can still expose secrets from that directory.
Writes consume temporary sandbox storage.
`+T` also depends on `bubblewrap` and kernel overlayfs support,
and may be unavailable with setuid bubblewrap.

### Nested `skn` usage

Inside a `skn` sandbox, scripts and aliases may invoke `skn` again,
creating nested sandboxes.
An inner sandbox cannot expose host paths that the outer sandbox did not expose,
or make an outer read-only bind writable.

To make nested usage convenient, `skn` passes `SKN_RO_BINDS` and `SKN_PASS_VARS` through
and sets `SKN_PATH_CHECK=true` by default.
Explicit `+V` options or `SKN_PASS_VARS` entries, including `SKN_PATH_CHECK`,
take precedence over these nested defaults.
Unset or override these variables before invoking the inner `skn` to make the nested sandbox narrower.

## Configuration

`skn` is configured through environment variables.
There are no configuration files.
The most important setting is `SKN_PATH_CHECK`.

### Path checks

For normal execution, `SKN_PATH_CHECK` must name a path-check command.
`skn` calls this command directly, without shell evaluation,
with each `+R`, `+W`, or `+T` path as its only argument.
A non-zero exit rejects the path and causes `skn` to abort with an error message.

The same check applies to read-only, writable, and transient-writable binds.
The check is intended as a guard against user mistakes,
such as running `skn command +W .` directly under `/home/user`.
The caller still chooses the access mode:
use `+W` only for paths where persistent writes are intended.

For testing, path checking can be disabled with
```sh
export SKN_PATH_CHECK=true
```

One simple useful path-check script is
```sh
#!/bin/bash
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: ${0##*/} PATH" >&2; exit 2; }

# Canonicalize $HOME for reliable matching.
home=$(realpath -ms -- "${HOME:?}")

# Check both the path as written and the path with symlinks resolved.
for path in "$(realpath -ms -- "$1")" "$(realpath -m -- "$1")"; do
    case "$path/" in
        # Allow descendants of $HOME and /tmp, but not those directories themselves.
        "$home"/?*|/tmp/?*) ;;

        # Reject everything else.
        *) exit 1 ;;
    esac

    # As a simple secrecy heuristic, reject paths that are not readable by “other”.
    [[ $(stat -c %A -- "$path") == ???????r?? ]] || exit 1
done
```
Save it as `~/bin/is-ok-for-untrusted`, make it executable, and enable it with
```sh
chmod +x ~/bin/is-ok-for-untrusted
export SKN_PATH_CHECK="$HOME/bin/is-ok-for-untrusted"
```

The example above is intentionally permissive:
it rejects obvious mistakes while staying out of the way for ordinary project, cache, and tool paths.
Adjust it as needed.
The checker is responsible for canonicalization, symlink handling, and any other policy requirements.

### Additional read-only binds

Set `SKN_RO_BINDS` to a colon-separated list of absolute paths to bind read-only.
For example:
```sh
export SKN_RO_BINDS="$HOME/.rustup:$HOME/.cargo/bin"
```

`SKN_RO_BINDS` entries must be absolute paths.
They are trusted user configuration and are not checked by `SKN_PATH_CHECK`.
Use this for stable setup, not per-command access grants;
use `+R` for those.

### Additional passed variables

Set `SKN_PASS_VARS` to a colon-separated list of environment variable names to pass when set.
For example:
```sh
export SKN_PASS_VARS=PYTHONPATH:SSH_AUTH_SOCK:DISPLAY
```

`SKN_PASS_VARS` entries must be variable names, not assignments.
Use `+V VAR` or `+V VAR=VALUE` for per-command environment grants.

## Practical examples

These examples assume that `skn` is installed and that `SKN_PATH_CHECK` is configured.
Use `+S` first to inspect the sandbox plan without running the command.
To explore a sandbox interactively before running a command,
copy the equivalent `skn` invocation shown by `+S`,
replace the command and its arguments with `bash` or `tmux`,
and keep the desired sandbox options.

### Running an untrusted project command read-only

Even commands that look informational may execute project-supplied code.
For example, to inspect a source tree’s configure options without giving it
write access to the project, the rest of the home directory, or the network:
```sh
skn ./configure +R. --help
```
If the command needs to write temporary files, it can use the sandbox’s private
`/tmp`, but persistent writes require an explicit `+W` bind.

### Installing and running a Python tool from PyPI

[Bandit](https://bandit.readthedocs.io/) is a Python security linter
that can scan a project without network access.
To install it from PyPI into a virtual environment,
begin by creating a fresh virtual environment and starting a sandboxed shell.
```sh
mkdir -p ~/venvs ~/.cache/pip
python3 -m venv ~/venvs/bandit
skn bash +N +W ~/venvs/bandit +W ~/.cache/pip
```
(Use `+T ~/.cache/pip` to leave no trace in the pip cache.)

Inside the sandboxed shell, activate the venv and install Bandit:
```
. ~/venvs/bandit/bin/activate
pip install bandit
exit
```

Bandit itself can run offline with read-only project access.
The installed console script uses the virtual environment’s Python,
so it can be executed directly:
```sh
skn ~/venvs/bandit/bin/bandit +R ~/venvs/bandit +R. -r .
```

For convenience, consider defining a shell alias
```sh
alias bandit='skn ~/venvs/bandit/bin/bandit +R ~/venvs/bandit'
```

In the following example (using the above alias) a report file is created with a shell redirect.
```sh
bandit +R. -r . -f json >report.json
```
Note that bandit still does not need writable project access.

### Installing and running an npm-based tool

[Biome](https://biomejs.dev/) serves here as an example of an npm-installed command-line tool
that normally runs without network access.

Assuming `~/.npmrc` configures `~/.npm-global` as the npm prefix,
and `~/.npm-global` and `~/.npm` already exist, the following shell alias is useful:
```sh
alias skn-npm='skn npm +R ~/.npmrc +W ~/.npm-global +W ~/.npm'
```
Replace `+W ~/.npm` with `+T ~/.npm` in the alias to discard npm cache writes.

Install Biome with network access:
```sh
skn-npm +N install -g @biomejs/biome
```
Keep `~/.npm-global/bin` out of `PATH`; expose installed commands through aliases:
```sh
alias biome='skn ~/.npm-global/bin/biome +R ~/.npm-global'
```

Biome can check a project offline with read-only project access:
```sh
biome +R. check .
```
To apply fixes persistently, grant writable project access explicitly:
```sh
biome +W. check --write .
```

### Rust/Cargo sandboxing

For a typical rustup-based setup, manual Cargo invocations under `skn` may look as follows:
```sh
alias skn-cargo-basic='skn cargo +R ~/.rustup +W ~/.cargo'
skn-cargo-basic +N +W. fetch
skn-cargo-basic +W. --offline build
```

This illustrates a useful pattern: fetch dependencies with network access,
then build without network access.
The bundled [Rust wrappers](rust/README.md) provide a more targeted solution:
`skn-cargo` automates workspace and Cargo-home grants
and refuses network access for build-like commands,
while `skn-rust-analyzer` runs rust-analyzer and its Cargo subprocesses in an offline sandbox.
These wrappers also serve as examples of building tool-specific wrappers around `skn`.

### Disposable project writes

Use `+T` when a tool insists on writing into a tree but its changes should not be kept,
for example with
```sh
skn make +T. -- test
```

Bind order matters. To make most of the project transient-writable
while keeping `target` persistent, use
```sh
mkdir -p target
skn make +T. +W ./target -- test
```

## Sandbox model

`skn` is deliberately simpler than `bwrap`.
Most notably, it does not allow re-binding paths to different locations.
This restriction simplifies the mental model, the user interface, and the path checker.
The simplified model is often sufficient to run ordinary command-line tools.
Use full `bwrap` for use cases like running a desktop application in a re-bound home directory.

Within that model, `skn` starts from a small, mostly read-only view of the host system and adds only the access that the user requests.

In broad strokes:

- System/runtime files are bound read-only.
- A small amount of system configuration is bound read-only when useful.
- User/project files are not visible unless explicitly bound with `+R`, `+W`, `+T`,
  or trusted configuration such as `SKN_RO_BINDS`.
- The synthetic sandbox filesystem is remounted read-only after setup.
- Persistent writes are limited to explicit `+W` binds.
- Non-persistent writes are limited to the private `/tmp` and explicit `+T` overlays.

DNS resolver configuration and common TLS certificate locations are added only with `+N`.
Host-specific name overrides such as `/etc/hosts` are not exposed automatically;
bind trusted configuration explicitly if a command needs it.

The environment is mostly cleared by default.
Use `+V`, `+E`, or `SKN_PASS_VARS` when environment access is needed.

The exact built-in bind list is intentionally an implementation detail;
inspect `./skn` or use `+S` to see the current plan.

## Threat model and non-goals

`skn` is intended to reduce accidental exposure when running untrusted project code,
build scripts, proc macros, tests, language servers, coding agents, and similar tools.
It is especially useful for preventing easy access to unrelated files in the home directory and for disabling network access by default.

It is not a complete security solution.
In particular:

- It relies on the kernel and bubblewrap behaving correctly.
- It does not defend against kernel vulnerabilities or sandbox escapes.
- Read-only binds still expose data for reading.
- Network access allows exfiltration of exposed data.
- It does not make malicious code safe to run with secrets deliberately bound into the sandbox.
- `+E` preserves the caller environment, which may expose secrets through environment variables.
- Persistent writable bind mounts allow sandboxed code to modify those paths.

Treat it as a pragmatic containment layer, not as a guarantee that hostile code is harmless.

## Testing

Run the test suite with
```sh
./tests/run
```

See [`tests/README.md`](tests/README.md) for details.
