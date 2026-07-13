# Archive Editor Save Deadlock Design

## Root Cause

The editor presenter starts `NSApp.runModal(for:)` inside a block executing on the main dispatch queue. That block cannot return until the editor closes. Archive saving finishes on a background queue, but its success or failure cleanup is dispatched to the main queue, which cannot drain while the modal block remains active. Process sampling confirmed the app was idle with no save/compression worker and the main thread nested inside `runModal`.

## Approved Design

- Keep the editor as the same independent titled, closable, movable 720×540 window.
- Remove the blocking application-modal loop and show the window non-blockingly.
- Preserve close prevention while saving and the confirmation before discarding unsaved edits.
- Preserve success cleanup: clear the saving overlay, discard the temporary editing session, mark edits clean, close the editor, and refresh archive preview.
- Preserve failure cleanup: clear the saving overlay, keep the editor and edits open, and show the error.

## Verification

- Add a presenter regression test proving a main-queue callback executes while the editor remains visible.
- Retain presenter creation, positioning, and dismissal tests.
- Run save success/failure tests, the complete GUI suite, Release build, packaging, and manual save verification.

## Constraints

- No editor visual, archive-format, CLI, dependency, package, or deployment-target changes.
- No Git commit, branch, or staging operation.

