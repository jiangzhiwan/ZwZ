# Compression Options Alignment Design

## Problem

The compression-options sheet centers each `ZWZSheetSection` at its intrinsic width. Sections whose controls do not expand therefore start at different horizontal positions. The segmented pickers also render their own labels, duplicating the section headings and making the misalignment more obvious.

## Approved Design

- Make every `ZWZSheetSection` occupy the full available width while retaining leading alignment.
- Hide the built-in labels for the output-format, compression-level, and encryption segmented pickers. The existing section headings remain the accessible visible labels.
- Keep the sheet dimensions, spacing, typography, colors, choices, bindings, and compression behavior unchanged.
- Apply the section-width rule through the shared `ZWZSheetSection` helper so password and public-key configurations follow the same alignment rule.

## Verification

- Add a focused GUI-source contract test that fails unless the shared section expands to full width and the three segmented pickers hide their duplicate labels.
- Run the focused GUI test suite and a release build.
- Repackage the app and repeat the compression-options manual check in Chinese; then continue the existing acceptance checklist one item at a time.

## Constraints

- No dependency, package, deployment-target, CLI, archive-format, or compression behavior changes.
- No Git commit, branch, or staging operation.

