import XCTest
@testable import ZwzCore

final class ZwzV2ExtractorTests: XCTestCase {
    func testPreviewReadsIndexWithoutExtractingFiles() async throws {
        let fixture = try makeFixture()
        let archive = fixture.dir.appendingPathComponent("out.zwz")
        let urls = try await ZwzV2Compressor(options: ZwzV2Options(blockSize: 16 * 1024, threadCount: 2))
            .compress(sourceURLs: [fixture.root], to: archive)

        let index = try await ZwzV2Extractor(options: ZwzV2Options(threadCount: 2))
            .preview(archiveURLs: urls, password: nil)

        XCTAssertTrue(index.entries.contains { $0.path == "a.txt" })
        XCTAssertTrue(index.entries.contains { $0.path == ".hidden.txt" && $0.isHidden })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.dir.appendingPathComponent("extract").path))
    }

    func testExtractsSingleEntryWithoutExtractingUnrequestedSibling() async throws {
        let fixture = try makeFixture()
        let archive = fixture.dir.appendingPathComponent("out.zwz")
        let urls = try await ZwzV2Compressor(options: ZwzV2Options(blockSize: 16 * 1024, threadCount: 2))
            .compress(sourceURLs: [fixture.root], to: archive)
        let destination = fixture.dir.appendingPathComponent("extract")

        let report = try await ZwzV2Extractor(options: ZwzV2Options(threadCount: 2))
            .extractEntry(path: "a.txt", archiveURLs: urls, to: destination, password: nil)

        XCTAssertTrue(report.failedEntries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("a.txt")), try Data(contentsOf: fixture.root.appendingPathComponent("a.txt")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("b.txt").path))
    }

    func testSingleEntryBudgetRejectsBeforeCreatingOutput() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let archive = fixture.dir.appendingPathComponent("budget.zwz")
        let urls = try await ZwzV2Compressor(
            options: ZwzV2Options(blockSize: 16 * 1024, threadCount: 2)
        ).compress(sourceURLs: [fixture.root], to: archive)
        let destination = fixture.dir.appendingPathComponent("budget-output")

        do {
            _ = try await ZwzV2Extractor().extractEntry(
                path: "a.txt",
                archiveURLs: urls,
                to: destination,
                password: nil,
                maximumBytes: 99_999
            )
            XCTFail("Expected the declared entry size to exceed the preview budget")
        } catch {
            XCTAssertTrue(error is ZwzError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSingleEntryCancellationRejectsBeforeCreatingOutput() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let archive = fixture.dir.appendingPathComponent("cancel.zwz")
        let urls = try await ZwzV2Compressor(
            options: ZwzV2Options(blockSize: 16 * 1024, threadCount: 2)
        ).compress(sourceURLs: [fixture.root], to: archive)
        let destination = fixture.dir.appendingPathComponent("cancel-output")
        let token = CancellationToken()
        token.cancel()

        do {
            _ = try await ZwzV2Extractor().extractEntry(
                path: "a.txt",
                archiveURLs: urls,
                to: destination,
                password: nil,
                maximumBytes: 100_000,
                cancellationToken: token
            )
            XCTFail("Expected the cancelled preview extraction to stop")
        } catch let error as ZwzError {
            guard case .operationCancelled = error else {
                return XCTFail("Expected operationCancelled, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExtractAllRestoresDirectoriesHiddenFilesAndBytes() async throws {
        let fixture = try makeFixture()
        let archive = fixture.dir.appendingPathComponent("out.zwz")
        let urls = try await ZwzV2Compressor(options: ZwzV2Options(blockSize: 8 * 1024, threadCount: 2))
            .compress(sourceURLs: [fixture.root], to: archive)
        let destination = fixture.dir.appendingPathComponent("extract-all")

        let report = try await ZwzV2Extractor(options: ZwzV2Options(threadCount: 2))
            .extractAll(archiveURLs: urls, to: destination, password: nil)

        XCTAssertTrue(report.failedEntries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("a.txt")), try Data(contentsOf: fixture.root.appendingPathComponent("a.txt")))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("b.txt")), try Data(contentsOf: fixture.root.appendingPathComponent("b.txt")))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(".hidden.txt")), try Data(contentsOf: fixture.root.appendingPathComponent(".hidden.txt")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("folder").path))
    }

    func testEncryptedPreviewRequiresCorrectPassword() async throws {
        let fixture = try makeFixture()
        let archive = fixture.dir.appendingPathComponent("encrypted.zwz")
        let urls = try await ZwzV2Compressor(
            options: ZwzV2Options(blockSize: 16 * 1024, password: "secret", threadCount: 2)
        ).compress(sourceURLs: [fixture.root], to: archive)
        let extractor = ZwzV2Extractor(options: ZwzV2Options(threadCount: 2))

        do {
            _ = try await extractor.preview(archiveURLs: urls, password: nil)
            XCTFail("Preview should require a password for encrypted archives")
        } catch ZwzV2Error.wrongPasswordOrTamperedData {
        }

        let index = try await extractor.preview(archiveURLs: urls, password: "secret")
        XCTAssertTrue(index.entries.contains { $0.path == "a.txt" })
    }

    func testArchivePreviewerForwardsPasswordToEncryptedZwzIndex() async throws {
        let fixture = try makeFixture()
        let archive = fixture.dir.appendingPathComponent("previewer-encrypted.zwz")
        let urls = try await ZwzV2Compressor(
            options: ZwzV2Options(blockSize: 16 * 1024, password: "secret", threadCount: 2)
        ).compress(sourceURLs: [fixture.root], to: archive)

        let entries = try ArchivePreviewer().preview(archivePath: urls[0].path, password: "secret")

        XCTAssertTrue(entries.contains { $0.path == "a.txt" })
    }

    func testRejectsExtractionThroughExistingDestinationSymlink() async throws {
        let fixture = try makeFixture()
        try Data("escape".utf8).write(to: fixture.root.appendingPathComponent("folder/escape.txt"))
        let archive = fixture.dir.appendingPathComponent("out.zwz")
        let urls = try await ZwzV2Compressor(options: ZwzV2Options(blockSize: 16 * 1024, threadCount: 2))
            .compress(sourceURLs: [fixture.root], to: archive)
        let destination = fixture.dir.appendingPathComponent("extract")
        let outside = fixture.dir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("folder"),
            withDestinationURL: outside
        )

        do {
            _ = try await ZwzV2Extractor(options: ZwzV2Options(threadCount: 2))
                .extractEntry(path: "folder/escape.txt", archiveURLs: urls, to: destination, password: nil)
            XCTFail("Extraction should reject symlink components inside the destination")
        } catch ZwzV2Error.unsafePath {
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.txt").path))
    }

    func testRejectsIndexBlockLayoutThatWritesPastOriginalSize() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let archive = try writeArchiveWithInvalidBlockLayout(in: dir)
        let destination = dir.appendingPathComponent("extract")

        do {
            _ = try await ZwzV2Extractor().extractAll(archiveURLs: [archive], to: destination, password: nil)
            XCTFail("Extraction should reject sparse or oversized block layouts")
        } catch ZwzV2Error.malformedArchive {
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("bad.txt").path))
    }

    func testExtractingOverExistingLongerFileTruncatesStaleBytes() async throws {
        let fixture = try makeFixture()
        let archive = fixture.dir.appendingPathComponent("out.zwz")
        let urls = try await ZwzV2Compressor(options: ZwzV2Options(blockSize: 16 * 1024, threadCount: 2))
            .compress(sourceURLs: [fixture.root], to: archive)
        let destination = fixture.dir.appendingPathComponent("extract")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data(String(repeating: "stale", count: 100_000).utf8).write(to: destination.appendingPathComponent("a.txt"))

        _ = try await ZwzV2Extractor(options: ZwzV2Options(threadCount: 2))
            .extractEntry(path: "a.txt", archiveURLs: urls, to: destination, password: nil)

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("a.txt")),
            try Data(contentsOf: fixture.root.appendingPathComponent("a.txt"))
        )
    }

    private func makeFixture() throws -> (dir: URL, root: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data(String(repeating: "a", count: 100_000).utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data(String(repeating: "b", count: 100_000).utf8).write(to: root.appendingPathComponent("b.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden.txt"))
        return (dir, root)
    }

    private func writeArchiveWithInvalidBlockLayout(in dir: URL) throws -> URL {
        let archiveID = UUID()
        let source = Data("abc".utf8)
        let block = try ZwzV2BlockCodec.encode(source, level: .none)
        var archive = Data()
        archive.append(try ZwzV2BinaryCodec.encodeHeader(ZwzV2Header(
            archiveID: archiveID,
            flags: [],
            blockSize: 1_024,
            kdfSalt: Data(),
            kdfIterations: 0
        )))

        let blockOffset = UInt64(archive.count)
        archive.append(try ZwzV2BinaryCodec.encodeBlockRecordHeader(ZwzV2BlockRecordHeader(
            sequence: 0,
            codec: block.codec,
            storedLength: UInt32(block.payload.count),
            originalLength: UInt32(block.originalLength),
            checksum: block.checksum,
            tagLength: 0
        )))
        archive.append(block.payload)

        let index = ZwzV2Index(
            archiveID: archiveID,
            blockSize: 1_024,
            entries: [
                ZwzV2Entry(
                    path: "bad.txt",
                    type: .file,
                    originalSize: UInt64(source.count),
                    modificationTime: Date(timeIntervalSince1970: 0),
                    isHidden: false,
                    blocks: [
                        ZwzV2BlockDescriptor(
                            sequence: 0,
                            fileOffset: 100,
                            archiveOffset: blockOffset,
                            storedLength: UInt32(block.payload.count),
                            originalLength: UInt32(block.originalLength),
                            codec: block.codec,
                            checksum: block.checksum,
                            authenticationTag: []
                        )
                    ]
                )
            ]
        )
        let encodedIndex = try ZwzV2IndexCodec.encodeForArchive(index, context: nil)
        let indexOffset = UInt64(archive.count)
        archive.append(encodedIndex.payload)
        archive.append(try ZwzV2BinaryCodec.encodeFooter(ZwzV2Footer(
            archiveID: archiveID,
            indexOffset: indexOffset,
            indexLength: UInt64(encodedIndex.payload.count),
            indexChecksum: checksum(of: encodedIndex.payload)
        )))

        let url = dir.appendingPathComponent("bad.zwz")
        try archive.write(to: url)
        return url
    }

    private func checksum(of data: Data) -> UInt32 {
        var value: UInt32 = 2_166_136_261
        for byte in data {
            value ^= UInt32(byte)
            value &*= 16_777_619
        }
        return value
    }
}
