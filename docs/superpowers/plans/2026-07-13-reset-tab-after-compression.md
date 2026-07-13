# Reset Tab After Successful Compression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the current workspace tab to a truly empty state after successful compression while preserving history and retry state on failure.

**Architecture:** Send a success-only callback from `ArchiveViewModel` after its generation-checked completion. Let `WorkspaceTab` reset its own content and kind, and notify `WorkspaceViewModel` to persist the new empty state.

**Tech Stack:** Swift 6.3, SwiftUI, XCTest, Swift Package Manager, macOS 15+

## Global Constraints

- Preserve compression output, options, history, errors, tab ordering, and tab identity.
- Reset only after successful compression; never after failure, cancellation, or recovery.
- Do not change dependencies or the macOS 15 minimum.
- Do not create commits, branches, or staged changes.

---

### Task 1: Model Successful Compression Completion

**Files:**
- Modify: `Sources/ZwzGUI/ArchiveViewModel.swift`
- Modify: `Tests/ZwzGUITests/PublicKeyArchiveWorkflowTests.swift`

**Interfaces:**
- Produces: `var onCompressionSucceeded: (@MainActor () -> Void)?`.

- [ ] **Step 1: Add failing success/failure callback tests**

Use `ArchiveWorkflowSpy` for a successful operation and a queued compression failure. Assert that success appends history before invoking the callback, while failure never invokes it and keeps `sourcePath`.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter PublicKeyArchiveWorkflowTests`

Expected: FAIL because `onCompressionSucceeded` does not exist.

- [ ] **Step 3: Add the minimal callback**

Declare the internal callback on `ArchiveViewModel`. In the generation-checked success block, append history and then invoke the callback. Do not invoke it in any error branch.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter PublicKeyArchiveWorkflowTests`

Expected: all selected tests pass.

### Task 2: Reset and Persist the Workspace Tab

**Files:**
- Modify: `Sources/ZwzGUI/WorkspaceTab.swift`
- Modify: `Sources/ZwzGUI/WorkspaceViewModel.swift`
- Modify: `Tests/ZwzGUITests/WorkspaceViewModelTests.swift`

**Interfaces:**
- Consumes: `ArchiveViewModel.onCompressionSucceeded`.
- Produces: `WorkspaceTab.onPersistentStateChanged` for saving the reset snapshot.

- [ ] **Step 1: Add a failing workspace behavior test**

Trigger the success callback on an occupied workspace tab. Assert its ID is unchanged, `kind == .empty`, `sourcePath == nil`, title is the localized new-tab title, history is retained, and `requestOpen` for another URL leaves `pendingOpenRequest == nil`.

- [ ] **Step 2: Run test and verify RED**

Run: `swift test --filter WorkspaceViewModelTests`

Expected: FAIL because the callback does not reset the tab.

- [ ] **Step 3: Implement tab reset and persistence wiring**

In `WorkspaceTab.init`, attach the compression-success callback to call `clearPreview()`, set `kind = .empty`, and notify `onPersistentStateChanged`. In `WorkspaceViewModel`, configure that persistence callback for initial, new, restored, and replacement tabs.

- [ ] **Step 4: Verify focused and full GUI suites**

Run: `swift test --filter WorkspaceViewModelTests`

Expected: all selected tests pass.

Run: `swift test --filter ZwzGUITests`

Expected: all GUI tests pass.

- [ ] **Step 5: Build, package, and manually verify**

Run: `swift build -c release`

Expected: exit code 0.

Run: `./scripts/package-app.sh`

Expected: refreshed `dist/ZwZ.app` and `dist/ZwZ.dmg`.

Manually compress a dropped folder, verify the same tab becomes empty, then drop another file and verify no replacement prompt appears.
