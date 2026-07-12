# Encrypted Archive Preview Password Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prompt for a password when encrypted archive preview requires one, retry in place, and reuse the accepted password for subsequent archive actions.

**Architecture:** `ArchivePreviewer` gains an optional password parameter and forwards it to the ZWZ index reader. `ArchiveViewModel` owns a small preview-password state machine and exposes deterministic result handlers for unit tests. `ContentView` presents a dedicated password sheet bound to that state.

**Tech Stack:** Swift 6.3, SwiftUI, XCTest, ZwzCore, Swift Package Manager

## Global Constraints

- Password failures show a password sheet, not the generic error page.
- Wrong passwords can be retried without reopening the archive.
- Non-password preview failures retain the generic error behavior.
- Accepted passwords are reused for entry extraction, opening, mounting, and full extraction.
- Canceling returns to the initial drop interface and clears sensitive state.

---

### Task 1: Password-Aware Preview API

**Files:**
- Modify: `Sources/ZwzCore/ArchivePreviewer.swift`
- Test: `Tests/ZwzCoreTests/ZWZV2/ZwzV2ExtractorTests.swift`

- [ ] Add a failing encrypted-preview test exercising `ArchivePreviewer.preview(archivePath:password:)`.
- [ ] Run the focused core test and verify it fails because the API does not accept a password.
- [ ] Add `password: String? = nil` to `ArchivePreviewer.preview` and forward it to `ZwzExtractor.listEntries` for `.zwz`.
- [ ] Run the focused test and verify it passes.

### Task 2: Preview Password State Machine

**Files:**
- Modify: `Sources/ZwzGUI/ArchiveViewModel.swift`
- Create: `Tests/ZwzGUITests/ArchivePreviewPasswordTests.swift`

- [ ] Add failing tests for initial password failure, retry failure, success, non-password failure, and cancel cleanup.
- [ ] Verify the focused GUI tests fail on missing password-prompt state and handlers.
- [ ] Add published prompt state, password-error state, password-error classification, success/failure handlers, retry action, and cancel action.
- [ ] Make `performPreview` pass the current password and distinguish initial attempt from retry.
- [ ] Pass the accepted password to `extractEntryForDrag`.
- [ ] Run focused GUI tests and verify they pass.

### Task 3: Password Prompt Interface and Localization

**Files:**
- Modify: `Sources/ZwzGUI/ZwzApp.swift`
- Modify: `Sources/ZwzGUI/Localization.swift`
- Test: `Tests/ZwzGUITests/ArchivePreviewPasswordTests.swift`

- [ ] Add failing assertions for the Simplified Chinese and English password-prompt strings.
- [ ] Verify the localization test fails with key fallbacks.
- [ ] Add localized title, preview action, and wrong-password copy.
- [ ] Add a dedicated SwiftUI password sheet with archive name, secure field, inline error, cancel/retry buttons, focus, and disabled loading/empty states.
- [ ] Run focused GUI tests and build `ZwzGUI`.

### Task 4: Regression Verification

**Files:**
- Verify all files changed in Tasks 1-3.

- [ ] Run all GUI tests.
- [ ] Run focused encrypted ZWZ preview tests.
- [ ] Build the GUI target.
- [ ] Inspect changed files for debug output, placeholders, trailing whitespace, and unrelated edits.
- [ ] Run the complete test suite; if the pre-existing core-suite stall recurs, report it accurately without claiming full-suite success.

### Task 5: Immediate Password-Sheet Dismissal

**Files:**
- Modify: `Sources/ZwzGUI/ArchiveViewModel.swift`
- Modify: `Tests/ZwzGUITests/ArchivePreviewPasswordTests.swift`

- [ ] Add an async failing test proving a successful password retry dismisses the sheet synchronously while keeping processing active and defers entry projection until the next main-thread turn.
- [ ] Run the focused test and verify it fails because the current success handler projects entries before dismissal.
- [ ] Add a password-verified success handler that clears the prompt state immediately and schedules the existing entry projection handler on the next main-thread turn.
- [ ] Route only successful password retries through the deferred handler; initial unencrypted previews keep the direct success path.
- [ ] Run the focused password tests, all GUI tests, and build `ZwzGUI`.

### Task 6: Submit-Time Dismissal and Repeatable Retry

**Files:**
- Modify: `Sources/ZwzGUI/ArchiveViewModel.swift`
- Modify: `Sources/ZwzGUI/ZwzApp.swift`
- Modify: `Tests/ZwzGUITests/ArchivePreviewPasswordTests.swift`

- [ ] Replace the previous success-time ordering test with failing tests proving submission immediately dismisses the prompt and a failed retry clears the rejected password before reopening it.
- [ ] Add a failing test for `canSubmitPreviewPassword`: false for empty/whitespace and true after entering a replacement password, independent of stale processing state.
- [ ] Run focused tests and verify the expected state assertions fail.
- [ ] Move prompt dismissal and inline-error clearing into `retryPreviewWithPassword`, remove the deferred success handler, and route all successes through the normal success handler.
- [ ] On retry password failure, clear `password`, finish processing, set the inline error, and reopen the prompt.
- [ ] Bind both Return submission and the Preview button to `canSubmitPreviewPassword`; remove `isProcessing` from the button disabled condition.
- [ ] Run focused password tests, all GUI tests, and build `ZwzGUI`.
