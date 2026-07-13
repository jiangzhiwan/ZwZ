import XCTest
@testable import ZwzCore

final class ZwzV2PathTests: XCTestCase {
    func testRejectsTraversalAndAbsoluteExtractionPaths() throws {
        let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)

        XCTAssertThrowsError(try ZwzV2PathValidator.validateExtractionPath("../escape.txt", destination: destination))
        XCTAssertThrowsError(try ZwzV2PathValidator.validateExtractionPath("/tmp/escape.txt", destination: destination))
        XCTAssertThrowsError(try ZwzV2PathValidator.validateExtractionPath("safe/\u{0}bad.txt", destination: destination))
    }

    func testDetectsCaseInsensitiveDuplicatePaths() throws {
        let date = Date(timeIntervalSince1970: 1)
        let entries = [
            ZwzV2Entry(path: "Folder/File.txt", type: .file, originalSize: 1, modificationTime: date, isHidden: false, blocks: []),
            ZwzV2Entry(path: "folder/file.txt", type: .file, originalSize: 1, modificationTime: date, isHidden: false, blocks: [])
        ]

        XCTAssertThrowsError(try ZwzV2PathValidator.validateNoDuplicatePaths(entries))
    }

    func testRejectsFileAndDescendantPathConflict() throws {
        let date = Date(timeIntervalSince1970: 1)
        let entries = [
            ZwzV2Entry(path: "foo", type: .file, originalSize: 1, modificationTime: date, isHidden: false, blocks: []),
            ZwzV2Entry(path: "foo/bar", type: .file, originalSize: 1, modificationTime: date, isHidden: false, blocks: [])
        ]

        XCTAssertThrowsError(try ZwzV2PathValidator.validateNoDuplicatePaths(entries))
    }

    func testRejectsCaseInsensitiveFileAndDescendantPathConflict() throws {
        let date = Date(timeIntervalSince1970: 1)
        let entries = [
            ZwzV2Entry(path: "foo", type: .file, originalSize: 1, modificationTime: date, isHidden: false, blocks: []),
            ZwzV2Entry(path: "FOO/bar", type: .file, originalSize: 1, modificationTime: date, isHidden: false, blocks: [])
        ]

        XCTAssertThrowsError(try ZwzV2PathValidator.validateNoDuplicatePaths(entries))
    }

    func testNormalizesAPathInsideTheSourceRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/archive-root")
        let item = root.appendingPathComponent("Folder").appendingPathComponent("file.txt")

        XCTAssertEqual(
            try ZwzV2PathValidator.normalizedArchivePath(root: root, item: item),
            "Folder/file.txt"
        )
    }

    func testEnumeratesDirectoriesAndHiddenFilesInArchivePathOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try Data("visible".utf8).write(to: root.appendingPathComponent("visible.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"),
            withDestinationURL: root.appendingPathComponent("visible.txt")
        )

        let items = try ZwzV2SourceEnumerator().enumerate(root: root)

        XCTAssertEqual(items.map(\.archivePath), [".hidden.txt", "Folder", "visible.txt"])
        XCTAssertEqual(items.first?.isHidden, true)
        XCTAssertEqual(items[1].type, .directory)
        XCTAssertEqual(items[2].size, 7)
    }
}
