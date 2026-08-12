# Sift

**A native macOS menu-bar app for safely reclaiming developer storage.**

Sift finds regenerable files across Git worktrees—such as `node_modules`, `.next`, and `.venv`—and lets you move them to macOS Trash without deleting your projects. It also shows reclaimable Docker images and common global developer caches in one place.

## Highlights

- Groups linked worktrees by repository and shows their branch, path, and reclaimable size
- Displays scan results progressively, with selection at the global, worktree, and folder level
- Moves generated project folders to macOS Trash so they remain recoverable
- Cleans unused Docker images without touching containers or volumes
- Supports global uv, pnpm, Bun, Yarn, npm, and Go caches
- Runs entirely on your Mac with no analytics or telemetry
- Includes built-in update checks from the app's Settings panel

## Install

1. Download the latest `Sift-*.dmg` from [GitHub Releases](https://github.com/dominik-bura/sift/releases/latest).
2. Open the disk image and drag **Sift** onto the **Applications** shortcut.
3. Eject the disk image, then open Sift from Applications. Its funnel icon will appear in the menu bar.

If macOS blocks the first launch, Control-click the app in Finder, choose **Open**, and confirm once.

Sift requires macOS 14 Sonoma or newer.

## Using Sift

1. Click the Sift icon in the menu bar.
2. Review the repositories, worktrees, and generated folders it found.
3. Select only the items you want to remove.
4. Click **Move to Trash** and confirm the cleanup.

Use the gear in the bottom-left corner to add or remove scanned project folders, see the installed version, or check for updates.

## What Sift cleans

| Area | Cleanup behavior |
| --- | --- |
| Worktrees | Selected generated folders are moved to macOS Trash. Project roots and source files are never selected. |
| Docker | Unused images are permanently pruned after a separate confirmation. Containers and volumes are preserved. |
| Global caches | The installed tool's official cache-cleaning command is run after a separate confirmation. |

Supported generated folders include:

`node_modules`, `.next`, `.venv`, `venv`, `.turbo`, `.parcel-cache`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `__pycache__`, `.svelte-kit`, `.angular`, `.vite`, `.nx`, `.nuxt`, `.output`, `.astro`, `.docusaurus`, `.expo`, `.tox`, `.nox`, `target`, `.gradle`, `.dart_tool`, `.build`, `coverage`, and `Pods`.

Ambiguous names such as `.cache`, `dist`, and `build` are intentionally excluded.

## Safety and privacy

Sift is designed around a narrow cleanup boundary:

- It never deletes a workspace or project root, `.git` data, source files, installed tools, managed Python versions, or lockfiles.
- Every worktree target must have an allow-listed folder name, be a strict descendant of a discovered workspace, and pass validation again immediately before cleanup.
- Symbolic links and paths outside the selected workspace are rejected.
- Worktree folders go to macOS Trash instead of being deleted directly.
- Docker cleanup accepts only a local Unix socket and rejects remote Docker contexts.
- Docker and global cache actions are clearly marked as permanent and require their own confirmation.

Sift has no third-party runtime dependencies, analytics, or telemetry. It does not upload file paths, scan results, storage information, or identifiers. Release builds contact GitHub only to check for a newer version; an update is downloaded only after you choose to install it.

## Build from source

Requirements: macOS 14 or newer and Xcode 16 or newer.

```bash
git clone https://github.com/dominik-bura/sift.git
cd sift
swift test
./scripts/build-app.sh
open build/Sift.app
```

For development, you can run the app directly with:

```bash
swift run Sift
```

Sift is built with SwiftUI, AppKit, and Apple system frameworks. Optional cleanup integrations invoke supported developer tools already installed on your Mac.

## Contributing

Bug reports, feature ideas, and pull requests are welcome through [GitHub Issues](https://github.com/dominik-bura/sift/issues).
