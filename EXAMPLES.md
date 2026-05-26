# Sandkasten recipes

These examples assume that [`skn` is installed](README.md#installation)
and that [`SKN_PATH_CHECK` is configured](USAGE.md#setup).
Use `+S` first to inspect the sandbox plan without running the command.
To explore a sandbox interactively before running a command,
copy the equivalent `skn` invocation shown by `+S`,
replace the command and its arguments with `bash`,
or with `with-tty +A bash` if the command needs `/dev/tty`,
and keep the desired sandbox options.

## Running an untrusted project command read-only

Even commands that look informational may execute project-supplied code.
For example, to inspect a source tree’s configure options without giving it
write access to the project, the rest of the home directory, or the network:
```sh
skn ./configure +R. --help
```
If the command needs to write temporary files, it can use the sandbox’s private
`/tmp`, but persistent writes require an explicit `+W` bind.

## Installing and running a Python tool from PyPI

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

## Installing and running an npm-based tool

[Biome](https://biomejs.dev/) serves here as an example of an npm-installed command-line tool
that normally runs without network access.

Assuming `~/.npm-global` and `~/.npm` already exist,
configure the npm prefix through the environment:
```sh
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
alias skn-npm='skn npm +V NPM_CONFIG_PREFIX +W ~/.npm-global +W ~/.npm'
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

## Running an interactive npm-installed coding harness

Use [`with-tty`](USAGE.md#interactive-commands-and-with-tty) for full-screen tools
or other interactive commands that need `/dev/tty` or shell job control.
Suppose an npm-installed coding harness provides `~/.npm-global/bin/harness`
and stores its state in `~/.harness`.

Install or update it using the `skn-npm` setup above:
```sh
mkdir -p ~/.harness
skn-npm +N install -g harness
```

Define a launcher that gives the harness a TTY, network access,
read-only access to its installation prefix,
and writable access to its own state directory:
```sh
alias harness='skn with-tty +A ~/.npm-global/bin/harness +N +R ~/.npm-global +W ~/.harness'
```

Run it on a project by granting project access for that invocation:
```sh
harness +W.
```

For a disposable trial run, make the project transient-writable instead:
```sh
harness +T.
```

This keeps the rest of the home directory hidden,
but `~/.harness` may contain API tokens or other secrets.
Because `+N` is part of the launcher,
those secrets are deliberately exposed to a networked command.

`with-tty`, `tmux`, and the harness’s Node runtime must be visible inside the sandbox.
If any of them are installed outside the default system paths,
bind their install directories read-only, for example with `SKN_RO_BINDS` or `+R`.

## Systematically sandboxing Node and npm

If you do not want npm packages, install scripts, project scripts,
or npm-installed CLIs to inherit ordinary home-directory access,
expose Node and npm through shell functions.
This makes sandboxing the default for commands launched through those functions,
while largely preserving usability.

For a Node installation under `$HOME/opt/node` and a user npm prefix:
```sh
node_home="$HOME/opt/node"
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
mkdir -p ~/.npm "$NPM_CONFIG_PREFIX"

node() {
    skn "$node_home/bin/node" \
        +R "$node_home" \
        +V "PATH=$node_home/bin:$PATH" \
        "$@"
}

npm() {
    skn "$node_home/bin/npm" \
        +R "$node_home" \
        +V "PATH=$node_home/bin:$PATH" \
        +V NPM_CONFIG_PREFIX \
        +W ~/.npm \
        "$@"
}

npm-admin() {
    npm +W "$NPM_CONFIG_PREFIX" "$@"
}
```

The ordinary `npm` function can write npm’s cache,
but it cannot write global packages or project files unless an invocation grants that access.
Install or update a global tool with network access and a writable npm prefix:
```sh
npm-admin +N install -g @biomejs/biome
```

Run project commands by granting project access explicitly:
```sh
npm +N +W. install
npm +W. test
npm +T. run build
```

Keep globally installed npm tools out of the host `PATH`;
expose them through launchers that also expose the Node runtime:
```sh
biome() {
    skn "$NPM_CONFIG_PREFIX/bin/biome" \
        +R "$node_home" \
        +R "$NPM_CONFIG_PREFIX" \
        +V "PATH=$node_home/bin:$PATH" \
        "$@"
}
```

Then grant project access per use:
```sh
biome +R. check .
biome +W. check --write .
```

If Node/npm come from the system package manager under `/usr`,
the explicit `node_home` bind is usually unnecessary because `/usr` is already visible.
For `nvm`, `fnm`, `asdf`, `mise`, or Volta setups,
bind the relevant installed Node version and pass a `PATH` that points at its `bin` directory.

## Rust/Cargo sandboxing

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
