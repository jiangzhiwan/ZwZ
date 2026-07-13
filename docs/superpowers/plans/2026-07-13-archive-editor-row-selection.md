# Archive Editor Row Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore archive-editor row selection while preserving double-click opening.

**Architecture:** Keep the existing SwiftUI `List` and selection binding. Add the same explicit single-click assignment used by the working preview list, alongside the existing double-click handler.

**Tech Stack:** Swift 6.3, SwiftUI, XCTest, Swift Package Manager, macOS 15+

## Global Constraints

- Preserve row visuals, double-click opening, toolbar actions, and editing behavior.
- Do not change dependencies or the macOS 15 minimum.
- Do not create commits, branches, or staged changes.

---

### Task 1: Restore Editor Row Selection

**Files:**
- Modify: `Tests/ZwzGUITests/CompressionOptionsLayoutTests.swift`
- Modify: `Sources/ZwzGUI/ZwzApp.swift`

**Interfaces:**
- Consumes: `ZWZArchiveEditorView.selectedPath` and `ArchiveEntry.path`.
- Produces: explicit single-click row selection while retaining double-click `openEditEntry(_:)`.

- [ ] **Step 1: Add the failing interaction contract test**

Extract `ZWZArchiveEditorView` from `ZwzApp.swift` and assert its row contains `.onTapGesture { selectedPath = entry.path }` immediately before the existing `.onTapGesture(count: 2)` handler.

- [ ] **Step 2: Run the test and verify RED**

Run: `swift test --filter CompressionOptionsLayoutTests`

Expected: FAIL because editor rows have only a double-click handler.

- [ ] **Step 3: Implement the minimal fix**

Add a single-click gesture to the editor row that assigns `selectedPath = entry.path`. Leave the double-click body unchanged.

- [ ] **Step 4: Verify focused and complete GUI suites**

Run: `swift test --filter CompressionOptionsLayoutTests`

Expected: PASS.

Run: `swift test --filter ArchiveEditSessionTests`

Expected: all selected tests pass.

Run: `swift test --filter ZwzGUITests`

Expected: all GUI tests pass.

- [ ] **Step 5: Build, package, and manually verify**

Run: `swift build -c release`

Expected: exit code 0.

Run: `./scripts/package-app.sh`

Expected: refreshed `dist/ZwZ.app` and `dist/ZwZ.dmg`.

Open an archive editor, single-click several rows, verify highlight and toolbar enablement, then double-click a directory and verify navigation still works.
