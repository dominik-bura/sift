# DevSweep

DevSweep is a small native macOS menu-bar app for reclaiming developer storage without deleting projects.

It discovers Git worktrees below configured folders, groups linked worktrees by their shared repository, measures regenerable dependency and build directories, shows the current branch and exact paths, and lets you select globally, per worktree, or per folder before moving anything to macOS Trash. It also reports reclaimable Docker image storage and global developer caches.

## Safety model

DevSweep's cleanup engine only accepts directories with an allow-listed final path component, and only when that directory is a strict descendant of a discovered workspace. It revalidates every target immediately before moving it to Trash.

Generated folders are moved to macOS Trash rather than deleted directly, so they remain recoverable until Trash is emptied.

It never targets:

- a workspace or project root
- `.git` data or source files
- Docker containers or volumes
- generic application caches, profiles, sessions, or offline data
- symbolic links

Docker cleanup runs the equivalent of `docker image prune -a --force`. Docker images cannot be moved to macOS Trash, so this separate action is permanent and has its own explicit confirmation. DevSweep deliberately does not run `docker system prune` or any volume cleanup. Remote Docker contexts are rejected; only a local `unix://` Docker endpoint is allowed.

Global cache cleanup uses the installed package manager's official command and is therefore permanent. Each action has a separate confirmation. DevSweep supports uv, pnpm, Bun, Yarn, npm, and Go build caches. Cache locations must resolve inside the current user's home directory. Installed tools, managed Python versions, lockfiles, and project files are never targeted.

## Supported generated folders

`node_modules`, `.next`, `.venv`, `venv`, `.turbo`, `.parcel-cache`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `__pycache__`, `.svelte-kit`, `.angular`, `.vite`, `.nx`, `.nuxt`, `.output`, `.astro`, `.docusaurus`, `.expo`, `.tox`, `.nox`, `target`, `.gradle`, `.dart_tool`, `.build`, `coverage`, and `Pods`.

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

DevSweep is intentionally dependency-free: SwiftUI/AppKit and Apple system frameworks are its only linked frameworks. Optional cleanup integrations invoke locally installed, trusted-path developer CLIs. It contains no analytics or telemetry. Its only application network access is the narrowly scoped GitHub release check and user-approved update download described below.

## Releases and updates

Every push to `main` runs `.github/workflows/release.yml`, builds a universal Apple Silicon + Intel app, embeds a version and the current GitHub repository, and publishes `DevSweep-<version>.zip` plus its SHA-256 checksum in a GitHub Release. Versions use `0.1.<GitHub run number>` so every release is ordered and unique.

GitHub release builds check the repository's public latest-release endpoint at launch and every six hours. The request sends only the normal IP/TLS metadata and a `DevSweep/<version>` user agent; DevSweep sends no telemetry, paths, storage information, identifiers, or credentials. Downloads happen only after clicking **Update**. The repository must be public because DevSweep intentionally does not store or transmit a GitHub access token.

Before installing, DevSweep requires HTTPS on GitHub-owned release hosts, verifies the published SHA-256 checksum, bundle identifier, embedded version, complete code signature, and—when present—the same Developer ID team. A bundled native helper then replaces and relaunches DevSweep only when its containing directory is writable. Local builds without a GitHub `origin` have update checks disabled.

The workflow creates an ad-hoc signed build with no setup. For warning-free public distribution, configure these repository secrets and the same workflow will Developer ID sign, notarize, and staple the app before publishing it: `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID`.

## Scan performance

DevSweep restores its last validated scan from a small local cache at launch, then refreshes in the background. Known agent workspace roots use shallow discovery and are scanned before broader custom project folders. The built-in locations include Codex, Claude, Cursor, T3, Conductor, Superset, Superconductor, Copilot, and 21st worktrees when those directories exist.

Workspace measurement uses a bounded pool of four concurrent scans. Results appear progressively and the cache is replaced only after the full refresh finishes.

Each cached generated folder also stores its directory modification signature. When that signature is unchanged, DevSweep reuses the previous allocated size instead of walking every file in `node_modules`, `.venv`, or a build cache again. The last-synced banner reports scan duration and the number of reused size measurements.
