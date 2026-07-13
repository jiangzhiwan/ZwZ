# Reset Tab After Successful Compression Design

## Problem

After a file or folder is compressed successfully, its source path and completed state remain in the current workspace tab. The tab title therefore continues to show the source/archive name, and dropping another item is treated as opening into an occupied tab, which triggers the replace-or-new-tab prompt.

## Approved Behavior

- After compression succeeds, preserve the success entry in the global history and then restore that same tab to a fresh empty state.
- Keep the tab identity, position, and selection unchanged.
- The restored tab title is the localized default “new tab” title and it accepts the next dropped/opened item without a replacement prompt.
- Do not reset the tab after compression failure, cancellation, or a protected-operation recovery request; those states retain the source and error/configuration needed to retry.

## Architecture

`ArchiveViewModel` exposes an internal main-actor success callback and invokes it only after a compression result has been accepted for the current operation generation and the history entry has been appended. `WorkspaceTab` owns the reset response: it clears its view model through the existing complete reset path and changes its kind to `.empty`. `WorkspaceViewModel` attaches a persistence callback to every created or restored tab so the empty state is saved immediately.

Operation-generation checks remain the authority for rejecting stale asynchronous callbacks. Resetting the view model invalidates the completed generation, preventing late progress updates from repopulating the tab.

## Verification

- A successful compression invokes the callback after history is recorded.
- A failed compression does not invoke the callback and retains its source.
- A workspace tab receiving the success event keeps its ID but becomes empty, uses the default title, and accepts the next URL without creating a pending replacement decision.
- Existing GUI tests, release build, packaging, and manual drag/compress/drop verification pass.

## Constraints

- No archive, compression, CLI, dependency, package, or deployment-target changes.
- No Git commit, branch, or staging operation.

