# Browser-Style Archive Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a persistent, browser-style multi-tab workspace whose tabs independently preview, compress, extract, search, request passwords, and run cancelable tasks.

**Architecture:** A window-level `WorkspaceViewModel` owns ordered `WorkspaceTab` objects, each containing an independent `ArchiveViewModel`. Open events, duplicate-path resolution, selection, reordering, restoration, shortcuts, and close decisions belong to the workspace; archive operations remain inside the tab view model. Core operations gain cooperative cancellation tokens before running-tab closure and partial-output cleanup are enabled.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, Combine, XCTest, Swift Package Manager, UserDefaults, Codable JSON

## Global Constraints

- Always retain at least one tab.
- Reuse an empty active tab; prompt New Tab / Replace Current / Cancel for an occupied active tab.
- Canonical duplicate paths activate their existing tab.
- Tabs and their compression, preview, extraction, password, search, progress, and error state are isolated and may run concurrently.
- Restore tabs defaults to enabled; never persist passwords.
- Cancellation is cooperative at file or block boundaries.
- Canceled output defaults to deletion, with `.partial` and ask-every-time settings.
- Virtual-disk mounting remains globally single-instance.
- Maintain Simplified Chinese and English localization.
- No new package dependencies.

---

### Task 1: Workspace Domain Model

**Files:**
- Create: `Sources/ZwzGUI/WorkspaceTab.swift`
- Create: `Sources/ZwzGUI/WorkspaceViewModel.swift`
- Create: `Tests/ZwzGUITests/WorkspaceViewModelTests.swift`

**Interfaces:**
- Produces: `WorkspaceTab`, `WorkspaceTabKind`, `WorkspaceTaskBadge`, `WorkspaceOpenDecision`, and `@MainActor final class WorkspaceViewModel`.
- `WorkspaceViewModel` exposes `tabs`, `selectedTabID`, `selectedTab`, `newTab()`, `selectTab(id:)`, `requestClose(id:)`, `closeImmediately(id:)`, `moveTab(fromOffsets:toOffset:)`, `selectNext()`, `selectPrevious()`, and `selectShortcutIndex(_:)`.

- [ ] **Step 1: Write failing invariant and navigation tests**

Create tests proving a new workspace starts with one empty selected tab, closing the last tab creates another empty tab, selecting and reordering preserve identity, next/previous wrap, and shortcut 9 selects the last tab.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter WorkspaceViewModelTests`

Expected: compilation fails because workspace types do not exist.

- [ ] **Step 3: Implement minimal domain types**

Define stable UUID identity, one `ArchiveViewModel` per tab, derived title/kind/badge, and the ordered collection operations required by tests. Keep persistence and file opening out of this task.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter WorkspaceViewModelTests`

Expected: all workspace invariant tests pass.

---

### Task 2: Per-Tab Operation Identity and Isolation

**Files:**
- Modify: `Sources/ZwzGUI/ArchiveViewModel.swift`
- Modify: `Sources/ZwzGUI/WorkspaceTab.swift`
- Test: `Tests/ZwzGUITests/WorkspaceViewModelTests.swift`

**Interfaces:**
- Produces: `operationGeneration: UUID?`, `beginOperation() -> UUID`, `acceptsCallback(generation:) -> Bool`, and `invalidateOperation()`.

- [ ] **Step 1: Add failing isolation tests**

Test that two tabs have different view models and state, replacement invalidates the old generation, and progress/completion tagged with a stale generation is ignored.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter WorkspaceViewModelTests`

Expected: generation and callback-gating APIs are missing.

- [ ] **Step 3: Add operation generation gates**

Start a generation for preview, compression, and extraction. Capture it in every asynchronous callback and guard before publishing progress, success, or failure. Reset sensitive state during tab replacement.

- [ ] **Step 4: Verify GREEN and existing GUI tests**

Run: `swift test --filter WorkspaceViewModelTests`

Run: `swift test --filter ZwzGUITests`

Expected: both pass.

---

### Task 3: Browser-Style Tab Strip and Active Content

**Files:**
- Create: `Sources/ZwzGUI/WorkspaceTabBar.swift`
- Create: `Sources/ZwzGUI/WorkspaceContentView.swift`
- Modify: `Sources/ZwzGUI/ZwzApp.swift:350-425`
- Test: `Tests/ZwzGUITests/WorkspaceViewModelTests.swift`

**Interfaces:**
- Consumes: Task 1 workspace collection and selection APIs.
- Produces: reusable `WorkspaceTabBar` and a content host that renders only the selected tab's existing workflow views.

- [ ] **Step 1: Add failing badge/title presentation tests**

Assert empty, running, completed, failed, missing, and interrupted tab states map to the specified localized title and badge values.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter WorkspaceViewModelTests`

- [ ] **Step 3: Build the tab strip**

Use a horizontal `ScrollViewReader`, shrinking tab frames with a fixed minimum and maximum, active/inactive material styling, progress/check/failure indicators, hover close buttons, a plus button, selection, close requests, and selected-tab auto-scroll.

- [ ] **Step 4: Host active per-tab content**

Refactor the current `ContentView` body into a per-tab content component bound to one `ArchiveViewModel`. Place the toolbar, tab strip, and active content in a new workspace shell. Bind all sheets to the selected tab view model without sharing their state.

- [ ] **Step 5: Build and regress**

Run: `swift build --target ZwzGUI`

Run: `swift test --filter ZwzGUITests`

Expected: GUI builds and all GUI tests pass.

---

### Task 4: Open Routing, Duplicate Detection, and Replace Decisions

**Files:**
- Modify: `Sources/ZwzGUI/WorkspaceViewModel.swift`
- Modify: `Sources/ZwzGUI/WorkspaceContentView.swift`
- Modify: `Sources/ZwzGUI/ZwzApp.swift:10-335`
- Create: `Tests/ZwzGUITests/WorkspaceOpenRoutingTests.swift`

**Interfaces:**
- Produces: `requestOpen(url:intent:)`, `pendingOpenRequest`, `resolvePendingOpen(_:)`, and canonical-path lookup.
- `WorkspaceOpenResolution` cases: `newTab`, `replaceCurrent`, `cancel`.

- [ ] **Step 1: Write failing routing tests**

Cover empty-tab reuse, occupied-tab prompt, canonical duplicate activation, cancel, new-tab opening, replacement, and Finder/AppDelegate routing.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter WorkspaceOpenRoutingTests`

- [ ] **Step 3: Implement canonical routing**

Standardize and resolve symlinks before lookup. Route drop, file importer, external app-open, and menu actions through the workspace. Do not call a tab's `handleAutoOpen` until the workspace has selected a destination tab.

- [ ] **Step 4: Add the three-choice dialog**

Present localized New Tab, Replace Current, and Cancel actions. Replacing an idle tab clears its view model first. Defer running-tab replacement to Task 7 cancellation flow.

- [ ] **Step 5: Verify GREEN**

Run: `swift test --filter WorkspaceOpenRoutingTests`

Run: `swift build --target ZwzGUI`

---

### Task 5: Tab Drag Reordering and Keyboard Shortcuts

**Files:**
- Modify: `Sources/ZwzGUI/WorkspaceTabBar.swift`
- Modify: `Sources/ZwzGUI/WorkspaceViewModel.swift`
- Modify: `Sources/ZwzGUI/ZwzApp.swift`
- Test: `Tests/ZwzGUITests/WorkspaceViewModelTests.swift`

**Interfaces:**
- Produces: tab drag payload by stable UUID and app commands for new, close, next, previous, and numbered selection.

- [ ] **Step 1: Add failing reorder and shortcut tests**

Cover moving both directions, keeping the moved tab selected, Command-1 through Command-8, Command-9 last-tab semantics, and modal-decision shortcut suppression.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter WorkspaceViewModelTests`

- [ ] **Step 3: Implement drag reorder**

Use tab UUID payloads and an explicit drop delegate so reordering is deterministic and persists through selection changes.

- [ ] **Step 4: Implement commands**

Add SwiftUI/AppKit command handlers for Command-T, Command-W, Control-Tab, Control-Shift-Tab, and Command-1…9. Route all actions to `WorkspaceViewModel`.

- [ ] **Step 5: Verify GREEN**

Run: `swift test --filter WorkspaceViewModelTests`

Run: `swift build --target ZwzGUI`

---

### Task 6: Versioned Workspace Persistence and Missing Files

**Files:**
- Create: `Sources/ZwzGUI/WorkspaceSnapshot.swift`
- Create: `Sources/ZwzGUI/WorkspacePersistence.swift`
- Modify: `Sources/ZwzGUI/WorkspaceViewModel.swift`
- Create: `Sources/ZwzGUI/MissingFileTabView.swift`
- Create: `Tests/ZwzGUITests/WorkspacePersistenceTests.swift`

**Interfaces:**
- Produces: `WorkspaceSnapshot(version:tabs:selectedTabID:)`, `WorkspaceTabSnapshot`, atomic `load()` and `save(_:)`, `restoreTabs()`, and `relocateMissingTab(id:to:)`.

- [ ] **Step 1: Write failing persistence tests**

Cover ordered round trip, selected tab, running-to-interrupted mapping, password exclusion, corrupt snapshot fallback, unsupported version fallback, disabled restoration, missing path, and relocation duplicate resolution.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter WorkspacePersistenceTests`

- [ ] **Step 3: Implement versioned snapshots**

Store only stable ID, kind, source path, running flag, and non-sensitive presentation state. Write JSON atomically to Application Support or a test-injected URL. Never encode `ArchiveViewModel.password`.

- [ ] **Step 4: Restore and re-preview**

Default restoration to enabled. Restore order and selection, convert running tasks to interrupted, re-preview available archives, request passwords again when needed, and retain missing paths as placeholder tabs.

- [ ] **Step 5: Add relocation UI**

Show localized File Missing, Relocate, and Close actions. Route selected replacement through canonical duplicate detection.

- [ ] **Step 6: Verify GREEN**

Run: `swift test --filter WorkspacePersistenceTests`

Run: `swift build --target ZwzGUI`

---

### Task 7: Core Cooperative Cancellation

**Files:**
- Create: `Sources/ZwzCore/CancellationToken.swift`
- Modify: `Sources/ZwzCore/Types.swift`
- Modify: `Sources/ZwzCore/ZipCompressor.swift`
- Modify: `Sources/ZwzCore/ZwzCompressor.swift`
- Modify: `Sources/ZwzCore/ArchiveExtractor.swift`
- Modify: `Sources/ZwzCore/ZwzExtractor.swift`
- Modify: `Sources/ZwzCore/ZWZV2/ZwzV2Compressor.swift`
- Modify: `Sources/ZwzCore/ZWZV2/ZwzV2Extractor.swift`
- Modify: `Sources/ZwzCore/ZwzAPI.swift`
- Create: `Tests/ZwzCoreTests/CancellationTokenTests.swift`
- Create: `Tests/ZwzCoreTests/OperationCancellationTests.swift`

**Interfaces:**
- Produces: thread-safe `CancellationToken`, `ZwzError.operationCancelled`, and optional `cancellationToken` parameters with default `nil` on public APIs.

- [ ] **Step 1: Write failing token tests**

Test initial state, idempotent cancellation, cross-thread observation, and `checkCancellation()` throwing the dedicated error.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter CancellationTokenTests`

- [ ] **Step 3: Implement the token**

Use a lock-protected Boolean or equivalent Sendable-safe primitive. Keep existing public callers source-compatible with default `nil` parameters.

- [ ] **Step 4: Add failing operation cancellation tests**

Exercise ZIP and ZWZ compression plus supported extraction paths with multi-file/block fixtures. Cancel from progress callbacks and assert the dedicated cancellation error and absence of finalized output.

- [ ] **Step 5: Verify operation RED**

Run: `swift test --filter OperationCancellationTests`

- [ ] **Step 6: Thread cancellation through core loops**

Check before files, between blocks, before file commit, and before archive/index finalization. For `Process` helpers, register termination on cancel and wait for process exit. Do not map cancellation to generic extraction failure.

- [ ] **Step 7: Verify core GREEN**

Run: `swift test --filter CancellationTokenTests`

Run: `swift test --filter OperationCancellationTests`

Expected: cancellation tests pass for each covered format.

---

### Task 8: Running-Tab Close, Cleanup Policies, and Replacement

**Files:**
- Create: `Sources/ZwzGUI/IncompleteArtifactPolicy.swift`
- Modify: `Sources/ZwzGUI/ArchiveViewModel.swift`
- Modify: `Sources/ZwzGUI/WorkspaceViewModel.swift`
- Modify: `Sources/ZwzGUI/WorkspaceContentView.swift`
- Create: `Tests/ZwzGUITests/WorkspaceCancellationTests.swift`

**Interfaces:**
- Produces: `requestClose`, `confirmCloseRunningTab`, cancel acknowledgment, operation-owned artifact tracking, and policy cases `delete`, `preservePartial`, `ask`.

- [ ] **Step 1: Write failing close and cleanup tests**

Test idle close, running confirmation, cancel acknowledgment before removal, repeated-close suppression, delete policy, `.partial` policy, ask policy, replacement after cleanup, and protection of pre-existing files.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter WorkspaceCancellationTests`

- [ ] **Step 3: Integrate per-tab cancellation**

Create a fresh token per task, expose canceling state, and acknowledge completion on the main actor. Make close/replacement wait for acknowledgment.

- [ ] **Step 4: Track operation-owned artifacts**

Record only paths created by the current generation. On cancellation, delete, rename, or prompt according to policy. Never remove a pre-existing destination.

- [ ] **Step 5: Add confirmation UI**

Present localized running-task close confirmation and, for ask policy, Delete / Preserve `.partial` / Cancel choices.

- [ ] **Step 6: Verify GREEN**

Run: `swift test --filter WorkspaceCancellationTests`

Run: `swift test --filter ZwzGUITests`

---

### Task 9: Workspace Settings and Localization

**Files:**
- Modify: `Sources/ZwzGUI/ZwzApp.swift:1535-1725`
- Modify: `Sources/ZwzGUI/Localization.swift`
- Modify: `Sources/ZwzGUI/WorkspaceViewModel.swift`
- Create: `Tests/ZwzGUITests/WorkspaceSettingsTests.swift`

**Interfaces:**
- UserDefaults keys: `zwz_restore_tabs` default true and `zwz_cancelled_artifact_policy` default `delete`.

- [ ] **Step 1: Add failing default and localization tests**

Assert restore defaults true, policy defaults delete, all three policy values round-trip, and all new tab/workspace strings exist in Chinese and English.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter WorkspaceSettingsTests`

- [ ] **Step 3: Add settings UI**

Create a Workspace settings section with the restore toggle and canceled-artifact picker. Inject the values into workspace restore and cleanup behavior.

- [ ] **Step 4: Add all localized copy**

Include New Tab, open-mode choices, close-running confirmation, progress states, interrupted task, missing file, relocation, virtual-disk ownership, and cleanup policy strings.

- [ ] **Step 5: Verify GREEN**

Run: `swift test --filter WorkspaceSettingsTests`

Run: `swift build --target ZwzGUI`

---

### Task 10: Virtual Disk Tab Ownership

**Files:**
- Modify: `Sources/ZwzGUI/VirtualDiskManager.swift`
- Modify: `Sources/ZwzGUI/WorkspaceViewModel.swift`
- Modify: `Sources/ZwzGUI/ZwzApp.swift:900-1235`
- Modify: `Tests/ZwzGUITests/VirtualDiskManagerTests.swift`

**Interfaces:**
- Add `ownerTabID: UUID?` to `VirtualDiskSession` with backward-compatible decoding.
- Produces workspace actions to select owner or request unmount.

- [ ] **Step 1: Add failing ownership tests**

Test owner round trip, older session decoding without owner, owner-tab eject controls, non-owner switch/unmount choices, and prevention of owner close while mounted.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter VirtualDiskManagerTests`

- [ ] **Step 3: Implement ownership**

Record selected tab ID at mount, expose owner lookup through the workspace, and clear ownership on unmount. Keep the singleton one-mount rule.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter VirtualDiskManagerTests`

Run: `swift build --target ZwzGUI`

---

### Task 11: AppDelegate Integration and Full Regression

**Files:**
- Modify: `Sources/ZwzGUI/ZwzApp.swift:10-350`
- Modify: all workspace files from Tasks 1-10 as required by integration findings.

**Interfaces:**
- AppDelegate owns one `WorkspaceViewModel`; main window receives the workspace; all external open/menu events route through it.

- [ ] **Step 1: Replace the single main view model**

Construct the workspace once in AppDelegate, restore it before window presentation, and pass it to the workspace content root. Ensure reopen preserves the same workspace instance.

- [ ] **Step 2: Route status-menu and Finder events**

Use workspace open intents for preview, extract, compression, clipboard, and `application(_:open:)`. Preserve duplicate-path activation and the open/replace prompt.

- [ ] **Step 3: Verify focused suites**

Run: `swift test --filter WorkspaceViewModelTests`

Run: `swift test --filter WorkspaceOpenRoutingTests`

Run: `swift test --filter WorkspacePersistenceTests`

Run: `swift test --filter WorkspaceCancellationTests`

Run: `swift test --filter WorkspaceSettingsTests`

Run: `swift test --filter VirtualDiskManagerTests`

- [ ] **Step 4: Verify all GUI behavior**

Run: `swift test --filter ZwzGUITests`

Expected: all GUI tests pass with zero failures.

- [ ] **Step 5: Verify core cancellation and existing core behavior**

Run: `swift test --filter CancellationTokenTests`

Run: `swift test --filter OperationCancellationTests`

Run the existing archive preview, search, password, ZWZ round-trip, security, and recovery focused suites affected by signature changes.

- [ ] **Step 6: Build release-relevant targets**

Run: `swift build --target ZwzGUI`

Run: `swift build -c release --product ZwzGUI`

Expected: both builds succeed.

- [ ] **Step 7: Run complete suite and inspect final changes**

Run: `swift test`. Because the current core suite includes expensive encrypted fixtures, allow sufficient time and report any long-running limitation accurately.

Inspect all changed files for placeholders, debug output, trailing whitespace, and unrelated edits. If Git metadata remains unavailable, report changed files without attempting commits or branch integration.
