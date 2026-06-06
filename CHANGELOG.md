# Changelog

## [Unreleased]

- Improve compatibility of `with-tty` with arbitrary user `.tmux.conf`:
  limit given tmux options to essentials;
  make detachment prevention more robust and less intrusive.
- Treat `SKN_RO_BINDS` entries as optional read-only binds; missing entries are now ignored.

## [0.2.0] - 2026-05-26

- Replace the `--` skn option terminator with `++`.
- Replace the shell-quoted `+I` wrapper-info mode with `+0`,
  that emits a machine-readable format with a NUL-delimited argv.
  This avoids having to use `eval` in wrappers (like those under `rust/`).
- Rename `example-path-check` to `skn-baseline-path-check`
  and document it as the included baseline path checker.
- Add `with-tty`, a helper for running interactive commands with a usable TTY,
  job control, and an inspection shell.

## [0.1.1] - 2026-05-18

- Safer output: keep reporting `SKN_PATH_CHECK` rejections until all paths have been processed (or another error occurred).

## [0.1.0] - 2026-05-17

- Initial public release
