import XCTest
@testable import ZwzCore

final class ZwzHiddenFilePreviewTests: XCTestCase {
    func testZwzPreviewIncludesHiddenFilesWrittenByCompressor() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("zwz-hidden-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source", isDirectory: true)
        let archive = root.appendingPathComponent("archive.zwz")
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: source.appendingPathComponent(".env"))
        try Data("visible".utf8).write(to: source.appendingPathComponent("visible.txt"))

        try ZwzCompressor().compress(
            sourcePath: source.path,
            destinationPath: archive.path,
            options: CompressionOptions(format: .zwz)
        )

        let entries = try ZwzExtractor().listEntries(archivePath: archive.path)
        let paths = Set(entries.map(\.path))

        XCTAssertTrue(paths.contains(".env"), "ZWZ paths: \(paths.sorted())")
        XCTAssertTrue(paths.contains("visible.txt"), "ZWZ paths: \(paths.sorted())")
    }

    func testZwzCompressionSkipsSymbolicLinksButKeepsHiddenFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("zwz-symlink-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source", isDirectory: true)
        let targetDirectory = source.appendingPathComponent("target", isDirectory: true)
        let symlink = source.appendingPathComponent("debug")
        let archive = root.appendingPathComponent("archive.zwz")
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: source.appendingPathComponent(".env"))
        try Data("target".utf8).write(to: targetDirectory.appendingPathComponent("file.txt"))
        try fm.createSymbolicLink(at: symlink, withDestinationURL: targetDirectory)

        try ZwzCompressor().compress(
            sourcePath: source.path,
            destinationPath: archive.path,
            options: CompressionOptions(format: .zwz)
        )

        let entries = try ZwzExtractor().listEntries(archivePath: archive.path)
        let paths = Set(entries.map(\.path))

        XCTAssertTrue(paths.contains(".env"), "ZWZ paths: \(paths.sorted())")
        XCTAssertTrue(paths.contains("target/file.txt"), "ZWZ paths: \(paths.sorted())")
        XCTAssertFalse(paths.contains("debug"), "ZWZ paths: \(paths.sorted())")
    }
}
