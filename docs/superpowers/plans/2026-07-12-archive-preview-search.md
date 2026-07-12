# Archive Preview Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an inline, localized search field that finds files and directories anywhere in the loaded archive while preserving existing directory navigation.

**Architecture:** `ArchiveViewModel` remains the owner of the complete archive index and derives `previewEntries` from either the current directory or a normalized global query. `ZWZArchiveContentView` binds to the query and reuses existing rows and entry actions, adding only a search field and a no-results state.

**Tech Stack:** Swift 6.3, SwiftUI, Combine, XCTest, Swift Package Manager, macOS 15+

## Global Constraints

- Search the complete archive index, not only the currently displayed directory.
- Match names and normalized full paths with case-insensitive substring matching.
- Include files and directories and respect the existing hidden-file preference.
- Clearing search restores the preserved current-directory listing.
- Do not add content search, regular expressions, advanced filters, dependencies, or a separate search window.
- Keep Simplified Chinese and English UI strings in `Localization.swift`.

---

### Task 1: Global Archive Search Behavior

**Files:**
- Create: `Tests/ZwzGUITests/ArchiveViewModelSearchTests.swift`
- Modify: `Sources/ZwzGUI/ArchiveViewModel.swift:75-90, 190-210, 360-475`

**Interfaces:**
- Consumes: `[ArchiveEntry]`, `ArchiveEntryPresentation.isHidden(path:)`, existing `currentDir` and `showHiddenFiles` state.
- Produces: `@Published var searchQuery: String`, `var isSearching: Bool`, `func setArchiveEntries(_ entries: [ArchiveEntry])`, and search-aware `updateFilteredEntries()`.

- [ ] **Step 1: Write failing view-model tests**

Create `ArchiveViewModelSearchTests.swift` with `@MainActor` tests that construct entries at the root and in nested directories. Use `setArchiveEntries(_:)`, set `currentDir`, `showHiddenFiles`, and `searchQuery`, then assert:

```swift
XCTAssertEqual(viewModel.previewEntries.map(\.path), ["Docs/Report.PDF"])
XCTAssertEqual(viewModel.previewEntries.map(\.path), ["Docs/Report.PDF", "Docs/notes.txt"])
XCTAssertTrue(viewModel.previewEntries.isEmpty)
```

Cover file-name matching across directories, parent-path matching, case insensitivity, surrounding whitespace, hidden visibility, no results, clearing back to the prior directory, and entering a matched directory clearing the query.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter ArchiveViewModelSearchTests`

Expected: compilation fails because `searchQuery`, `isSearching`, and `setArchiveEntries(_:)` do not exist.

- [ ] **Step 3: Add minimal search state and archive-loading seam**

Add to `ArchiveViewModel`:

```swift
@Published var searchQuery = "" {
    didSet {
        selectedEntryId = nil
        updateFilteredEntries()
    }
}

var isSearching: Bool {
    !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

func setArchiveEntries(_ entries: [ArchiveEntry]) {
    allEntries = entries
    updateFilteredEntries()
}
```

Use `setArchiveEntries(_:)` when preview loading completes. Reset `searchQuery` in `performPreview(path:)` before asynchronous loading and in `clearPreview()`.

- [ ] **Step 4: Add global filtering before existing directory projection**

At the start of `updateFilteredEntries()`, trim the query. When non-empty, normalize each path by removing a leading `./`, apply the existing hidden-entry rule, and keep entries whose name or normalized path contains the query with `.caseInsensitive` comparison. Assign the flat matches to `previewEntries` and return. Leave the existing current-directory branches unchanged.

In `enterDirectory(_:)`, set `searchQuery = ""` before setting `currentDir` so a directory selected from global results opens normally.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run: `swift test --filter ArchiveViewModelSearchTests`

Expected: all `ArchiveViewModelSearchTests` pass with no failures.

---

### Task 2: Inline Search Interface and Localization

**Files:**
- Modify: `Sources/ZwzGUI/ZwzApp.swift:930-1080`
- Modify: `Sources/ZwzGUI/Localization.swift:20-105`
- Test: `Tests/ZwzGUITests/ArchiveViewModelSearchTests.swift`

**Interfaces:**
- Consumes: `ArchiveViewModel.searchQuery`, `ArchiveViewModel.isSearching`, `ArchiveViewModel.previewEntries`, and `L.string(_:)`.
- Produces: localized keys `search_archive_contents` and `no_search_results`; inline search field and empty-result presentation.

- [ ] **Step 1: Add failing localization assertions**

Extend `ArchiveViewModelSearchTests` with a main-actor test that switches `LanguageManager.shared` between `zh` and `en` and asserts exact localized values:

```swift
XCTAssertEqual(L.string("search_archive_contents"), "搜索压缩包内容")
XCTAssertEqual(L.string("no_search_results"), "未找到匹配项目")
XCTAssertEqual(L.string("search_archive_contents"), "Search archive contents")
XCTAssertEqual(L.string("no_search_results"), "No matching items")
```

Restore the original language with `defer`.

- [ ] **Step 2: Run the localization test and verify RED**

Run: `swift test --filter ArchiveViewModelSearchTests`

Expected: localization assertions fail because missing keys fall back to their key names.

- [ ] **Step 3: Add both localized string pairs**

Add to `L.zh` and `L.en`:

```swift
"search_archive_contents": "搜索压缩包内容",
"no_search_results": "未找到匹配项目",
```

```swift
"search_archive_contents": "Search archive contents",
"no_search_results": "No matching items",
```

- [ ] **Step 4: Add the native search field and empty state**

In the breadcrumb bar, keep breadcrumbs on the leading side and add a trailing `TextField` bound to `$viewModel.searchQuery`, with a magnifying-glass icon, rounded background, localized placeholder, and a clear button shown only when the query is non-empty. Constrain it to a practical width so breadcrumb navigation remains usable.

Replace the unconditional list with a conditional: when `viewModel.isSearching && viewModel.previewEntries.isEmpty`, show a centered magnifying-glass icon and `L.string("no_search_results")`; otherwise render the existing list unchanged.

- [ ] **Step 5: Run focused tests and build the GUI target**

Run: `swift test --filter ArchiveViewModelSearchTests`

Expected: all focused tests pass.

Run: `swift build --target ZwzGUI`

Expected: build completes successfully with no Swift compiler errors.

---

### Task 3: Regression Verification

**Files:**
- Verify all changed files from Tasks 1-2.

**Interfaces:**
- Consumes: completed search behavior and interface.
- Produces: evidence that the feature does not regress existing archive behavior.

- [ ] **Step 1: Run the complete test suite**

Run: `swift test`

Expected: all test targets pass with zero failures.

- [ ] **Step 2: Inspect the final diff**

Run: `git diff --check` when Git metadata is available; otherwise inspect changed files directly and confirm no trailing whitespace, debug output, placeholders, or unrelated edits.

- [ ] **Step 3: Record environment limitation**

If the workspace is still not recognized as a Git repository, do not attempt a commit. Report the changed files and verification output to the user.
