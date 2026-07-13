# Narrower Preview Sidebar Design

## Goal

Reduce the archive entry preview sidebar's default expanded width from 200 px to 180 px so the preview occupies less horizontal space.

## Scope

- Change the default preview sidebar width to 180 px.
- Keep the existing adjustable range of 180–260 px and its 20 px step.
- Keep the window expansion amount synchronized with the effective sidebar width.
- Preserve widths that users have explicitly saved in settings.

## Behavior

New/default configurations open the preview at 180 px. Existing saved width preferences remain unchanged. Preview content, selection behavior, closing behavior, and window restoration behavior are unaffected.

## Verification

- Add or update a focused test for the preview width defaults and limits.
- Run the relevant GUI test suite or package tests.
