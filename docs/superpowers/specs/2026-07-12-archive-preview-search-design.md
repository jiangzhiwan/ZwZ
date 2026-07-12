# Archive Preview Search Design

## Goal

Add an inline search field to the archive preview interface so users can find files and directories anywhere in the currently opened archive without extracting it or leaving the preview.

## Scope

- Search the complete archive index, not only the currently displayed directory.
- Match both entry names and normalized full paths.
- Use case-insensitive substring matching.
- Include files and directories in results.
- Respect the existing **show hidden files** preference.
- Preserve the user's current directory while search is active and restore its listing when the query is cleared.
- Do not add content search, regular expressions, advanced filters, or a separate search window.

## Interface

Place a native SwiftUI search field in the archive preview navigation area, visually associated with the breadcrumb bar. Its placeholder is localized as “搜索压缩包内容” / “Search archive contents”.

When the field is empty, the interface behaves exactly as it does today: the breadcrumb identifies the current directory and the list shows that directory's immediate children.

When the field contains non-whitespace text:

- The list switches to flat global search results.
- Each row keeps the existing icon, name, full path, size, and modified date presentation.
- The footer reports the number and total size of matching results.
- Breadcrumb navigation remains visible but does not alter the active global result set.
- A clear control returns immediately to the preserved directory listing.

If there are no matches, show a centered empty state with a magnifying-glass icon and a localized “未找到匹配项目” / “No matching items” message instead of a blank list.

## Interaction

- Typing updates results immediately; no additional archive I/O occurs.
- Leading and trailing whitespace in the query is ignored.
- Matching is case-insensitive and checks both `entry.name` and the normalized archive path.
- Double-clicking a matched file extracts it to the existing temporary location and opens it with the system default application.
- Double-clicking a matched directory clears the query and navigates into that directory.
- Dragging a matched file continues to use the existing single-entry extraction behavior.
- Clearing or closing the archive resets the search query.
- Loading another archive starts with an empty query.

## Data Flow

`ArchiveViewModel` owns a published search query alongside the existing full archive entry collection. The existing filtering method becomes the single place that derives `previewEntries`:

1. Normalize and trim the query.
2. If non-empty, filter the full entry collection by name or path and apply hidden-file visibility.
3. If empty, retain the existing current-directory projection logic.

The view binds its search field directly to the query. Query changes trigger the same derivation method used by directory navigation and hidden-file toggling. Search results reuse `ArchiveEntry` values, so selection, sizing, opening, and dragging retain their existing behavior.

## Error and Empty States

Search is local over the already loaded archive index and introduces no new recoverable I/O errors. An empty result is a normal state, not an error. Existing archive preview and extraction error handling remains unchanged.

## Localization

Add localized keys for:

- Search field placeholder.
- No-results message.

Both Simplified Chinese and English dictionaries must be updated.

## Testing

Add GUI-target unit tests for the view-model filtering behavior before implementation. Tests cover:

- A file-name match from a directory other than the current directory.
- A parent-path match.
- Case-insensitive matching.
- Trimming surrounding query whitespace.
- Hidden entries excluded or included according to the existing preference.
- Clearing the query restores the preserved current-directory listing.
- A query with no match produces an empty result set.
- Entering a directory from a search result clears search and displays that directory.

Run the focused GUI tests first, then the complete Swift test suite.

## Success Criteria

- Users can find entries anywhere in a loaded archive by typing part of a name or path.
- Search updates without rereading or extracting the archive.
- Existing directory browsing behavior returns unchanged after clearing search.
- Existing open, drag, hidden-file, size, and localization behaviors continue to work.
- New focused tests and the complete test suite pass.
