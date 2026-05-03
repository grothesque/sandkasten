# Tests

The test suite can be run from the repository root with
```sh
./tests/run
```

This runs Bash syntax checks, `shellcheck` when available,
whitespace checks in Git worktrees, and the Bats tests under `tests/`.

One can also run only the Bats tests with
```sh
bats tests
```

Some sandbox integration tests require a usable `bubblewrap` setup.
Tests that depend on unavailable features, such as transient overlays, skip themselves.
