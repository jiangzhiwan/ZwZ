# Encrypted Archive Preview Password Design

## Goal

When an encrypted archive is dragged into or opened by ZwZ, automatically present a password prompt and retry previewing the archive instead of showing only a password-required error page.

## Root Cause

The current preview path always calls `ArchivePreviewer.preview(archivePath:)` without a password. `ArchiveViewModel.performPreview(path:)` converts the resulting password error directly into `errorMessage`, and no state exists for requesting a preview password. `ArchivePreviewer` also cannot forward a password to the ZWZ index reader.

## Supported Flow

1. The user drags or opens an archive.
2. ZwZ detects the archive format and starts previewing it without a password.
3. If preview succeeds, the existing file list appears unchanged.
4. If the error represents a required or incorrect password, ZwZ opens a dedicated preview-password sheet instead of the generic error view.
5. The user enters a password and chooses “预览” / “Preview”.
6. ZwZ immediately dismisses the sheet, keeps the reading indicator visible, and retries previewing the same archive with that password.
7. On success, ZwZ stores the password for subsequent entry opening, dragging, mounting, and extraction, then displays the archive contents without reopening the sheet.
8. On another password failure, ZwZ stops the reading state, clears the rejected password, reopens the sheet, and displays a localized inline error so the user can retry.
9. Canceling clears the pending password state and returns to the initial drop interface.

## View-Model State

Add published state for:

- Whether the preview-password sheet is presented.
- An inline password-prompt error message.
- Whether a password retry is currently in progress, reusing the existing processing state where practical.

The existing `password` property holds the candidate password and, after success, the accepted password. `sourcePath`, `archiveName`, and `detectedFormat` continue to identify the pending archive.

Password-related errors must be classified separately from other preview failures. Non-password errors continue to use the existing generic error view.

## Password Submission Ordering

Submitting a non-empty password must synchronously dismiss the password sheet before the background preview retry starts. The flow has three possible stages:

1. Clear any previous inline error, set the password-sheet presentation state to false, and start the reading state.
2. On success, derive `previewEntries`, finish processing, and display the archive contents.
3. On password failure, finish processing, clear the rejected password, restore the inline error, and present a fresh password sheet.

The Preview button and Return-key submission are enabled whenever the trimmed password is non-empty. They do not depend on a stale global processing value because the sheet is absent while processing. This guarantees every re-presented prompt can submit a second or later attempt.

## Preview API

Extend `ArchivePreviewer.preview` with an optional password parameter whose default is `nil`, preserving existing callers. Forward it to `ZwzExtractor.listEntries` for ZWZ archives. Formats whose index listing does not use a password continue their existing behavior.

`ArchiveViewModel.performPreview` accepts or reads the current password and distinguishes an initial automatic preview from a retry. A dedicated retry action validates that the password is non-empty, dismisses the prompt, and launches preview.

## Interface

Add a compact SwiftUI sheet presented from `ContentView` containing:

- A lock icon and localized “需要密码” / “Password Required” title.
- The archive name.
- A secure password field focused for immediate typing.
- A localized inline wrong-password message when a retry fails.
- Cancel and Preview buttons.
- A disabled Preview button only when the trimmed password is empty.

## Password Reuse

After successful preview, pass the accepted password to `extractEntryForDrag`, file opening through that method, virtual-disk mounting, and the existing extraction options. Clearing the preview or selecting another archive clears the password.

## Testing

Use test seams around preview result handling so GUI tests can verify the state transition without expensive encrypted-archive generation for every case. Add tests for:

- A password-related initial preview error opens the password sheet and does not set the generic error page.
- A non-password preview error still uses the generic error page.
- A failed password retry reopens the sheet, clears the rejected password, and exposes an inline error.
- A successful retry closes the sheet, clears its inline error, and displays entries.
- Submitting a non-empty password dismisses the sheet before preview work begins.
- A second attempt becomes enabled after the user enters a replacement password.
- Cancel clears password and pending archive preview state.
- Entry extraction receives the accepted password.
- `ArchivePreviewer` can preview an encrypted ZWZ archive with the correct password and rejects a missing password.

Run focused GUI and core tests, build the GUI target, then run the complete available test suite with any pre-existing long-running limitation reported accurately.

## Success Criteria

- Dragging or opening an encrypted ZWZ archive automatically presents a usable password input window.
- A correct password reveals archive contents without requiring the user to restart the operation.
- An incorrect password can be retried in place.
- Accepted passwords are reused for subsequent operations on that preview.
- Unencrypted archives and non-password preview errors retain their current behavior.
