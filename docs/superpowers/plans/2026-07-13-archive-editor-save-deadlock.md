# Archive Editor Save Deadlock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow archive-editor save completion callbacks to execute immediately while preserving the independent editor window.

**Architecture:** Remove the nested blocking AppKit modal loop from `ArchiveEditorWindowPresenter`. Continue using the existing `NSWindowDelegate` close rules and view-model save lifecycle.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, XCTest, Swift Package Manager, macOS 15+

## Global Constraints

- Preserve the independent 720×540 titled editor window and all save/error/close behavior.
- Do not change archive output, dependencies, or the macOS 15 minimum.
- Do not create commits, branches, or staged changes.

---

### Task 1: Remove Main-Queue Modal Blocking

**Files:**
- Modify: `Tests/ZwzGUITests/ArchiveEditorWindowPresenterTests.swift`
- Modify: `Sources/ZwzGUI/ArchiveEditorWindowPresenter.swift`

**Interfaces:**
- Consumes: `ArchiveEditorWindowPresenter.Coordinator.present(relativeTo:)`.
- Produces: non-blocking window presentation with existing delegate-based dismissal.

- [ ] **Step 1: Add a failing non-blocking presenter test**

Present the editor, enqueue a main-queue fulfillment, and wait through the run loop while the window stays visible. Assert the callback executes before dismissal.

- [ ] **Step 2: Run the test and verify RED**

Run: `swift test --filter ArchiveEditorWindowPresenterTests`

Expected: FAIL or time out because the presenter enters `runModal` on the main queue.

- [ ] **Step 3: Implement the minimal presenter fix**

Remove `isRunningModal`, `NSApp.runModal(for:)`, and all `NSApp.stopModal()` branches. Keep the deferred sizing/positioning/alpha update, then return without starting a modal loop.

- [ ] **Step 4: Verify presenter and save lifecycle tests**

Run: `swift test --filter ArchiveEditorWindowPresenterTests`

Expected: all selected tests pass.

Run: `swift test --filter ArchiveViewModelDirtyStateTests`

Expected: all selected tests pass.

Run: `swift test --filter PublicKeyArchiveWorkflowTests`

Expected: all selected tests pass.

- [ ] **Step 5: Verify complete GUI suite and deliverable**

Run: `swift test --filter ZwzGUITests`

Expected: all GUI tests pass.

Run: `swift build -c release`

Expected: exit code 0.

Run: `./scripts/package-app.sh`

Expected: refreshed `dist/ZwZ.app` and `dist/ZwZ.dmg`.

Manually edit and save a small ZIP, verify the saving overlay disappears, the editor closes, and reopening shows the saved change.
