import XCTest
import ZwzCore
@testable import ZwzGUI

@MainActor
final class ArchiveViewModelSearchTests: XCTestCase {
    private func makeViewModel() -> ArchiveViewModel {
        let viewModel = ArchiveViewModel()
        viewModel.showHiddenFiles = false
        viewModel.currentDir = ""
        return viewModel
    }

    private var entries: [ArchiveEntry] {
        [
            ArchiveEntry(name: "Docs", path: "Docs/", size: 0, isDirectory: true, modifiedDate: nil),
            ArchiveEntry(name: "Report.PDF", path: "Docs/Report.PDF", size: 1_024, isDirectory: false, modifiedDate: nil),
            ArchiveEntry(name: "notes.txt", path: "Docs/notes.txt", size: 128, isDirectory: false, modifiedDate: nil),
            ArchiveEntry(name: "Images", path: "Images/", size: 0, isDirectory: true, modifiedDate: nil),
            ArchiveEntry(name: "report.png", path: "Images/report.png", size: 2_048, isDirectory: false, modifiedDate: nil),
            ArchiveEntry(name: ".env", path: "Project/.env", size: 32, isDirectory: false, modifiedDate: nil),
            ArchiveEntry(name: "readme.md", path: "Project/readme.md", size: 64, isDirectory: false, modifiedDate: nil),
        ]
    }

    func testSearchMatchesFileNameAcrossArchiveIgnoringCaseAndWhitespace() {
        let viewModel = makeViewModel()
        viewModel.currentDir = "Images/"
        viewModel.setArchiveEntries(entries)

        viewModel.searchQuery = "  REPORT.PDF  "

        XCTAssertEqual(viewModel.previewEntries.map(\.path), ["Docs/Report.PDF"])
        XCTAssertTrue(viewModel.isSearching)
    }

    func testSearchMatchesParentPath() {
        let viewModel = makeViewModel()
        viewModel.setArchiveEntries(entries)

        viewModel.searchQuery = "docs/"

        XCTAssertEqual(
            viewModel.previewEntries.map(\.path),
            ["Docs/", "Docs/Report.PDF", "Docs/notes.txt"]
        )
    }

    func testSearchRespectsHiddenFilePreference() {
        let viewModel = makeViewModel()
        viewModel.setArchiveEntries(entries)
        viewModel.searchQuery = "project"

        XCTAssertEqual(viewModel.previewEntries.map(\.path), ["Project/readme.md"])

        viewModel.showHiddenFiles = true

        XCTAssertEqual(viewModel.previewEntries.map(\.path), ["Project/.env", "Project/readme.md"])
    }

    func testSearchWithNoMatchProducesEmptyResults() {
        let viewModel = makeViewModel()
        viewModel.setArchiveEntries(entries)

        viewModel.searchQuery = "missing-item"

        XCTAssertTrue(viewModel.previewEntries.isEmpty)
    }

    func testDirectoryDisplaySizeCacheRefreshesWithArchiveEntries() {
        let viewModel = makeViewModel()
        let docs = entries[0]
        viewModel.setArchiveEntries(entries)
        XCTAssertEqual(viewModel.displaySize(for: docs), 1_152)

        viewModel.setArchiveEntries([docs])
        XCTAssertEqual(viewModel.displaySize(for: docs), 0)
    }

    func testClearingSearchRestoresPreservedDirectory() {
        let viewModel = makeViewModel()
        viewModel.currentDir = "Docs/"
        viewModel.setArchiveEntries(entries)
        viewModel.searchQuery = "report.png"

        viewModel.searchQuery = ""

        XCTAssertEqual(viewModel.currentDir, "Docs/")
        XCTAssertEqual(viewModel.previewEntries.map(\.path), ["Docs/Report.PDF", "Docs/notes.txt"])
        XCTAssertFalse(viewModel.isSearching)
    }

    func testEnteringMatchedDirectoryClearsSearchAndDisplaysDirectory() {
        let viewModel = makeViewModel()
        viewModel.setArchiveEntries(entries)
        viewModel.searchQuery = "docs"
        let docs = try! XCTUnwrap(viewModel.previewEntries.first(where: { $0.path == "Docs/" }))

        viewModel.enterDirectory(docs)

        XCTAssertEqual(viewModel.searchQuery, "")
        XCTAssertEqual(viewModel.currentDir, "Docs/")
        XCTAssertEqual(viewModel.previewEntries.map(\.path), ["Docs/Report.PDF", "Docs/notes.txt"])
    }

    func testSearchInterfaceStringsAreLocalized() {
        let languageManager = LanguageManager.shared
        let originalLanguage = languageManager.currentLanguage
        defer { languageManager.setLanguage(originalLanguage) }

        languageManager.setLanguage("zh")
        XCTAssertEqual(L.string("search_archive_contents"), "搜索压缩包内容")
        XCTAssertEqual(L.string("no_search_results"), "未找到匹配项目")
        XCTAssertEqual(L.string("preview_loading"), "正在准备预览…")
        XCTAssertEqual(L.string("preview_unsupported"), "暂不支持预览此文件类型")

        languageManager.setLanguage("en")
        XCTAssertEqual(L.string("search_archive_contents"), "Search archive contents")
        XCTAssertEqual(L.string("no_search_results"), "No matching items")
        XCTAssertEqual(L.string("preview_loading"), "Preparing preview…")
        XCTAssertEqual(L.string("preview_unsupported"), "This file type cannot be previewed")
    }
}
