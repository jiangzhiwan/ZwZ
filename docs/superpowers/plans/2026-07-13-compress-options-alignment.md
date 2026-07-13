# Compression Options Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align all compression-options sections to one leading edge and remove duplicate picker labels without changing functionality.

**Architecture:** Keep the existing SwiftUI hierarchy. Put the width/alignment invariant in the shared `ZWZSheetSection` helper and hide only the redundant labels on the three segmented pickers.

**Tech Stack:** Swift 6.3, SwiftUI, XCTest, Swift Package Manager, macOS 15+

## Global Constraints

- Preserve sheet dimensions, spacing, typography, colors, choices, bindings, and compression behavior.
- Do not change dependencies, package resolution, or the macOS 15 minimum.
- Do not create commits, branches, or staged changes.

---

### Task 1: Lock and Repair Compression-Sheet Alignment

**Files:**
- Create: `Tests/ZwzGUITests/CompressionOptionsLayoutTests.swift`
- Modify: `Sources/ZwzGUI/ZwzApp.swift`

**Interfaces:**
- Consumes: `ZWZCompressOptionsView` and `ZWZSheetSection<Content>`.
- Produces: a full-width, leading-aligned shared section and label-hidden segmented pickers.

- [ ] **Step 1: Write the failing layout contract test**

Read `Sources/ZwzGUI/ZwzApp.swift` and assert that `ZWZSheetSection.body` ends with `.frame(maxWidth: .infinity, alignment: .leading)` and that the output-format, compression-level, and encryption pickers each apply `.labelsHidden()` before `.pickerStyle(.segmented)`.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter CompressionOptionsLayoutTests`

Expected: FAIL because the shared section does not expand and the three picker labels remain visible.

- [ ] **Step 3: Implement the minimal SwiftUI fix**

Add `.labelsHidden()` to the three segmented pickers in `ZWZCompressOptionsView`. Add `.frame(maxWidth: .infinity, alignment: .leading)` to the outer `VStack` returned by `ZWZSheetSection.body`.

- [ ] **Step 4: Verify GREEN and regressions**

Run: `swift test --filter CompressionOptionsLayoutTests`

Expected: PASS.

Run: `swift test --filter ZwzGUITests`

Expected: all GUI tests pass.

- [ ] **Step 5: Build, package, and manually verify**

Run: `swift build -c release`

Expected: exit code 0.

Run: `./scripts/package-app.sh`

Expected: refreshed `dist/ZwZ.app` and `dist/ZwZ.dmg`.

Open the packaged app and confirm the five section headings share the source-file leading edge and no segmented picker repeats its heading.
