# Archive Editor Row Selection Design

## Problem

Archive-editor rows attach a custom double-click gesture but do not explicitly update `selectedPath` on a single click. The custom gesture suppresses the list's implicit selection behavior, leaving rows without selection highlighting and keeping Rename, Replace, and Delete disabled.

## Approved Design

- Follow the already-working archive preview list pattern: a single click explicitly assigns `entry.path` to `selectedPath`.
- Preserve the existing double-click behavior for opening directories and editable files.
- Preserve selection clearing when navigating breadcrumbs or deleting an entry, so toolbar actions cannot target a stale path.
- Do not alter list contents, row appearance, toolbar actions, archive editing behavior, or window dimensions.

## Verification

- Add a focused GUI layout/interaction contract test requiring both single-click selection and double-click opening on editor rows.
- Run editor-related and complete GUI tests, build Release, repackage, and manually verify row highlight plus toolbar enablement.

## Constraints

- No archive-format, CLI, dependency, package, or deployment-target changes.
- No Git commit, branch, or staging operation.

