# Changelog

## [Unreleased]

### Changed

- Replace the `--` skn option terminator with `++`.
- Replace the shell-quoted `+I` wrapper-info mode with `+0`,
  that emits a machine-readable format with a NUL-delimited argv.
  This avoids having to use `eval` in wrappers (like those under `rust/`).

## [0.1.1] - 2026-05-18

### Fixed

- Safer output: keep reporting `SKN_PATH_CHECK` rejections until all paths have been processed (or another error occurred).

## [0.1.0] - 2026-05-17

- Initial public release
