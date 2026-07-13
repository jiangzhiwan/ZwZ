import Foundation
import SWCompression
import XCTest
import ZIPFoundation
@testable import ZwzCore

final class ArchiveEntryPreviewExtractionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveEntryPreviewExtractionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testZipRequiresAnExactEntryAndCleansTemporaryRootAfterMaliciousSuffixNearMatch() throws {
        let outsideName = "preview-outside-\(UUID().uuidString)/report.txt"
        let maliciousPath = "../../\(outsideName)"
        let archiveURL = root.appendingPathComponent("malicious.zip")
        try makeZip(at: archiveURL, entries: [(maliciousPath, .file, Data("malicious".utf8))])

        let rootsBefore = extractionRoots()
        XCTAssertThrowsError(try ArchiveExtractor().extractEntryToTemp(
            archivePath: archiveURL.path,
            entryPath: "report.txt"
        ))

        XCTAssertEqual(extractionRoots(), rootsBefore)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("zwz-drag-placeholder")
                .appendingPathComponent(maliciousPath)
                .standardizedFileURL.path
        ))
    }

    func testZipRejectsDuplicateExactEntriesAndCleansTemporaryRoot() throws {
        let archiveURL = root.appendingPathComponent("duplicate.zip")
        try makeZip(at: archiveURL, entries: [
            ("report.txt", .file, Data("first".utf8)),
            ("report.txt", .file, Data("second".utf8)),
        ])
        let rootsBefore = extractionRoots()

        XCTAssertThrowsError(try ArchiveExtractor().extractEntryToTemp(
            archivePath: archiveURL.path,
            entryPath: "report.txt"
        ))
        XCTAssertEqual(extractionRoots(), rootsBefore)
    }

    func testZipRejectsSymlinkEntryAndCleansTemporaryRoot() throws {
        let archiveURL = root.appendingPathComponent("symlink.zip")
        try makeZip(at: archiveURL, entries: [
            ("report.txt", .symlink, Data("../../outside.txt".utf8)),
        ])
        let rootsBefore = extractionRoots()

        XCTAssertThrowsError(try ArchiveExtractor().extractEntryToTemp(
            archivePath: archiveURL.path,
            entryPath: "report.txt"
        ))
        XCTAssertEqual(extractionRoots(), rootsBefore)
    }

    func testTarRequiresUniqueExactEntryAndRejectsSymlink() throws {
        let suffixArchive = root.appendingPathComponent("suffix.tar.gz")
        try makeTarGz(at: suffixArchive, entries: [
            TarEntry(info: TarEntryInfo(name: "nested/report.txt", type: .regular), data: Data("nested".utf8)),
        ])
        XCTAssertThrowsError(try ArchiveExtractor().extractEntryToTemp(
            archivePath: suffixArchive.path,
            entryPath: "report.txt"
        ))

        let duplicateArchive = root.appendingPathComponent("duplicate.tar.gz")
        try makeTarGz(at: duplicateArchive, entries: [
            TarEntry(info: TarEntryInfo(name: "report.txt", type: .regular), data: Data("one".utf8)),
            TarEntry(info: TarEntryInfo(name: "report.txt", type: .regular), data: Data("two".utf8)),
        ])
        XCTAssertThrowsError(try ArchiveExtractor().extractEntryToTemp(
            archivePath: duplicateArchive.path,
            entryPath: "report.txt"
        ))

        let symlinkArchive = root.appendingPathComponent("symlink.tar.gz")
        var linkInfo = TarEntryInfo(name: "report.txt", type: .symbolicLink)
        linkInfo.linkName = "../../outside.txt"
        try makeTarGz(at: symlinkArchive, entries: [TarEntry(info: linkInfo, data: Data())])
        XCTAssertThrowsError(try ArchiveExtractor().extractEntryToTemp(
            archivePath: symlinkArchive.path,
            entryPath: "report.txt"
        ))
    }

    func testTarRejectsRootEntryThatCouldBeParsedAsAToolOption() throws {
        let archiveURL = root.appendingPathComponent("option.tar.gz")
        try makeTarGz(at: archiveURL, entries: [
            TarEntry(
                info: TarEntryInfo(name: "--checkpoint-action=exec=ignored", type: .regular),
                data: Data("content".utf8)
            ),
        ])
        let rootsBefore = extractionRoots()

        XCTAssertThrowsError(try ArchiveExtractor().extractEntryToTemp(
            archivePath: archiveURL.path,
            entryPath: "--checkpoint-action=exec=ignored"
        ))
        XCTAssertEqual(extractionRoots(), rootsBefore)
    }

    func testSingleEntryExtractionHonorsInclusiveByteLimitAndCleansOnOverflow() throws {
        let archiveURL = root.appendingPathComponent("budget.zip")
        try makeZip(at: archiveURL, entries: [("report.txt", .file, Data("12345".utf8))])

        let exactURL = try ArchiveExtractor().extractEntryToTemp(
            archivePath: archiveURL.path,
            entryPath: "report.txt",
            maximumBytes: 5
        )
        XCTAssertEqual(try Data(contentsOf: exactURL), Data("12345".utf8))
        try FileManager.default.removeItem(at: exactURL.deletingLastPathComponent())

        let rootsBefore = extractionRoots()
        XCTAssertThrowsError(try ArchiveExtractor().extractEntryToTemp(
            archivePath: archiveURL.path,
            entryPath: "report.txt",
            maximumBytes: 4
        ))
        XCTAssertEqual(extractionRoots(), rootsBefore)
    }

    func testSingleEntryExtractionChecksCancellationAndCleansTemporaryRoot() throws {
        let archiveURL = root.appendingPathComponent("cancel.zip")
        try makeZip(at: archiveURL, entries: [("report.txt", .file, Data("content".utf8))])
        let token = CancellationToken()
        token.cancel()
        let rootsBefore = extractionRoots()

        XCTAssertThrowsError(try ArchiveExtractor().extractEntryToTemp(
            archivePath: archiveURL.path,
            entryPath: "report.txt",
            maximumBytes: 100,
            cancellationToken: token
        )) { error in
            guard let zwzError = error as? ZwzError,
                  case .operationCancelled = zwzError else {
                return XCTFail("Expected operationCancelled, got \(error)")
            }
        }
        XCTAssertEqual(extractionRoots(), rootsBefore)
    }

    private func makeZip(
        at url: URL,
        entries: [(path: String, type: ZIPFoundation.Entry.EntryType, data: Data)]
    ) throws {
        let archive = try ZIPFoundation.Archive(url: url, accessMode: .create)
        for item in entries {
            try archive.addEntry(
                with: item.path,
                type: item.type,
                uncompressedSize: Int64(item.data.count),
                provider: { position, size in
                    let start = Int(position)
                    return item.data.subdata(in: start..<min(start + size, item.data.count))
                }
            )
        }
    }

    private func makeTarGz(at url: URL, entries: [TarEntry]) throws {
        let tar = TarContainer.create(from: entries)
        try GzipArchive.archive(data: tar).write(to: url)
    }

    private func extractionRoots() -> Set<String> {
        let prefixes = ["zwz-drag-", "zwz-entry-", "zwz-v3-entry-"]
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )) ?? []
        return Set(names.filter { name in prefixes.contains(where: name.hasPrefix) })
    }
}
