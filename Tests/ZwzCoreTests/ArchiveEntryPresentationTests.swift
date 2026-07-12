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
