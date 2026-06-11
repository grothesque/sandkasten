# Sandkasten usage guide

For worked command-line recipes, see [Sandkasten recipes](EXAMPLES.md).

Contents:

- [Installation and setup](#installation-and-setup)
- [Invoking `skn`](#invoking-skn)
- [Configuration](#configuration)
- [Interactive commands and `with-tty`](#interactive-commands-and-with-tty)
- [Sandbox model](#sandbox-model)
- [Threat model and non-goals](#threat-model-and-non-goals)
- [Testing](#testing)

## Installation and setup

This guide assumes that `skn` is on `PATH` and that a path checker has been configured.
One basic setup is shown in the [README](README.md#installation-and-basic-setup).
See [Configuration](#configuration) for details.

## Invoking `skn`

```sh
skn COMMAND [skn-options] [++] [COMMAND-args...]
```

Run `COMMAND` inside a `bwrap` sandbox intended for untrusted code.
Without arguments, print a usage message and exit.

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
+X NAME[:PROFILE]
              expand skn options from skn-expansion-NAME
+N            enable network access
+E            preserve caller environment instead of clearing it
+S            show the sandbox plan after parsing, then exit
+0            emit machine-readable parsed info (for wrappers), then exit
++            stop parsing skn options
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

### Transient writable overlays

Use `+T PATH` when an existing directory should appear writable but host data should not be modified.
Initial reads come from the host directory; writes, deletes,
and replacements go to a tmpfs-backed overlay and vanish when the sandbox exits.
For example:
```sh
skn make +T. ++ test
```

Bind order matters. To make most of the project transient-writable
while keeping only `target` persistent, use
```sh
mkdir -p target
skn make +T. +W ./target ++ test
```

`+T` is not a snapshot and does not hide host data:
concurrent host-side changes to the underlying directory are not hidden or made coherent.
`+T` depends on `bubblewrap` and kernel overlayfs support,
and may be unavailable with setuid bubblewrap.

### Option expansion

`+X NAME` runs the command `skn-expansion-NAME`
and expands its output into `skn` options to be given in place of `+X NAME`.
`NAME` must be a simple name that in particular may not contain `/`.

`+X NAME:PROFILE` runs `skn-expansion-NAME PROFILE` instead.
The profile must also be a simple name;
its meaning is defined by the expansion helper.
For example, `+X cargo:rust-analyzer` uses the `rust-analyzer` profile
of the `cargo` expansion.

An expansion is a trusted helper that prints one complete `skn` argument
per line.
For example:
```text
+R
project
+W
project/target
```
The expansion can be inspected by running `skn-expansion-NAME` directly,
or `skn-expansion-NAME PROFILE` for a profiled expansion.
Expansion output is parsed without shell evaluation.
The line-based protocol cannot represent arguments containing newlines.
Expansions may emit ordinary sandbox options,
but not control options such as `+X`, `+S`, `+0`, or `++`.

Expansion helpers run by `skn` get `SKN_EXPANSION_MODE=inspect` for `+S` and `+0`,
and `SKN_EXPANSION_MODE=prepare` for normal execution.
In normal use, prepare mode should emit the same `skn` arguments as inspect mode.
Its purpose is to make those emitted grants valid,
not to change them.
In prepare mode, helpers may perform side effects to make emitted grants valid,
such as creating directories or files that will be bound writable.
Helpers should treat an unset `SKN_EXPANSION_MODE` as `inspect`,
so direct inspection stays side-effect-free.

## Configuration

`skn` is configured through environment variables.
There are no configuration files.

Normal usage requires `SKN_PATH_CHECK` to name a path-check command.
There is deliberately no default:
if the checker is missing or mistyped, `skn` fails rather than running without path checks.

Many users will also want to set `SKN_RO_BINDS` to a colon-separated list of paths (directories or files)
that they consider part of the read-only base system,
but which are not included in the default sandbox (review with `+S`).

A basic configuration can be as simple as the one shown in the [README](README.md#installation-and-basic-setup).

### Path checks

`skn` calls the path-check command directly, without shell evaluation,
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

If this policy fits, set
```sh
export SKN_PATH_CHECK=skn-baseline-path-check
```
Otherwise adapt or replace the checker.

For tests,
or as a one-off bypass for a false positive from the configured checker,
use the standard `true` command as an always-succeeding checker:
```sh
SKN_PATH_CHECK=true skn COMMAND ...
```
Bypassing path checks permanently is not recommended.

### Base filesystem binds

By default, `skn` creates read-only binds to essential parts of the filesystem
such as `/usr`, `/bin`, `/lib`, and a few parts of `/etc`.
The exact binds can be verified using `+S`.

The environment variable `SKN_RO_BINDS` can be used to add
additional paths (directories or files) to the default list of base system read-only binds.
The value must be a colon-separated list of absolute paths, for example:
```sh
export SKN_RO_BINDS="$HOME/.local/bin:$HOME/.npm-global"
```
Since `SKN_RO_BINDS` is meant for stable configuration of the base sandbox,
the paths are not checked by `SKN_PATH_CHECK`.
`SKN_RO_BINDS` entries that do not correspond to an existing path are ignored.

Use `+R`, `+W`, or `+T` for per-command filesystem binds.

### Base environment

Unless the `+E` option is given, `skn` mostly clears the environment.
A few essential variables are passed through by default:
`PATH`, `HOME`, `USER`, `LOGNAME`, `TERM`, `COLORTERM`, `LANG`, and `LC_*`.

To pass additional variables as part of the base environment,
set `SKN_PASS_VARS` to a colon-separated list of environment variable names.
For example:
```sh
export SKN_PASS_VARS=PYTHONPATH:NPM_CONFIG_PREFIX
```

Use `+V` for per-command environment grants.
Unlike `SKN_PASS_VARS`, `+V` also allows assigning new values.

## Interactive commands and `with-tty`

`with-tty` is an independent helper script shipped with Sandkasten.
It is not an `skn` option;
it is a command that is usually run inside an `skn` sandbox.
Use it for interactive terminal programs that expect to open `/dev/tty` directly
or need shell job control.

Without it, symptoms can include errors such as
```text
emacs: Could not open file: /dev/tty
```
or an interactive program such as `nano` or Pi suspending itself
and leaving no usable sandboxed shell to return to.

`with-tty` uses `tmux` internally to give the real command a usable terminal and job control,
so `tmux` must be available inside the sandbox.
The tmux session is private and disposable:
it is not meant to be detached from and reattached to like a normal tmux session.
If the tmux client is detached, `with-tty` reattaches while the session still exists.
The default tmux suspend key binding is disabled.

`with-tty` exits automatically after a quiet successful command,
but leaves an inspection shell when the command prints visible output, fails, or stops.
Use `jobs` and `fg` there for stopped jobs,
and `exit` to end the session.

Run `with-tty` as the sandboxed command and use `+A` to prepend the real interactive command:
```sh
alias skn-nano='skn with-tty +A nano'
skn-nano +W. README.md
```

Because `with-tty` and `tmux` run inside the sandbox,
their executables must be visible there.
If you want `with-tty` to use your regular tmux configuration,
make it visible read-only too:
```sh
export SKN_RO_BINDS="${SKN_RO_BINDS:+$SKN_RO_BINDS:}$HOME/.tmux.conf"
```

`with-tty` intentionally sets only a small tmux baseline.
For example, richer keybindings can live in your `~/.tmux.conf` instead:
```tmux
# Support richer keybindings, for example Ctrl-Enter, on modern terminals.
set-option -g extended-keys on
set-option -g extended-keys-format csi-u
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
- After setup, the sandbox root filesystem is remounted read-only.
- Persistent writes are limited to explicit `+W` binds.
- Non-persistent writes are limited to the private `/tmp` and explicit `+T` overlays.

DNS resolver configuration and common TLS certificate locations are added only with `+N`.
Host-specific name overrides such as `/etc/hosts` are not exposed automatically;
bind that configuration explicitly if a command needs it.

Environment visibility and filesystem visibility are separate:
a directory named in `PATH` is usable only if it is also visible inside the sandbox,
for example through the default system binds, `SKN_RO_BINDS`, or an explicit bind.
Use `+V`, `+E`, or `SKN_PASS_VARS` when additional environment access is needed.

The exact built-in bind list is intentionally an implementation detail;
inspect `./skn` or use `+S` to see the current plan.

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
