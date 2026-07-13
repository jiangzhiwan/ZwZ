import Foundation
import XCTest
@testable import ZwzCore

final class ZwzV2BinaryCodecTests: XCTestCase {
    func testHeaderRoundTrip() throws {
        let header = ZwzV2Header(
            archiveID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            flags: [.encrypted],
            blockSize: 4 * 1024 * 1024,
            kdfSalt: Data([1, 2, 3, 4]),
            kdfIterations: 210_000
        )

        let data = try ZwzV2BinaryCodec.encodeHeader(header)
        XCTAssertEqual(data.count, ZwzV2Header.encodedLength)
        XCTAssertEqual(try ZwzV2BinaryCodec.decodeHeader(data), header)
    }

    func testOldV1HeaderIsRejectedAsUnsupported() {
        var bytes = Data(repeating: 0, count: ZwzV2Header.encodedLength)
        bytes.replaceSubrange(0..<4, with: Data([0x5A, 0x57, 0x5A, 0x31]))

        XCTAssertThrowsError(try ZwzV2BinaryCodec.decodeHeader(bytes)) { error in
            XCTAssertEqual(error as? ZwzV2Error, .unsupportedVersion(1))
        }
    }

    func testFooterRoundTrip() throws {
        let footer = ZwzV2Footer(
            archiveID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            indexOffset: 123,
            indexLength: 456,
            indexChecksum: 789
        )

        let data = try ZwzV2BinaryCodec.encodeFooter(footer)
        XCTAssertEqual(try ZwzV2BinaryCodec.decodeFooter(data), footer)
    }

    func testFooterDecodeRejectsOverflowingIndexRange() throws {
        let footer = ZwzV2Footer(
            archiveID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            indexOffset: UInt64.max,
            indexLength: 1,
            indexChecksum: 789
        )

        var data = try ZwzV2BinaryCodec.encodeFooter(
            ZwzV2Footer(
                archiveID: footer.archiveID,
                indexOffset: 0,
                indexLength: 0,
                indexChecksum: footer.indexChecksum
            )
        )
        data.replaceSubrange(24..<32, with: littleEndianBytes(footer.indexOffset))
        data.replaceSubrange(32..<40, with: littleEndianBytes(footer.indexLength))
        assertMalformed(try ZwzV2BinaryCodec.decodeFooter(data))
    }

    func testFooterEncodeRejectsOverflowingIndexRange() {
        let footer = ZwzV2Footer(
            archiveID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            indexOffset: UInt64.max,
            indexLength: 1,
            indexChecksum: 789
        )

        assertMalformed(try ZwzV2BinaryCodec.encodeFooter(footer))
    }

    func testBlockRecordHeaderRoundTripUsesLittleEndianFields() throws {
        let record = ZwzV2BlockRecordHeader(
            sequence: 0x0102_0304_0506_0708,
            codec: .deflate,
            storedLength: 0x1112_1314,
            originalLength: 0x2122_2324,
            checksum: 0x3132_3334,
            tagLength: 16
        )

        let data = try ZwzV2BinaryCodec.encodeBlockRecordHeader(record)
        XCTAssertEqual(Array(data.prefix(8)), [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(try ZwzV2BinaryCodec.decodeBlockRecordHeader(data), record)
    }

    func testSplitEnvelopeRoundTrip() throws {
        let envelope = ZwzV2SplitEnvelope(
            archiveID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            volumeNumber: 7,
            isFinal: true,
            logicalOffset: 123,
            payloadLength: 456,
            payloadChecksum: 789
        )

        let data = try ZwzV2BinaryCodec.encodeSplitEnvelope(envelope)
        XCTAssertEqual(data.count, ZwzV2SplitEnvelope.encodedLength)
        XCTAssertEqual(try ZwzV2BinaryCodec.decodeSplitEnvelope(data), envelope)
    }

    func testSplitEnvelopeDecodeRejectsOverflowingPayloadRange() throws {
        let envelope = ZwzV2SplitEnvelope(
            archiveID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            volumeNumber: 7,
            isFinal: true,
            logicalOffset: UInt64.max,
            payloadLength: 1,
            payloadChecksum: 789
        )

        var data = try ZwzV2BinaryCodec.encodeSplitEnvelope(
            ZwzV2SplitEnvelope(
                archiveID: envelope.archiveID,
                volumeNumber: envelope.volumeNumber,
                isFinal: envelope.isFinal,
                logicalOffset: 0,
                payloadLength: 0,
                payloadChecksum: envelope.payloadChecksum
            )
        )
        data.replaceSubrange(32..<40, with: littleEndianBytes(envelope.logicalOffset))
        data.replaceSubrange(40..<48, with: littleEndianBytes(envelope.payloadLength))
        assertMalformed(try ZwzV2BinaryCodec.decodeSplitEnvelope(data))
    }

    func testSplitEnvelopeEncodeRejectsOverflowingPayloadRange() {
        let envelope = ZwzV2SplitEnvelope(
            archiveID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            volumeNumber: 7,
            isFinal: true,
            logicalOffset: UInt64.max,
            payloadLength: 1,
            payloadChecksum: 789
        )

        assertMalformed(try ZwzV2BinaryCodec.encodeSplitEnvelope(envelope))
    }

    func testHeaderDecodeRejectsUnsupportedFlags() throws {
        var data = try encodedHeader()
        data[24] = 0x04

        assertMalformed(try ZwzV2BinaryCodec.decodeHeader(data))
    }

    func testBlockRecordDecodeRejectsUnknownCodec() {
        var data = Data(repeating: 0, count: ZwzV2BlockRecordHeader.encodedLength)
        data[8] = 0xFF

        assertMalformed(try ZwzV2BinaryCodec.decodeBlockRecordHeader(data))
    }

    func testHeaderDecodeRejectsBadMagic() throws {
        var data = try encodedHeader()
        data[0] = 0

        assertMalformed(try ZwzV2BinaryCodec.decodeHeader(data))
    }

    func testHeaderDecodeRejectsBadVersion() throws {
        var data = try encodedHeader()
        data[4] = 3

        assertMalformed(try ZwzV2BinaryCodec.decodeHeader(data))
    }

    func testHeaderDecodeRejectsMalformedSaltLength() throws {
        var data = try encodedHeader()
        data[32] = 33

        assertMalformed(try ZwzV2BinaryCodec.decodeHeader(data))
    }

    func testFooterDecodeRejectsReservedByteCorruption() throws {
        var data = try ZwzV2BinaryCodec.encodeFooter(
            ZwzV2Footer(
                archiveID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                indexOffset: 123,
                indexLength: 456,
                indexChecksum: 789
            )
        )
        data[44] = 1

        assertMalformed(try ZwzV2BinaryCodec.decodeFooter(data))
    }

    func testDecodeRejectsMalformedFixedLengthRecord() {
        XCTAssertThrowsError(try ZwzV2BinaryCodec.decodeFooter(Data(repeating: 0, count: ZwzV2Footer.encodedLength - 1))) { error in
            guard case .malformedArchive = error as? ZwzV2Error else {
                return XCTFail("Expected a malformed archive error, got \(error)")
            }
        }
    }

    private func assertMalformed<T>(_ expression: @autoclosure () throws -> T) {
        XCTAssertThrowsError(try expression()) { error in
            guard case .malformedArchive = error as? ZwzV2Error else {
                return XCTFail("Expected a malformed archive error, got \(error)")
            }
        }
    }

    private func encodedHeader() throws -> Data {
        try ZwzV2BinaryCodec.encodeHeader(
            ZwzV2Header(
                archiveID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                flags: [.encrypted],
                blockSize: 4 * 1024 * 1024,
                kdfSalt: Data([1, 2, 3, 4]),
                kdfIterations: 210_000
            )
        )
    }

    private func littleEndianBytes(_ value: UInt64) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
