# Sandkasten usage guide

For worked command-line recipes, see [Sandkasten recipes](EXAMPLES.md).

Contents:

- [Setup](#setup)
- [Invoking `skn`](#invoking-skn)
- [Configuration](#configuration)
- [Sandbox model](#sandbox-model)
- [Threat model and non-goals](#threat-model-and-non-goals)
- [Testing](#testing)

## Setup

Normal execution requires `SKN_PATH_CHECK` to name a path-check command.
If you decide to use the included baseline checker as shown in the [README](README.md#installation), set:
```sh
export SKN_PATH_CHECK=skn-baseline-path-check
```

Use `SKN_RO_BINDS` for directories that you consider part of the read-only base system,
but which are not included in the default sandbox (review with `+S`).
For example, after installing Sandkasten helpers in `~/.local/bin`, you likely want:
```sh
export SKN_RO_BINDS="$HOME/.local/bin"
```
For per-command project and data access, prefer `+R`, `+W`, or `+T`.

See [Path checks](#path-checks) and
[Additional read-only binds](#additional-read-only-binds) for details.

## Invoking `skn`

```sh
skn COMMAND [skn-options] [++] [COMMAND-args...]
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
Use `++` to explicitly cease parsing of skn options and pass the remainder to `COMMAND`.
For example, in `skn echo ++ +R`, `+R` is passed to `echo`.

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
+0            emit machine-readable parsed info (for wrappers), then exit
++            stop parsing skn options
```

`+0` is intended for wrappers and similar tooling.
See the source code for the current format.

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
For such interactive programs, run the optional `with-tty` helper inside the sandbox.
It creates a private tmux PTY for the real command and leaves an inspection shell
on output, failure, or suspension; for example, `skn with-tty +A bash +R.`.

Run `skn` without arguments to output a usage message and exit.

`skn` recognizes the following environment variables:

- `SKN_PATH_CHECK` names the mandatory path-check command for normal execution.
- `SKN_RO_BINDS` adds configured additional read-only binds.
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
There is deliberately no default:
if it is missing or mistyped, `skn` fails rather than running without path checks.

`skn` calls this command directly, without shell evaluation,
with each `+R`, `+W`, or `+T` path as its only argument.
A non-zero exit rejects the path and causes `skn` to abort.

Path checks are a pragmatic guardrail against user mistakes,
like running `skn command +R.` while the current directory is `$HOME`.
The explicit `+R`, `+W`, or `+T` options are still the user's access grants,
so the baseline checker is intentionally conservative about false positives.

The included [`skn-baseline-path-check`](skn-baseline-path-check)
implements a baseline policy for typical personal use:
it allows ordinary descendants of `$HOME` and `/tmp`,
but rejects broad grants such as `$HOME` itself and paths whose written or
symlink-resolved form is not readable by “other”.
This typically rejects broad private grants such as `~/.ssh` itself,
while still allowing explicitly named descendant paths that pass the final-path
readability check, for example `~/.ssh/authorized_keys` when that file is
world-readable.
Use it unchanged if this policy fits; otherwise adapt or replace it.

For tests and throw-away experiments,
you can explicitly select a checker that always succeeds:
```sh
export SKN_PATH_CHECK=true
```
Do not use that as your normal setup.

### Additional read-only binds

Set `SKN_RO_BINDS` to a colon-separated list of absolute paths to bind read-only.
For example:
```sh
export SKN_RO_BINDS="$HOME/.rustup:$HOME/.cargo/bin"
```

`SKN_RO_BINDS` entries must be absolute paths.
They come from user configuration and are not checked by `SKN_PATH_CHECK`.
Use this for stable baseline visibility, not per-command access grants;
use `+R` for those.

### Additional passed variables

Set `SKN_PASS_VARS` to a colon-separated list of environment variable names to pass when set.
For example:
```sh
export SKN_PASS_VARS=PYTHONPATH:SSH_AUTH_SOCK:DISPLAY
```

`SKN_PASS_VARS` entries must be variable names, not assignments.
Use `+V VAR` or `+V VAR=VALUE` for per-command environment grants.

### Disposable project writes

Use `+T` when a tool insists on writing into a tree but its changes should not be kept,
for example with
```sh
skn make +T. ++ test
```

Bind order matters. To make most of the project transient-writable
while keeping `target` persistent, use
```sh
mkdir -p target
skn make +T. +W ./target ++ test
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
- The sandbox has its own UTS namespace and a neutral hostname (`skn`).
- A small amount of system configuration is bound read-only when useful.
- User/project files are not visible unless explicitly bound with `+R`, `+W`, `+T`,
  or configured baseline binds such as `SKN_RO_BINDS`.
- The synthetic sandbox filesystem is remounted read-only after setup.
- Persistent writes are limited to explicit `+W` binds.
- Non-persistent writes are limited to the private `/tmp` and explicit `+T` overlays.

DNS resolver configuration and common TLS certificate locations are added only with `+N`.
Host-specific name overrides such as `/etc/hosts` are not exposed automatically;
bind that configuration explicitly if a command needs it.

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
