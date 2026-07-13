import XCTest
@testable import ZwzCore

final class ZwzV2VolumeIOTests: XCTestCase {
    func testSplitWriterAndReaderRoundTripAcrossBoundaries() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = dir.appendingPathComponent("archive.zwz")
        let archiveID = UUID(uuidString: "99999999-2222-3333-4444-555555555555")!

        let writer = try ZwzV2VolumeWriter(outputURL: output, archiveID: archiveID, splitVolumeSize: 64)
        let offset = try writer.write(Data((0..<200).map { UInt8($0 % 251) }))
        let urls = try writer.finalize()
        let reader = try ZwzV2VolumeReader(urls: urls)

        XCTAssertEqual(offset, 0)
        XCTAssertEqual(try splitEnvelope(at: urls[0]).volumeNumber, 0)
        XCTAssertEqual(try reader.read(offset: 50, length: 100), Data((50..<150).map { UInt8($0 % 251) }))
    }

    func testReaderRejectsReorderedSplitVolumes() throws {
        let urls = try makeSplitArchive()

        XCTAssertMalformed(try ZwzV2VolumeReader(urls: [urls[1], urls[0], urls[2], urls[3]]), containing: "reordered")
    }

    func testReaderReportsMissingZeroBasedSplitVolume() throws {
        let urls = try makeSplitArchive()

        XCTAssertMissingVolume(try ZwzV2VolumeReader(urls: [urls[0], urls[2], urls[3]]), number: 1)
    }

    func testReaderRejectsDuplicateSplitVolume() throws {
        let urls = try makeSplitArchive()

        XCTAssertMalformed(try ZwzV2VolumeReader(urls: [urls[0], urls[0], urls[1], urls[2], urls[3]]), containing: "duplicate")
    }

    func testReaderRejectsSplitVolumesFromDifferentArchives() throws {
        let first = try makeSplitArchive()
        let second = try makeSplitArchive()

        XCTAssertMalformed(try ZwzV2VolumeReader(urls: [first[0], second[1]]), containing: "archive IDs")
    }

    func testReaderRejectsSplitVolumeWithInvalidChecksum() throws {
        let urls = try makeSplitArchive()
        var data = try Data(contentsOf: urls[0])
        data[ZwzV2SplitEnvelope.encodedLength] ^= 0xFF
        try data.write(to: urls[0])

        XCTAssertMalformed(try ZwzV2VolumeReader(urls: urls), containing: "checksum")
    }

    func testReaderRejectsUnexpectedFinalMarker() throws {
        let urls = try makeSplitArchive()
        try rewriteEnvelope(at: urls[0]) { $0.isFinal = true }

        XCTAssertMalformed(try ZwzV2VolumeReader(urls: urls), containing: "final-volume marker")
    }

    func testReaderRejectsNonContiguousLogicalRange() throws {
        let urls = try makeSplitArchive()
        try rewriteEnvelope(at: urls[1]) { $0.logicalOffset += 1 }

        XCTAssertMalformed(try ZwzV2VolumeReader(urls: urls), containing: "logical ranges")
    }

    func testSingleFileWriterAndReaderRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = dir.appendingPathComponent("archive.zwz")
        let data = Data([10, 20, 30, 40])

        let writer = try ZwzV2VolumeWriter(outputURL: output, archiveID: UUID())
        XCTAssertEqual(try writer.write(data), 0)
        XCTAssertEqual(try writer.finalize(), [output])

        let reader = try ZwzV2VolumeReader(urls: [output])
        XCTAssertEqual(try reader.read(offset: 1, length: 2), Data([20, 30]))
    }

    func testEmptySingleFileArchiveCanBeRead() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = dir.appendingPathComponent("archive.zwz")

        let writer = try ZwzV2VolumeWriter(outputURL: output, archiveID: UUID())
        XCTAssertEqual(try writer.finalize(), [output])

        let reader = try ZwzV2VolumeReader(urls: [output])
        XCTAssertEqual(try reader.read(offset: 0, length: 0), Data())
    }

    private func makeSplitArchive() throws -> [URL] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = dir.appendingPathComponent("archive.zwz")
        let writer = try ZwzV2VolumeWriter(outputURL: output, archiveID: UUID(), splitVolumeSize: 64)
        _ = try writer.write(Data((0..<200).map { UInt8($0 % 251) }))
        return try writer.finalize()
    }

    private func splitEnvelope(at url: URL) throws -> ZwzV2SplitEnvelope {
        try ZwzV2BinaryCodec.decodeSplitEnvelope(Data(contentsOf: url).prefix(ZwzV2SplitEnvelope.encodedLength))
    }

    private func rewriteEnvelope(at url: URL, mutate: (inout ZwzV2SplitEnvelope) -> Void) throws {
        var data = try Data(contentsOf: url)
        var envelope = try ZwzV2BinaryCodec.decodeSplitEnvelope(data.prefix(ZwzV2SplitEnvelope.encodedLength))
        mutate(&envelope)
        data.replaceSubrange(0..<ZwzV2SplitEnvelope.encodedLength, with: try ZwzV2BinaryCodec.encodeSplitEnvelope(envelope))
        try data.write(to: url)
    }

    private func XCTAssertMissingVolume<T>(_ expression: @autoclosure () throws -> T, number: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? ZwzV2Error, .missingVolume(number), file: file, line: line)
        }
    }

    private func XCTAssertMalformed<T>(_ expression: @autoclosure () throws -> T, containing message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case .malformedArchive(let reason) = error as? ZwzV2Error else {
                return XCTFail("Expected malformed archive error, got \\(error)", file: file, line: line)
            }
            XCTAssertTrue(reason.contains(message), "Expected '\\(reason)' to contain '\\(message)'", file: file, line: line)
        }
    }
}
