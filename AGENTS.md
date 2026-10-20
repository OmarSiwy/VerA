# Agents

## Building

- Run every `zig build` inside `nix develop -c …`. The shell gives each Zig store path its own global cache (`ZIG_GLOBAL_CACHE_DIR=~/.cache/zig-<store path>`). ESPice pins a different build of the same Zig version, so with a shared `~/.cache/zig` the two evict each other's build runner and every `zig build`, even `--help`, takes about 2 minutes. The first build in a fresh cache pays a one-time compile of about 70 s.
- Edit loop: keep `zig build check --watch -fincremental` running. `check` type-checks every root without emitting or running anything, so an edit is re-checked in under a second. `zig build test-<x> --watch -fincremental` also works, but each rerun costs the tests' run time.

## Worktrees

- Symlink a new worktree's `.zig-cache` to the main checkout's (`ln -s <main>/.zig-cache <worktree>/.zig-cache`) so they share build results.
- Shared caches share incremental state: run one `--watch -fincremental` per artifact at a time across all worktrees.
