import XCTest
@testable import ZwzCore

final class ArchiveEntryPresentationTests: XCTestCase {
    func testDirectorySizeSumsDescendantFiles() {
        let entries = [
            ArchiveEntry(name: "Docs", path: "Docs/", size: 0, isDirectory: true, modifiedDate: nil),
            ArchiveEntry(name: "a.pdf", path: "Docs/a.pdf", size: 1_500, isDirectory: false, modifiedDate: nil),
            ArchiveEntry(name: "b.png", path: "Docs/Images/b.png", size: 2_500, isDirectory: false, modifiedDate: nil),
            ArchiveEntry(name: "root.zip", path: "root.zip", size: 9_000, isDirectory: false, modifiedDate: nil),
        ]

        XCTAssertEqual(ArchiveEntryPresentation.displaySize(for: entries[0], in: entries), 4_000)
    }

    func testArchiveEntryConversionSumsOnlyExactDirectoryDescendants() {
        let date = Date(timeIntervalSince1970: 1_000)
        let entries = [
            ZwzV2Entry(path: "A", type: .directory, originalSize: 0, modificationTime: date, isHidden: false, blocks: []),
            ZwzV2Entry(path: "A/B", type: .directory, originalSize: 0, modificationTime: date, isHidden: false, blocks: []),
            ZwzV2Entry(path: "AB", type: .directory, originalSize: 0, modificationTime: date, isHidden: false, blocks: []),
            ZwzV2Entry(path: "A/root.bin", type: .file, originalSize: 10, modificationTime: date, isHidden: false, blocks: []),
            ZwzV2Entry(path: "A/B/deep.bin", type: .file, originalSize: 20, modificationTime: date, isHidden: false, blocks: []),
            ZwzV2Entry(path: "AB/other.bin", type: .file, originalSize: 40, modificationTime: date, isHidden: false, blocks: []),
        ]

        let converted = ZwzExtractor.archiveEntries(from: entries)
        XCTAssertEqual(converted.first { $0.path == "A" }?.size, 30)
        XCTAssertEqual(converted.first { $0.path == "A/B" }?.size, 20)
        XCTAssertEqual(converted.first { $0.path == "AB" }?.size, 40)
    }

    func testPreviewIconNamesReflectFileType() {
        XCTAssertEqual(ArchiveEntryPresentation.iconName(forFileNamed: "photo.jpeg", isDirectory: false), "photo.fill")
        XCTAssertEqual(ArchiveEntryPresentation.iconName(forFileNamed: "notes.txt", isDirectory: false), "doc.text.fill")
        XCTAssertEqual(ArchiveEntryPresentation.iconName(forFileNamed: "archive.7z", isDirectory: false), "doc.zipper")
        XCTAssertEqual(ArchiveEntryPresentation.iconName(forFileNamed: "Folder", isDirectory: true), "folder.fill")
    }

    func testHiddenEntriesAreDetectedFromAnyPathComponent() {
        XCTAssertTrue(ArchiveEntryPresentation.isHidden(path: ".env"))
        XCTAssertTrue(ArchiveEntryPresentation.isHidden(path: "Project/.git/config"))
        XCTAssertTrue(ArchiveEntryPresentation.isHidden(path: "./Project/.DS_Store"))
        XCTAssertFalse(ArchiveEntryPresentation.isHidden(path: "Project/visible.txt"))
    }
}
