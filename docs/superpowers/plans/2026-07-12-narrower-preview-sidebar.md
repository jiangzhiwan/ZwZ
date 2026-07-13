# Narrower Preview Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the archive entry preview sidebar's default expanded width from 200 px to 180 px while preserving user-saved widths.

**Architecture:** Keep the existing single source of truth in `ArchiveEntryPreviewSettings`. The preview pane and window expansion already consume the effective setting, so changing the default constant updates both behaviors without duplicating layout values.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, Swift Package Manager

## Global Constraints

- The default preview sidebar width is 180 px.
- The adjustable range remains 180–260 px with a 20 px step.
- Existing explicitly saved width preferences remain unchanged.
- Preview content and interaction behavior remain unchanged.

---

### Task 1: Preview Sidebar Width Default

**Files:**
- Modify: `Tests/ZwzGUITests/ArchiveEntryPreviewSupportTests.swift`
- Modify: `Sources/ZwzGUI/ArchiveEntryPreviewSupport.swift`

**Interfaces:**
- Consumes: `ArchiveEntryPreviewSettings.defaultSidebarWidth`, `minimumSidebarWidth`, and `maximumSidebarWidth` as internal `Double` constants.
- Produces: A 180 px default consumed by `@AppStorage` and window expansion code already present in `ZWZArchiveContentView`.

- [ ] **Step 1: Write the failing test**

Add this test to `ArchiveEntryPreviewSupportTests`:

```swift
func testPreviewSidebarWidthDefaultsToNarrowestSupportedSize() {
    XCTAssertEqual(ArchiveEntryPreviewSettings.defaultSidebarWidth, 180.0)
    XCTAssertEqual(ArchiveEntryPreviewSettings.minimumSidebarWidth, 180.0)
    XCTAssertEqual(ArchiveEntryPreviewSettings.maximumSidebarWidth, 260.0)
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `swift test --filter ArchiveEntryPreviewSupportTests/testPreviewSidebarWidthDefaultsToNarrowestSupportedSize`

Expected: FAIL because `defaultSidebarWidth` is 200.0 rather than 180.0.

- [ ] **Step 3: Write the minimal implementation**

In `ArchiveEntryPreviewSettings`, change only the default:

```swift
static let defaultSidebarWidth = 180.0
```

- [ ] **Step 4: Run focused and full verification**

Run: `swift test --filter ArchiveEntryPreviewSupportTests/testPreviewSidebarWidthDefaultsToNarrowestSupportedSize`

Expected: PASS with zero failures.

Run: `swift test`

Expected: All test suites pass with zero failures.

- [ ] **Step 5: Review the diff**

Run: `git diff --check && git diff -- Tests/ZwzGUITests/ArchiveEntryPreviewSupportTests.swift Sources/ZwzGUI/ArchiveEntryPreviewSupport.swift`

Expected: No whitespace errors; the diff contains one focused test and the 200-to-180 default change only.
