<p align="center">
  <img src="App/Assets/SiftAppIcon-1024.png" width="128" height="128" alt="Sift app icon">
</p>

<h1 align="center">Sift</h1>

<p align="center"><strong>A native macOS menu-bar app for safely reclaiming developer storage.</strong></p>

Sift finds regenerable files across Git worktrees—such as `node_modules`, `.next`, `.venv`, and `.terraform`—and lets you remove them without deleting your projects. It also shows reclaimable Docker images and common global developer caches in one place.

## Highlights

- Groups linked worktrees by repository and shows their branch, path, and generated-folder size
- Displays scan results progressively, with selection at the global, worktree, and folder level
- Moves generated project folders to macOS Trash by default, with an optional permanent mode
- Cleans unused Docker images and build cache without touching containers or volumes
- Supports global uv, pnpm, Bun, Yarn, npm, npx, pip, Go, and Homebrew caches, including pnpm stores left behind by other pnpm versions
- Runs entirely on your Mac with no analytics or telemetry
- Includes built-in update checks from the app's Settings panel
- Opens macOS Storage Settings from Sift’s settings for the broader disk breakdown
- Shows system swap and app process-group resident memory, with normal quit requests
- Supports Pulumi plugin cache, Xcode DerivedData and documentation, simulator caches, Docker Scout, Playwright browsers, and unavailable simulator cleanup
- Clears the web caches of common Electron apps, editors, and browsers, plus leftover app update downloads, without touching sign-ins or app data
- Shows when each cache last changed and keeps caches that are still in use out of bulk cleanup

## Storage, memory, and cleanup

Sift has two tabs: **Clean up** and **Memory**. For the broader disk breakdown, choose **Open macOS Storage Settings…** in Sift’s settings. The separate Storage investigation tab has been removed; opening Sift does not start a whole-disk scan or request access to protected libraries.

The internal storage scanner and privacy protections remain available to the codebase. Known protected locations are excluded before opening them during broad discovery; explicitly configured project roots remain usable. This conservative path policy is not an exhaustive macOS permission detector. No privacy settings are changed automatically.

Folder-attributed sizes can include shared APFS blocks and must not be interpreted as guaranteed savings. Global cache rows show **stored** size; Sift measures the observed macOS free-space change after cleanup. uv's physical-space reporting option is enabled only when the installed version supports it.

The **Memory** tab's headline and capacity bar show system RAM in use versus physical memory, refreshed every two seconds while visible. This uses anonymous memory excluding purgeable pages, wired memory, and the physical compressed-memory footprint—not summed app RSS or disk usage. File caches and disk swap are excluded from the RAM numerator; the bar is not a memory-pressure indicator. Swap remains separate below. Resident RAM groups include child processes and may count shared memory more than once. Quit requests are graceful, allowing apps to ask users to save work; Sift never offers to delete swap.

The **Clean up** tab opens by default and groups global sources into expandable **Packages**, **Apps**, and **Developer tools** sections. Individual rows expand for paths, warnings, and scope details. One inventory chart compares measured folder-attributed sizes, including prune-only stores; it is not whole-disk usage or expected freed space. Docker's cleanup estimate is displayed separately and is never added to the stored-folder breakdown. Failed or pending measurements keep the inventory explicitly partial.

The header reports actual macOS free disk space. After a cleanup, a separate observed-result card shows the Mac-wide free-space change during the operation; concurrent app activity can affect it. Moving to Trash is explicitly distinguished from releasing disk space. No zero-valued savings metric is fabricated when a measurement is unavailable.

Generated-folder selections stay deselected by default. The worktree **Selection** menu includes an age-based shortcut using folder modification dates, not last-use dates; review and the normal cleanup confirmation are still required. The footer only offers a destructive action after folders are selected. There is no automatic deletion or history retention policy.

Independent cleanup sources can run in parallel, including Docker, separate caches, and a selected worktree-folder batch. Each source has its own busy state; duplicate operations and overlapping ancestor/descendant paths (including known symlink aliases) are blocked. **Clean eligible…** starts independent source jobs and skips already-busy or conflicting sources, while plugins, simulators, blocked caches, and caches changed in the last 14 days retain their individual-review rules. Failures remain visible on their source even if another job succeeds. Jobs continue when the menu closes. Whole-inventory refresh waits until cleanup is idle, and results from scans begun before a cleanup cannot overwrite its newer state. Free-space changes are Mac-wide observations and may include concurrent cleanups or other activity; do not add them as per-job savings.

Additional cleanup uses narrow boundaries:

- Pulumi removes downloaded plugins via its CLI; required versions may download again. Infrastructure state and credentials remain excluded.
- Xcode cleanup clears only default DerivedData. Archives, SDKs, and installed simulator runtimes remain excluded.
- Dia, Codex, Spark, Helium, Firefox, and Spotify cleanup clears specific Library cache directories only. Known running apps must quit first. App support data, conversations, profiles, offline downloads, and worktrees are excluded.
- VS Code, VS Code Insiders, Cursor, Kiro, Antigravity, Notion, Miro, Slack, Claude, Capacities, and Postman cleanup empties only `Cache`, `Code Cache`, and `GPUCache` (also inside `Partitions/*`); editors additionally clear `CachedData`, `CachedExtensionVSIXs`, and `logs`. `Service Worker`, `WebStorage`, `IndexedDB`, `Local Storage`, `workspaceStorage`, settings, and extensions are never listed. The app must quit first. Caches of apps in daily use grow back, so the gain is temporary.
- App update downloads covers `*-updater` and `*.ShipIt` folders in `~/Library/Caches` and `*-updater` in `~/Library/Application Support/Caches`. Anything changed in the last 24 hours is kept because it may be a pending update.
- Developer tool caches are emptied in place: Docker Scout analysis results, the simulator dyld cache, Xcode's documentation cache, virtualenv seed wheels, node-gyp headers, and AzCopy job logs older than a day (transfer plans are kept). Playwright browsers require individual confirmation because tests fail until `playwright install` runs again.
- npm's row measures only `_cacache`, which is what `npm cache clean` clears; npx packages in `~/.npm/_npx` are a separate source. When no trusted `bun` executable is found, the default Bun cache is emptied directly, and the Bun cache bundled with Reflex is its own source.
- **Other pnpm stores** lists `v<number>` store directories beside the store the installed pnpm reports. `pnpm store prune` never touches them. They are removed entirely and require individual confirmation. Stores containing a `links` entry are excluded, including symlink markers, because pnpm's global virtual store can still back existing projects through symlinks even when another pnpm version is installed. Other store files are hard-linked or cloned into normal project-local `node_modules` and can be downloaded again when needed. The cleaner repeats this exclusion immediately before removal.
- `.terraform` and project-local `.pnpm-store` folders are offered per worktree. Removing `.terraform` requires `terraform init` before the next plan, re-supplying any `-backend-config` values, and resets the selected workspace to `default`; state files beside it are never touched.
- Wildcard paths never match symbolic links, a literal cache path that is a link fails closed, and only the exact listed directories are emptied.
- File-based sources skip unreadable matched folders and continue with readable ones. Rows show a skipped-location count; expand them for exact paths and access errors. Skipped folders are excluded from displayed size and left untouched by cleanup, including when only a descendant is unreadable. Wildcard enumeration permission failures are also listed, never mistaken for an absent source; unsafe or symlink-redirected paths still fail closed. Partial subtotals are labeled measured, and an entirely skipped source is not labeled Empty. After cleanup, an incomplete or age-skipped measurement cannot establish removed bytes; only a complete measurement or verified absence can establish a zero-byte result. No access is requested and no permissions are changed automatically.
- Simulator cleanup uses `simctl delete unavailable` against the same device set used for measurement. The row measures only device directories explicitly reported as unavailable by `simctl`, not all simulator storage. It deletes unavailable device data permanently and preserves available devices and installed runtimes. Listing or measurement failures are shown as errors, not as an empty cache; attributed bytes are not guaranteed disk-space savings.
- Pulumi plugins, simulator devices, Playwright browsers, and other pnpm stores require individual confirmation and are excluded from **Clean eligible…**, as are blocked caches. Bulk confirmation names the eligible sources before executing anything.
- Each measured cache shows when it last changed. This is the newest modification date inside the cache, not a last-use date. A cache changed in the last 14 days is probably still in use, so clearing it mostly causes the same data to download again: **Clean eligible…** skips it, while its own **Clean…** button stays available. Prune-only sources are unaffected.

VM disks, personal files, downloads, and agent conversations are inspectable in Storage and Finder, but Sift does not delete them through these new cleanup actions. Storage snapshots contain local paths and sizes, remain on the Mac, and are never uploaded.

## Install

### Homebrew

```bash
brew tap dominik-bura/sift
brew install --cask dominik-bura/sift/sift
```

See [Homebrew release setup](docs/homebrew-releases.md) for the dedicated-tap configuration.

### Direct download

1. Download the latest `Sift-*.dmg` from [GitHub Releases](https://github.com/dominik-bura/sift/releases/latest).
2. Open the disk image and drag **Sift** onto the **Applications** shortcut.
3. Eject the disk image, then open Sift from Applications. Its funnel icon will appear in the menu bar.

### First launch

If macOS shows **“Sift Not Opened”** for an older or locally built copy, you can allow that specific copy as follows:

1. Try to open Sift once, then dismiss the warning.
2. Open **System Settings → Privacy & Security**.
3. Scroll down to **Security** and click **Open Anyway** next to the message about Sift.
4. Confirm by clicking **Open** and entering your Mac password if requested.

macOS saves Sift as an exception, so this is required only once for that installed copy. See [Apple's instructions for opening an unnotarized app](https://support.apple.com/en-us/102445).

GitHub releases are explicitly labeled **Unsigned** when the repository has no Apple Developer ID and notarization credentials configured.

Sift requires macOS 14 Sonoma or newer.

## Using Sift

1. Click the Sift icon in the menu bar.
2. Review the repositories, worktrees, and generated folders it found.
3. Select only the items you want to remove.
4. Click **Move to Trash** and confirm the cleanup.

Use the gear in the bottom-left corner to add or remove scanned project folders, choose the worktree cleanup mode, see the installed version, or check for updates.

Release builds check for updates on launch and every six hours. When an update is available, Sift shows a native update window while you are using the app, not over another app or during cleanup. Choose **Update & Relaunch**, **Remind Me Tomorrow**, or **Skip This Version**. Reminder and skip choices survive restarts; the gear badge and manual Update action remain available. Downloads and installation require your approval. Cleanup cannot start during an approved update, and installation cannot start while cleanup is running.

## What Sift cleans

| Area | Cleanup behavior |
| --- | --- |
| Worktrees | Selected generated folders move to macOS Trash by default. A default-off setting can delete them immediately after an additional explicit confirmation. Project roots and source files are never selected. |
| Docker | Unused images and build cache are permanently pruned after a separate confirmation. Containers and volumes are preserved. |
| Global caches | The installed tool's official cache-cleaning command is run after a separate confirmation. |

Supported generated folders include:

`node_modules`, `.next`, `.venv`, `venv`, `.turbo`, `.parcel-cache`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `__pycache__`, `.svelte-kit`, `.angular`, `.vite`, `.nx`, `.nuxt`, `.output`, `.astro`, `.docusaurus`, `.expo`, `.tox`, `.nox`, `target`, `.gradle`, `.dart_tool`, `.build`, `coverage`, and `Pods`.

Ambiguous names such as `.cache`, `dist`, and `build` are intentionally excluded.

## Safety and privacy

Sift is designed around a narrow cleanup boundary:

- It never deletes a workspace or project root, `.git` data, source files, installed tools, managed Python versions, or lockfiles.
- Every worktree target must have an allow-listed folder name, be a strict descendant of a discovered workspace, and pass validation again immediately before cleanup.
- Symbolic links and paths outside the selected workspace are rejected.
- Worktree folders go to macOS Trash by default. Permanent deletion is available only through a persistent, default-off setting and is clearly identified in the confirmation.
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
open "build/Sift Dev.app"
```

For development, you can run the app directly with:

```bash
swift run Sift
```

Local builds use the separate `Sift Dev.app` identity, keep their own preferences, and have update checks disabled. Production `Sift.app` bundles are created only by the release workflow.

Sift is built with SwiftUI, AppKit, and Apple system frameworks. Optional cleanup integrations invoke supported developer tools already installed on your Mac.

## Contributing

Bug reports, feature ideas, and pull requests are welcome through [GitHub Issues](https://github.com/dominik-bura/sift/issues).
