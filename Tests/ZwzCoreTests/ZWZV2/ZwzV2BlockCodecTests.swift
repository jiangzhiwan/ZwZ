import XCTest
@testable import ZwzCore

final class ZwzV2BlockCodecTests: XCTestCase {
    func testNoneStoresVerbatim() throws {
        let input = Data("hello".utf8)
        let block = try ZwzV2BlockCodec.encode(input, level: .none)
        XCTAssertEqual(block.codec, .store)
        XCTAssertEqual(try ZwzV2BlockCodec.decode(block), input)
    }

    func testNormalRoundTripsCompressibleData() throws {
        let input = Data(String(repeating: "abc123\n", count: 20_000).utf8)
        let block = try ZwzV2BlockCodec.encode(input, level: .normal)
        XCTAssertLessThan(block.payload.count, input.count)
        XCTAssertEqual(try ZwzV2BlockCodec.decode(block), input)
    }

    func testNormalStoresIncompressibleData() throws {
        var bytes = [UInt8]()
        for value in 0..<65_536 {
            bytes.append(UInt8((value * 31) % 251))
        }
        let input = Data(bytes)
        let block = try ZwzV2BlockCodec.encode(input, level: .normal)
        XCTAssertEqual(try ZwzV2BlockCodec.decode(block), input)
    }

    func testDecodeReportsChecksumMismatch() throws {
        let input = Data("checksum me".utf8)
        var block = try ZwzV2BlockCodec.encode(input, level: .none)
        block.checksum ^= 1

        XCTAssertThrowsError(try ZwzV2BlockCodec.decode(block)) { error in
            XCTAssertEqual(error as? ZwzV2Error, .checksumMismatch(sequence: 0))
        }
    }

    func testRawDecodeMapsMalformedCompressedPayloadToDecompressionFailed() {
        XCTAssertThrowsError(
            try ZwzV2BlockCodec.decode(
                codec: .deflate,
                payload: Data([0]),
                originalLength: 1,
                sequence: 7
            )
        ) { error in
            XCTAssertEqual(error as? ZwzV2Error, .decompressionFailed(sequence: 7))
        }
    }

    func testNormalStoresWhenDeflateBeatsLZ4ButDoesNotSaveOnePercent() throws {
        let selected = ZwzV2BlockCodec.selectNormalCodec(
            inputCount: 1_000,
            lz4Count: 1_100,
            deflateCount: 1_010,
            hasRepetition: true
        )

        XCTAssertEqual(selected, .store)
    }
}
