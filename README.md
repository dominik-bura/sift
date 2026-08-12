# DevSweep

DevSweep is a small native macOS menu-bar app for reclaiming developer storage without deleting projects.

It discovers Git worktrees below configured folders, groups linked worktrees by their shared repository, measures regenerable dependency and build directories, shows the current branch and exact paths, and lets you select globally, per worktree, or per folder before moving anything to macOS Trash. It also reports reclaimable Docker image storage and can prune unused images.

## Safety model

DevSweep's cleanup engine only accepts directories with an allow-listed final path component, and only when that directory is a strict descendant of a discovered workspace. It revalidates every target immediately before moving it to Trash.

Generated folders are moved to macOS Trash rather than deleted directly, so they remain recoverable until Trash is emptied.

It never targets:

- a workspace or project root
- `.git` data or source files
- Docker containers or volumes
- generic application caches, profiles, sessions, or offline data
- symbolic links

Docker cleanup runs the equivalent of `docker image prune -a --force`. Docker images cannot be moved to macOS Trash, so this separate action is permanent and has its own explicit confirmation. DevSweep deliberately does not run `docker system prune` or any volume cleanup.

## Supported generated folders

`node_modules`, `.next`, `.venv`, `venv`, `.turbo`, `.parcel-cache`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `__pycache__`, `.svelte-kit`, `.angular`, and `.vite`.

Generic names such as `.cache`, `dist`, and `build` are intentionally excluded because they are too ambiguous to delete safely.

## Build and run

Requirements: macOS 14 or newer and Xcode 15 or newer.

```bash
swift test
./scripts/build-app.sh
open build/DevSweep.app
```

The build script creates an ad-hoc signed app at `build/DevSweep.app`. Drag it to `/Applications` for normal use. On first launch, add any project parent folders that are not among the defaults.

## Development

```bash
swift run DevSweep
```

DevSweep is intentionally dependency-free: SwiftUI/AppKit, Foundation, and the local Docker CLI are all it uses.

## Scan performance

DevSweep restores its last validated scan from a small local cache at launch, then refreshes in the background. Known agent workspace roots use shallow discovery and are scanned before broader custom project folders. The built-in locations include Codex, Claude, Cursor, T3, Conductor, Superset, Superconductor, Copilot, and 21st worktrees when those directories exist.

Workspace measurement uses a bounded pool of four concurrent scans. Results appear progressively and the cache is replaced only after the full refresh finishes.
