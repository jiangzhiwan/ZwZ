import XCTest
@testable import ZwzCore

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class ZwzV2CompressorTests: XCTestCase {
    func testOrderedBlockWindowAppliesBackpressureWhenEarlierBlockIsMissing() throws {
        var window = ZwzV2OrderedBlockWindow<String>()

        XCTAssertEqual(window.insert("one", sequence: 1, nextSequenceToWrite: 0), [])
        XCTAssertTrue(window.shouldApplyBackpressure(inFlightCount: 1, maxInFlightBlocks: 2))

        XCTAssertEqual(window.insert("zero", sequence: 0, nextSequenceToWrite: 0), ["zero", "one"])
        XCTAssertFalse(window.shouldApplyBackpressure(inFlightCount: 0, maxInFlightBlocks: 2))
    }

    func testReportsIncrementalProgressForMultiBlockArchive() async throws {
        let fixture = try makeFixture()
        let blockSize = 16 * 1024
        try Data(repeating: 0x41, count: blockSize * 4)
            .write(to: fixture.root.appendingPathComponent("multi-block.bin"))
        let output = fixture.dir.appendingPathComponent("progress.zwz")
        let recorder = ProgressRecorder()

        _ = try await ZwzV2Compressor(
            options: ZwzV2Options(blockSize: blockSize, compressionLevel: .normal, threadCount: 2)
        ).compress(sourceURLs: [fixture.root], to: output) { value in
            recorder.append(value)
        }

        let values = recorder.values
        XCTAssertTrue(values.contains { $0 > 0 && $0 < 1 })
        XCTAssertEqual(values.last, 1.0)
    }

    func testCompressesHiddenFileAndWritesReadableEncryptedOrPlainIndex() async throws {
        let fixture = try makeFixture()
        let output = fixture.dir.appendingPathComponent("out.zwz")
        let compressor = ZwzV2Compressor(options: ZwzV2Options(blockSize: 32 * 1024, compressionLevel: .normal, threadCount: 2))

        let urls = try await compressor.compress(sourceURLs: [fixture.root], to: output)

        XCTAssertEqual(urls.count, 1)
        let archive = try Data(contentsOf: urls[0])
        let header = try ZwzV2BinaryCodec.decodeHeader(archive.prefix(ZwzV2Header.encodedLength))
        let footerStart = archive.count - ZwzV2Footer.encodedLength
        let footer = try ZwzV2BinaryCodec.decodeFooter(archive[footerStart..<archive.count])
        let indexStart = Int(footer.indexOffset)
        let indexEnd = indexStart + Int(footer.indexLength)
        let index = try ZwzV2IndexCodec.decodeFromArchive(
            payload: archive[indexStart..<indexEnd],
            tag: Data(),
            context: nil
        )

        XCTAssertEqual(header.archiveID, index.archiveID)
        XCTAssertTrue(index.entries.contains { $0.path == ".hidden.txt" && $0.isHidden })

        try assertBlockRecordBoundaries(index: index, reader: ZwzV2VolumeReader(urls: urls))
    }

    func testEncryptsBlockAndIndexWithTagsInTheArchiveStream() async throws {
        let fixture = try makeFixture()
        let output = fixture.dir.appendingPathComponent("encrypted.zwz")
        let options = ZwzV2Options(
            blockSize: 32 * 1024,
            compressionLevel: .normal,
            password: "secret",
            threadCount: 2
        )

        let urls = try await ZwzV2Compressor(options: options).compress(sourceURLs: [fixture.root], to: output)
        let archive = try Data(contentsOf: urls[0])
        let header = try ZwzV2BinaryCodec.decodeHeader(archive.prefix(ZwzV2Header.encodedLength))
        let footerStart = archive.count - ZwzV2Footer.encodedLength
        let footer = try ZwzV2BinaryCodec.decodeFooter(archive[footerStart..<archive.count])
        let context = try ZwzV2Crypto.deriveContext(
            password: "secret",
            salt: header.kdfSalt,
            iterations: header.kdfIterations,
            archiveID: header.archiveID
        )
        let indexStart = Int(footer.indexOffset)
        let indexEnd = indexStart + Int(footer.indexLength)
        let indexTagStart = indexEnd
        let indexTagEnd = indexTagStart + 16
        let index = try ZwzV2IndexCodec.decodeFromArchive(
            payload: archive[indexStart..<indexEnd],
            tag: archive[indexTagStart..<indexTagEnd],
            context: context
        )

        XCTAssertTrue(header.flags.contains(.encrypted))
        XCTAssertTrue(index.entries.flatMap(\.blocks).allSatisfy { $0.authenticationTag.count == 16 })
        XCTAssertTrue(index.entries.contains { $0.path == ".hidden.txt" && $0.isHidden })

        try assertBlockRecordBoundaries(index: index, reader: ZwzV2VolumeReader(urls: urls))
    }

    func testSplitArchiveHasReadableBlockRecordsAtDescriptorOffsets() async throws {
        let fixture = try makeFixture()
        try Data((0..<64_000).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
            .write(to: fixture.root.appendingPathComponent("random.bin"))
        let output = fixture.dir.appendingPathComponent("split.zwz")
        let options = ZwzV2Options(
            blockSize: 8 * 1024,
            compressionLevel: .normal,
            splitVolumeSize: 4 * 1024,
            threadCount: 2
        )

        let urls = try await ZwzV2Compressor(options: options).compress(sourceURLs: [fixture.root], to: output)
        XCTAssertGreaterThan(urls.count, 1)

        let reader = try ZwzV2VolumeReader(urls: urls)
        let footer = try ZwzV2BinaryCodec.decodeFooter(
            reader.read(offset: logicalLength(of: urls) - UInt64(ZwzV2Footer.encodedLength), length: ZwzV2Footer.encodedLength)
        )
        let index = try ZwzV2IndexCodec.decodeFromArchive(
            payload: reader.read(offset: footer.indexOffset, length: Int(footer.indexLength)),
            tag: Data(),
            context: nil
        )

        try assertBlockRecordBoundaries(index: index, reader: reader)
    }

    private func makeFixture() throws -> (dir: URL, root: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(String(repeating: "hello\n", count: 10_000).utf8).write(to: root.appendingPathComponent("visible.txt"))
        try Data("secret".utf8).write(to: root.appendingPathComponent(".hidden.txt"))
        return (dir, root)
    }

    private func assertBlockRecordBoundaries(index: ZwzV2Index, reader: ZwzV2VolumeReader) throws {
        for block in index.entries.flatMap(\.blocks) {
            let header = try ZwzV2BinaryCodec.decodeBlockRecordHeader(
                reader.read(offset: block.archiveOffset, length: ZwzV2BlockRecordHeader.encodedLength)
            )
            XCTAssertEqual(header.sequence, block.sequence)
            XCTAssertEqual(header.codec, block.codec)
            XCTAssertEqual(header.storedLength, block.storedLength)
            XCTAssertEqual(header.originalLength, block.originalLength)
            XCTAssertEqual(header.checksum, block.checksum)
            XCTAssertEqual(Int(header.tagLength), block.authenticationTag.count)

            let payloadOffset = block.archiveOffset + UInt64(ZwzV2BlockRecordHeader.encodedLength)
            XCTAssertEqual(try reader.read(offset: payloadOffset, length: Int(block.storedLength)).count, Int(block.storedLength))
            XCTAssertEqual(
                Array(try reader.read(offset: payloadOffset + UInt64(block.storedLength), length: block.authenticationTag.count)),
                block.authenticationTag
            )
        }
    }

    private func logicalLength(of urls: [URL]) throws -> UInt64 {
        var total: UInt64 = 0
        for url in urls {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let prefix = size >= 4 ? try Data(contentsOf: url, options: .mappedIfSafe).prefix(4) : Data()
            total += Array(prefix) == ZwzV2Format.splitMagic
                ? size - UInt64(ZwzV2SplitEnvelope.encodedLength)
                : size
        }
        return total
    }
}
