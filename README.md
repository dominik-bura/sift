<p align="center">
  <img src="App/Assets/SiftAppIcon-1024.png" width="128" height="128" alt="Sift app icon">
</p>

<h1 align="center">Sift</h1>

<p align="center"><strong>A native macOS menu-bar app for safely reclaiming developer storage.</strong></p>

Sift finds regenerable files across Git worktrees—such as `node_modules`, `.next`, and `.venv`—and lets you remove them without deleting your projects. It also shows reclaimable Docker images and common global developer caches in one place.

## Highlights

- Groups linked worktrees by repository and shows their branch, path, and generated-folder size
- Displays scan results progressively, with selection at the global, worktree, and folder level
- Moves generated project folders to macOS Trash by default, with an optional permanent mode
- Cleans unused Docker images and build cache without touching containers or volumes
- Supports global uv, pnpm, Bun, Yarn, npm, Go, and Homebrew caches
- Runs entirely on your Mac with no analytics or telemetry
- Includes built-in update checks from the app's Settings panel
- Adds a read-only Storage explorer with breadcrumbs, largest-file discovery, filtering, size/growth sorting, Finder reveal, and local growth comparisons
- Shows system swap and app process-group resident memory, with normal quit requests
- Supports Pulumi plugin cache, Xcode DerivedData, selected app caches, and unavailable simulator cleanup

## Storage, memory, and cleanup

The **Storage** tab measures readable folders across the data volume, including hidden coding-agent directories, app data, projects, and virtual-machine files. Scans start only when you explicitly choose to measure or refresh a folder, not when you open the tab or navigate. macOS may request access to protected folders; denying access gives partial results and does not prevent normal cleanup. Large scans can take several minutes and continue when the menu closes. Saved results remain visible during refresh. Permission-limited or timed-out scans are labeled explicitly; an unreadable native-scanned folder is shown as unavailable, not empty. The difference between readable-folder totals and volume usage remains visible rather than being presented as reclaimable space.

Clickable breadcrumbs and the full path show the current location. Both refresh buttons scan that location, not an unrelated whole-volume root; their context menu offers a full rescan ignoring cache. Folder results can be filtered by name/path and sorted by size, name, or growth when a comparable complete baseline exists. Muted row bars compare each folder with the largest measured sibling, not the physical disk or guaranteed savings. Filtering does not start a disk-wide search or change the bar scale.

The **Largest files** view retains the 100 largest regular files encountered recursively during the same native scan, with bounded path storage and no extra filesystem walk. It shows file-attributed allocation separately from logical size and flags known hardlink/fully-shared allocation. These file rows overlap folder totals and must never be summed as savings. Filters apply only to that largest-file sample; scan a narrower folder to discover more. Old saved measurements, parent-derived folder results, and the directory-only `du` fallback may have no file index, which is shown explicitly. Permission-limited and live file samples are incomplete. Symlink targets are not followed.

Context badges distinguish supported caches, known generated-worktree data, personal folders, and unknown data needing review. Only paths matched against currently recognized cleanup targets offer **Review cleanup…**; this navigates to Clean up, expands the corresponding cache/worktree, and preserves existing selections without adding any. A nested file's review link is explicitly scoped to the complete supported cache or workspace. All normal validation and confirmations remain required. Other paths offer Finder reveal and copy-path actions, never an arbitrary delete button. Free-space history is collapsed below the explorer so discovery comes first.

Folder-attributed sizes can include shared APFS blocks and must not be interpreted as guaranteed savings. Global cache rows show **stored** size; Sift measures the observed macOS free-space change after cleanup. uv's physical-space reporting option is enabled only when the installed version supports it.

Storage exploration uses a native APFS metadata scanner with up to four shared workers across top-level and shallow subtrees, and batched `getattrlistbulk` reads. One scan-wide ledger counts hardlinks once and deduplicates clones only when macOS reports fully shared blocks with matching clone identity and sizes and no resource fork. Partially shared files and files with resource forks remain conservatively attributed; this is not a unique-extents or guaranteed-savings calculation. Shared bytes have deterministic ownership across displayed rows, so drill-down values scoped to a parent scan may differ from scanning that folder alone. Symlinks are not followed and other mounted filesystems are not traversed. Unsupported filesystems or native metadata fall back to `du -x -k`; permission failures remain partial results, not a reason to bypass access checks.

While refreshing, earlier rows remain visible and newly measured rows are marked. Native progress is throttled to roughly five updates per second, with elapsed time and completed-directory counts, never a guessed percentage. Top-level children include their immediate subfolders for drill-down. Changes of accounting method or sharing scope start a new growth-comparison baseline rather than appearing as storage growth or cleanup savings.

The native live cache is bounded to eight roots for five minutes, in memory only. Filesystem events and recursive-generation counters provide early invalidation, but are not treated as freshness proof: cached totals require a fresh recursive metadata-fingerprint validation, including file identity, allocation, size, modification/change timestamps, and directory identity/timestamps. Changes trigger a full sharing-aware rescan of that root; fine-grained changed-subtree reuse is not implemented yet. Roots with hardlink references outside the scan are not cached, because writes through those aliases may evade root-local events. Partial or cancelled scans are never cached. Cleanup invalidates the live cache. Right-click the folder refresh button for **Full rescan (ignore cache)**. Persistent saved measurements are history, not trusted live cache entries after restart.

Storage scans run one at a time. Additional requests queue up (smaller known folders before whole-volume scans), and a completed parent scan can satisfy a queued child request without another walk. Cancel stops Sift's read-only scan (or its owned fallback `du` process), not other apps or cleanup operations. Completed rows remain visible after cancellation, explicitly incomplete and without a total; earlier completed snapshots remain intact. Queued requests can also be cancelled.

Before the first storage scan, an explicit **Not scanning** card names the action (**Scan data volume** or **Scan this folder**). The Home folder and App data shortcuts only navigate; they never start a scan or request permissions by themselves.

Successful unrestricted folder snapshots are saved locally across restarts for growth comparisons, with first/latest samples per day (up to 64 per folder, 512 globally). Comparisons prefer an available snapshot at least seven days earlier, otherwise the oldest available snapshot, and show the actual date interval. Incomplete or permission-limited scans never become growth baselines. This is attributed folder-size change, not guaranteed reclaimable space. Storage scans remain manual; saving history does not introduce background full-disk scans or automatic cleanup.

The glass UI uses one rounded category breakdown in Clean up rather than repeated miniature row charts. Storage rows use quiet proportional comparison bars; Memory rows stay compact and numeric. The Storage view includes locally saved free-space history, sampled every 15 minutes while Sift runs (up to 30 days). Orange dots mark cleanup attempts, not their causal savings; the trend chart labels its observed vertical range. Folder-change bars compare successful, unrestricted snapshots, not invented daily data. Bars are visual scales, not literal disk blocks.

The **Memory** tab's headline and capacity bar show system RAM in use versus physical memory, refreshed every two seconds while visible. This uses anonymous memory excluding purgeable pages, wired memory, and the physical compressed-memory footprint—not summed app RSS or disk usage. File caches and disk swap are excluded from the RAM numerator; the bar is not a memory-pressure indicator. Swap remains separate below. Resident RAM groups include child processes and may count shared memory more than once. Quit requests are graceful, allowing apps to ask users to save work; Sift never offers to delete swap.

The **Clean up** tab opens by default and groups global sources into expandable **Packages**, **Apps**, and **Developer tools** sections. Individual rows expand for paths, warnings, and scope details. One inventory chart compares measured folder-attributed sizes, including prune-only stores; it is not whole-disk usage or expected freed space. Docker's cleanup estimate is displayed separately and is never added to the stored-folder breakdown. Failed or pending measurements keep the inventory explicitly partial.

The header reports actual macOS free disk space. After a cleanup, a separate observed-result card shows the Mac-wide free-space change during the operation; concurrent app activity can affect it. Moving to Trash is explicitly distinguished from releasing disk space. No zero-valued savings metric is fabricated when a measurement is unavailable.

Generated-folder selections stay deselected by default. The worktree **Selection** menu includes an age-based shortcut using folder modification dates, not last-use dates; review and the normal cleanup confirmation are still required. The footer only offers a destructive action after folders are selected. There is no automatic deletion or history retention policy.

Additional cleanup uses narrow boundaries:

- Pulumi removes downloaded plugins via its CLI; required versions may download again. Infrastructure state and credentials remain excluded.
- Xcode cleanup clears only default DerivedData. Archives, SDKs, and installed simulator runtimes remain excluded.
- Dia, Codex, and Spark cleanup clears specific Library cache directories only. Known running apps must quit first. App support data, conversations, profiles, and worktrees are excluded.
- Simulator cleanup uses `simctl delete unavailable` against the same device set used for measurement. The row measures only device directories explicitly reported as unavailable by `simctl`, not all simulator storage. It deletes unavailable device data permanently and preserves available devices and installed runtimes. Listing or measurement failures are shown as errors, not as an empty cache; attributed bytes are not guaranteed disk-space savings.
- Pulumi plugins and simulator devices require individual confirmation and are excluded from **Clean eligible…**, as are blocked caches. Bulk confirmation names the eligible sources before executing anything.

VM disks, personal files, downloads, and agent conversations are inspectable in Storage and Finder, but Sift does not delete them through these new cleanup actions. Storage snapshots contain local paths and sizes, remain on the Mac, and are never uploaded.

## Install

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
