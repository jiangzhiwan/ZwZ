# Browser-Style Archive Tabs Design

## Goal

Add a browser-style tab workspace to ZwZ so users can open and operate on multiple archives, compression sources, and extraction tasks concurrently in one window.

## Confirmed Product Decisions

- Always keep at least one tab, including an empty tab that accepts file selection or drag-and-drop.
- If the active tab is empty, reuse it without prompting.
- If the active tab contains content or a task, ask whether to open in a new tab, replace the active tab, or cancel.
- If the same canonical archive path is already open, switch to its existing tab instead of opening a duplicate.
- Compression, preview, and extraction all belong to individual tabs and can run concurrently.
- Closing a running tab requires confirmation and cooperatively cancels its task.
- Restore tabs at launch is configurable and enabled by default.
- Restored encrypted archives request their password again; passwords are never persisted.
- Running tasks are not resumed after restart; restored tabs show that the previous task was interrupted.
- Tabs are horizontally arranged below the main toolbar, Chrome-style, with close and plus buttons.
- Tabs can be dragged to reorder, and the persisted order is restored.
- Keyboard shortcuts: Command-T, Command-W, Control-Tab, Control-Shift-Tab, and Command-1 through Command-9.
- Incomplete-artifact handling is configurable; automatic deletion is the default.
- Tabs shrink to a minimum width, then scroll horizontally.
- Virtual-disk mounting remains a single global resource and shows which tab owns the mount.
- Missing restored files remain as recoverable tabs with Relocate and Close actions.
- Cancellation is cooperative at file or data-block boundaries.
- Background task state appears on tabs as progress, success, or failure indicators.

## Architecture

### Window Workspace

Introduce a main-actor `WorkspaceViewModel` that owns:

- An ordered collection of `WorkspaceTab` objects.
- The selected tab ID.
- Pending open/replace decisions.
- Pending close/cancel decisions.
- Tab persistence and restoration.
- Canonical-path lookup for duplicate prevention.
- Global keyboard navigation actions.

`AppDelegate` owns one `WorkspaceViewModel` for the main window instead of one `ArchiveViewModel`. External file-open events are routed to the workspace so they can activate an existing tab, reuse an empty tab, or present the open-mode decision.

### Workspace Tab

Each `WorkspaceTab` has a stable UUID and owns exactly one `ArchiveViewModel`. It exposes derived presentation state:

- Title and icon.
- Empty, archive, compression-source, extraction-task, missing-file, or interrupted state.
- Current task kind and progress.
- Success or failure indicator.
- Whether it can close immediately or requires cancellation confirmation.
- Canonical source path when one exists.

The existing `ArchiveViewModel` remains responsible for the actual per-tab workflow. Global history, appearance, language, application settings, file associations, and the virtual-disk manager remain shared services.

### Isolation

Every asynchronous callback carries both the tab ID and a per-operation generation ID. Before publishing progress or completion, the callback verifies that the tab still exists and that the operation generation is current. A closed or replaced tab therefore cannot be mutated by a stale background callback.

Passwords stay only in the owning `ArchiveViewModel` and are cleared when the tab is replaced, closed, restored, or reset.

## Tab Interface

The custom tab strip sits below `ZWZToolbar` and above the active tab content.

Each tab displays:

- A type icon when idle.
- A circular progress indicator while running.
- A checkmark after successful completion.
- A red failure indicator after an error.
- A truncated filename or “新标签页” / “New Tab”.
- A close button, visible on hover and always visible for the active tab.

The active tab uses the existing blue/pink visual language. Inactive tabs use subdued material styling. Each tab has a comfortable maximum width and shrinks toward a defined minimum. Once the strip cannot fit all minimum-width tabs, it scrolls horizontally and automatically reveals the selected tab.

The plus button creates and selects an empty tab. Closing the final tab replaces it with a new empty tab.

Drag-and-drop reorders tabs. Reordering updates persistence immediately. Dragging a file onto tab content follows the open-mode rules; dragging a file directly onto an empty tab opens there.

## Open and Replace Rules

All entry points—drop zone, file importer, Finder open events, status-menu preview/extract actions, and restored paths—route through `WorkspaceViewModel.requestOpen(url:intent:)`.

The decision order is:

1. Canonicalize the path, resolving symlinks and standardized path components.
2. If an existing tab has that canonical path, select it.
3. If the active tab is empty, open in the active tab.
4. Otherwise present New Tab, Replace Current, and Cancel choices.

Replacing a running tab first follows the same running-task confirmation and cancellation flow as closing it. Replacement occurs only after cancellation cleanup completes.

## Per-Tab Workflows

Compression options, extraction options, encrypted-preview password prompts, search state, directory navigation, progress, and errors are attached to the owning tab. Switching tabs does not dismiss or transfer another tab's state.

Sheets are presented from the active tab's view and bind to its `ArchiveViewModel`. A sheet belonging to a tab that becomes inactive remains represented by its view-model state and is restored when the tab is selected again, avoiding state leakage between tabs.

Multiple tabs may preview, compress, or extract simultaneously. Each task uses a separate operation context and cancellation token.

## Cooperative Cancellation

Introduce a thread-safe `CancellationToken` with `cancel()` and `checkCancellation()` operations, plus a dedicated cancellation error.

Core compression and extraction APIs accept an optional cancellation token. They check it:

- Before starting a file.
- Between compression or decompression blocks.
- Before committing a completed output file.
- Before finalizing an archive index or split volume.

External helper processes are terminated when cancellation is requested, then waited on to prevent zombies.

Closing a running tab presents confirmation. On confirmation:

1. Mark the tab as canceling and disable repeated close requests.
2. Cancel its operation token.
3. Wait for the operation to acknowledge cancellation.
4. Apply the incomplete-artifact policy.
5. Remove or replace the tab.

## Incomplete Artifact Policy

Add a setting with three values:

- Delete automatically (default).
- Preserve and rename with a `.partial` suffix.
- Ask every time.

Only paths created by the current operation are eligible for automatic deletion or renaming. Pre-existing user files and directories must never be deleted. Temporary extraction directories are always removed unless they contain a deliberately preserved partial result.

## Persistence and Restoration

Add a “Restore tabs at launch” setting, enabled by default.

Persist a versioned, Codable workspace snapshot containing:

- Ordered tab IDs.
- Selected tab ID.
- Tab kind.
- Source path.
- Whether a task was running at the last snapshot.
- The minimum non-sensitive presentation state required to restore the tab.

Do not persist passwords, extracted temporary paths, cancellation tokens, raw archive indexes, or in-progress buffers.

Snapshots are updated after tab creation, close, selection, reorder, source change, and task-state change. Writes are atomic.

At launch:

- If restoration is disabled or no valid snapshot exists, create one empty tab.
- Restore tabs in saved order and select the saved tab when possible.
- Re-preview available archives asynchronously.
- Encrypted archives reopen the password prompt when their tab is selected.
- Tabs whose task was running show an interrupted status and do not restart the operation.
- Missing paths show a missing-file state with Relocate and Close actions.
- If every stored tab is invalid and closed, retain one empty tab.

Relocating a file updates the tab's canonical path and duplicate lookup. If the relocated path is already open elsewhere, select the existing tab and close the missing-file placeholder.

## Virtual Disk Ownership

`VirtualDiskManager` remains a singleton and records the owning tab ID in its session. The owning tab shows the eject action. Other tabs show that the virtual disk is in use and offer actions to switch to the owner or unmount it. Closing the owner tab while mounted retains the existing safety rule: the disk must be unmounted before the tab can finish closing.

## Keyboard Navigation

- Command-T creates and selects an empty tab.
- Command-W requests closure of the selected tab.
- Control-Tab selects the next tab, wrapping at the end.
- Control-Shift-Tab selects the previous tab, wrapping at the start.
- Command-1 through Command-8 select the corresponding tab.
- Command-9 selects the last tab.

Shortcuts operate at the workspace level and do not trigger while a modal confirmation requires a choice.

## Settings

Add a Tabs or Workspace settings section with:

- Restore tabs at launch: Boolean, default true.
- On canceled task: Delete automatically, Preserve as `.partial`, or Ask every time; default Delete automatically.

Settings are localized in Simplified Chinese and English and stored in `UserDefaults` using stable keys.

## Error Handling

- Errors belong to the tab whose operation produced them.
- A background failure marks its tab red without stealing focus.
- Selecting the tab reveals the existing detailed error view.
- Snapshot decoding failure falls back to one empty tab without deleting the unreadable snapshot until a new valid snapshot is saved.
- File-access failures during restoration produce the missing-file state.
- Cancellation is reported as canceled, not failed.
- Failed cleanup reports the path that could not be removed and keeps the tab available for recovery.

## Testing

### Workspace Unit Tests

- Starts and ends with at least one tab.
- Reuses an empty active tab.
- Prompts when the active tab is occupied.
- Selects an existing tab for duplicate canonical paths.
- Creates, selects, closes, replaces, and reorders tabs correctly.
- Wraps next/previous selection and handles Command-1 through Command-9 semantics.
- Ignores stale operation generations.
- Maintains independent state across concurrent tabs.

### Persistence Tests

- Round-trips ordered tabs and selected ID.
- Defaults restoration to enabled.
- Does not encode passwords.
- Restores interrupted and missing-file states correctly.
- Falls back safely for corrupt or unsupported snapshots.
- Relocation resolves duplicates.

### Cancellation Tests

- Cancellation is observed at file and block boundaries.
- Closing a running tab waits for acknowledgment.
- Delete, preserve, and ask policies affect only current-operation artifacts.
- Pre-existing files are never removed.
- External helper processes terminate cleanly.

### Interface Tests

- Tab indicators map correctly from task state.
- The final tab is replaced by an empty tab.
- Open/replace and close-running confirmations expose the correct actions.
- Settings and tab strings are localized.
- Existing archive search and encrypted-password flows stay isolated per tab.

Run focused tests after each task, all GUI tests after workspace integration, core cancellation tests for each archive format, the GUI build, and the complete available suite with any pre-existing long-running limitation reported accurately.

## Delivery Scope

This is one feature but spans workspace state, UI, persistence, core cancellation, settings, and AppDelegate routing. Implementation must be split into independently testable stages. The first usable milestone is multi-tab preview and navigation; subsequent stages add per-tab compression/extraction concurrency, cancellation cleanup, restoration, and global shortcuts without leaving partially wired UI controls.

## Success Criteria

- Users can keep multiple independent archive or task tabs open in one window.
- Empty-tab, duplicate, open/replace, close, reorder, overflow, and shortcut behaviors match the confirmed decisions.
- Per-tab tasks can run concurrently without state leakage.
- Running tabs close safely through cooperative cancellation and configured cleanup.
- Tabs restore by default without persisting passwords or resuming interrupted tasks.
- Missing files and the single global virtual disk have clear recovery and ownership behavior.
- Existing search, password preview, compression, extraction, history, settings, and virtual-disk safety behavior continue to work.
