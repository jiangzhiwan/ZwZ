import XCTest
import ZwzCore
import ZIPFoundation
@testable import ZwzGUI

final class ArchiveEditSessionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveEditSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testEditsAreSavedByReplacingZipArchive() throws {
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Docs"), withIntermediateDirectories: true)
        try Data("before".utf8).write(to: source.appendingPathComponent("Docs/readme.txt"))
        try Data("remove me".utf8).write(to: source.appendingPathComponent("remove.txt"))

        let archive = root.appendingPathComponent("archive.zip")
        try makeZip(from: source, at: archive)

        let addition = root.appendingPathComponent("added.c")
        try Data("int main(void) { return 0; }".utf8).write(to: addition)
        let session = try ArchiveEditSession.create(archiveURL: archive, password: nil)
        XCTAssertTrue(try session.entries().map(\.path).contains("remove.txt"))
        try session.writeText("after", to: "Docs/readme.txt")
        try session.rename(path: "Docs/readme.txt", to: "guide.txt")
        try session.delete(path: "remove.txt")
        try session.add(urls: [addition], into: "Docs")
        try session.save(password: nil)

        let entries = try ArchivePreviewer().preview(archivePath: archive.path).map(\.path)
        XCTAssertTrue(entries.contains("Docs/guide.txt"))
        XCTAssertTrue(entries.contains("Docs/added.c"))
        XCTAssertFalse(entries.contains("remove.txt"))

        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        try ArchiveExtractor().extract(archivePath: archive.path, destinationPath: extracted.path)
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("Docs/guide.txt")), "after")
    }

    func testEditSessionRejectsPathsOutsideWorkspace() throws {
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("body".utf8).write(to: source.appendingPathComponent("file.txt"))
        let archive = root.appendingPathComponent("archive.zip")
        try makeZip(from: source, at: archive)
        let session = try ArchiveEditSession.create(archiveURL: archive, password: nil)

        XCTAssertThrowsError(try session.delete(path: "../outside.txt"))
        XCTAssertThrowsError(try session.rename(path: "file.txt", to: "../outside.txt"))
        XCTAssertFalse(session.hasChanges)
    }

    func testSessionStartsCleanAndNoOpEditsRemainClean() throws {
        let archive = try makeSimpleArchive(named: "clean.zip", contents: "body")
        let session = try ArchiveEditSession.create(archiveURL: archive, password: nil)
        let identical = root.appendingPathComponent("file.txt")
        try Data("body".utf8).write(to: identical)

        _ = try session.entries()
        _ = try session.text(for: "file.txt")
        try session.writeText("body", to: "file.txt")
        try session.rename(path: "file.txt", to: "file.txt")
        try session.replace(path: "file.txt", with: identical)
        try session.add(urls: [identical], into: "")
        try session.add(urls: [], into: "New Folder")

        XCTAssertFalse(session.hasChanges)
    }

    func testSuccessfulMutationsMarkSessionAsChanged() throws {
        let textSession = try ArchiveEditSession.create(
            archiveURL: makeSimpleArchive(named: "text.zip", contents: "before"),
            password: nil
        )
        try textSession.writeText("after", to: "file.txt")
        XCTAssertTrue(textSession.hasChanges)

        let renameSession = try ArchiveEditSession.create(
            archiveURL: makeSimpleArchive(named: "rename.zip", contents: "body"),
            password: nil
        )
        try renameSession.rename(path: "file.txt", to: "renamed.txt")
        XCTAssertTrue(renameSession.hasChanges)

        let deleteSession = try ArchiveEditSession.create(
            archiveURL: makeSimpleArchive(named: "delete.zip", contents: "body"),
            password: nil
        )
        try deleteSession.delete(path: "file.txt")
        XCTAssertTrue(deleteSession.hasChanges)

        let replacement = root.appendingPathComponent("replacement.txt")
        try Data("replacement".utf8).write(to: replacement)
        let replaceSession = try ArchiveEditSession.create(
            archiveURL: makeSimpleArchive(named: "replace.zip", contents: "body"),
            password: nil
        )
        try replaceSession.replace(path: "file.txt", with: replacement)
        XCTAssertTrue(replaceSession.hasChanges)

        let addition = root.appendingPathComponent("added.txt")
        try Data("added".utf8).write(to: addition)
        let addSession = try ArchiveEditSession.create(
            archiveURL: makeSimpleArchive(named: "add.zip", contents: "body"),
            password: nil
        )
        try addSession.add(urls: [addition], into: "")
        XCTAssertTrue(addSession.hasChanges)
    }

    func testBatchRenameSupportsChainedDestinationsWithoutLosingFiles() throws {
        let source = root.appendingPathComponent("batch-chain-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("from-a".utf8).write(to: source.appendingPathComponent("A.txt"))
        try Data("from-b".utf8).write(to: source.appendingPathComponent("B.txt"))
        let archive = root.appendingPathComponent("batch-chain.zip")
        try makeZip(from: source, at: archive)
        let session = try ArchiveEditSession.create(archiveURL: archive, password: nil)

        try session.batchRename(items: [
            (sourcePath: "A.txt", newName: "B.txt"),
            (sourcePath: "B.txt", newName: "C.txt")
        ])

        XCTAssertEqual(try session.text(for: "B.txt"), "from-a")
        XCTAssertEqual(try session.text(for: "C.txt"), "from-b")
        XCTAssertTrue(session.hasChanges)
    }

    func testFailedReplacementKeepsOriginalAndDoesNotMarkSessionAsChanged() throws {
        let archive = try makeSimpleArchive(named: "failed-replace.zip", contents: "original")
        let session = try ArchiveEditSession.create(archiveURL: archive, password: nil)
        let missing = root.appendingPathComponent("missing.txt")

        XCTAssertThrowsError(try session.replace(path: "file.txt", with: missing))
        XCTAssertEqual(try session.text(for: "file.txt"), "original")
        XCTAssertFalse(session.hasChanges)
    }

    func testSavingChangesResetsSessionDirtyState() throws {
        let archive = try makeSimpleArchive(named: "save-reset.zip", contents: "before")
        let session = try ArchiveEditSession.create(archiveURL: archive, password: nil)
        try session.writeText("after", to: "file.txt")
        XCTAssertTrue(session.hasChanges)

        try session.save(password: nil)

        XCTAssertFalse(session.hasChanges)
    }

    private func makeSimpleArchive(named name: String, contents: String) throws -> URL {
        let source = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: source.appendingPathComponent("file.txt"))
        let archive = root.appendingPathComponent(name)
        try makeZip(from: source, at: archive)
        return archive
    }

    private func makeZip(from source: URL, at archiveURL: URL) throws {
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]))
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory != true else { continue }
            let rootPath = source.resolvingSymlinksInPath().path
            let itemPath = url.resolvingSymlinksInPath().path
            let relative = String(itemPath.dropFirst(rootPath.count + 1))
            _ = try archive.addEntry(with: relative, fileURL: url, compressionMethod: .deflate)
        }
    }
}
