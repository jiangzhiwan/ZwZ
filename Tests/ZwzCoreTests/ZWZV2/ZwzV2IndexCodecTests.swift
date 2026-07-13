import XCTest
@testable import ZwzCore

final class ZwzV2IndexCodecTests: XCTestCase {
    func testPlainIndexRoundTrips() throws {
        let index = sampleIndex()
        let data = try ZwzV2IndexCodec.encodePlain(index)
        XCTAssertEqual(try ZwzV2IndexCodec.decodePlain(data), index)
    }

    func testPlainIndexStoresModificationTimeAsLittleEndianMilliseconds() throws {
        let data = try ZwzV2IndexCodec.encodePlain(sampleIndex())

        XCTAssertEqual(Array(data[59..<67]), [0x10, 0x27, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    func testPlainIndexRejectsFractionalMillisecondModificationTime() throws {
        var index = sampleIndex()
        index.entries[0].modificationTime = Date(timeIntervalSince1970: 10.000_5)

        assertMalformed(try ZwzV2IndexCodec.encodePlain(index))
    }

    func testPlainIndexRejectsModificationTimeAtUnrepresentableUpperBound() throws {
        var index = sampleIndex()
        index.entries[0].modificationTime = Date(timeIntervalSince1970: 9_223_372_036_854_776)

        assertMalformed(try ZwzV2IndexCodec.encodePlain(index))
    }

    func testEncryptedIndexDoesNotExposeFilenames() throws {
        let index = sampleIndex()
        let context = try ZwzV2Crypto.deriveContext(password: "secret", salt: Data(repeating: 9, count: 16), iterations: 1_000, archiveID: index.archiveID)
        let sealed = try ZwzV2IndexCodec.encodeForArchive(index, context: context)
        XCTAssertNil(sealed.payload.range(of: Data("hidden.txt".utf8)))
        XCTAssertEqual(try ZwzV2IndexCodec.decodeFromArchive(payload: sealed.payload, tag: sealed.tag, context: context), index)
    }

    func testEncryptedIndexRejectsModifiedPayload() throws {
        let index = sampleIndex()
        let context = try ZwzV2Crypto.deriveContext(password: "secret", salt: Data(repeating: 9, count: 16), iterations: 1_000, archiveID: index.archiveID)
        var sealed = try ZwzV2IndexCodec.encodeForArchive(index, context: context)
        sealed.payload[sealed.payload.startIndex] ^= 0x01

        assertTampered(try ZwzV2IndexCodec.decodeFromArchive(payload: sealed.payload, tag: sealed.tag, context: context))
    }

    func testEncryptedIndexRejectsModifiedTag() throws {
        let index = sampleIndex()
        let context = try ZwzV2Crypto.deriveContext(password: "secret", salt: Data(repeating: 9, count: 16), iterations: 1_000, archiveID: index.archiveID)
        var sealed = try ZwzV2IndexCodec.encodeForArchive(index, context: context)
        sealed.tag[sealed.tag.startIndex] ^= 0x01

        assertTampered(try ZwzV2IndexCodec.decodeFromArchive(payload: sealed.payload, tag: sealed.tag, context: context))
    }

    func testPlainIndexRejectsTrailingBytes() throws {
        var data = try ZwzV2IndexCodec.encodePlain(sampleIndex())
        data.append(0)

        assertMalformed(try ZwzV2IndexCodec.decodePlain(data))
    }

    func testPlainIndexRejectsUnsafePaths() throws {
        var data = try ZwzV2IndexCodec.encodePlain(sampleIndex())
        data.replaceSubrange(32..<50, with: Data("../escape-filexxxx".utf8))

        XCTAssertThrowsError(try ZwzV2IndexCodec.decodePlain(data)) { error in
            XCTAssertEqual(error as? ZwzV2Error, .unsafePath("../escape-filexxxx"))
        }
    }

    func testEncryptedIndexRejectsWrongContext() throws {
        let index = sampleIndex()
        let good = try ZwzV2Crypto.deriveContext(password: "secret", salt: Data(repeating: 9, count: 16), iterations: 1_000, archiveID: index.archiveID)
        let wrong = try ZwzV2Crypto.deriveContext(password: "wrong", salt: Data(repeating: 9, count: 16), iterations: 1_000, archiveID: index.archiveID)
        let sealed = try ZwzV2IndexCodec.encodeForArchive(index, context: good)

        XCTAssertThrowsError(try ZwzV2IndexCodec.decodeFromArchive(payload: sealed.payload, tag: sealed.tag, context: wrong)) { error in
            XCTAssertEqual(error as? ZwzV2Error, .wrongPasswordOrTamperedData)
        }
    }

    private func sampleIndex() -> ZwzV2Index {
        let block = ZwzV2BlockDescriptor(sequence: 0, fileOffset: 0, archiveOffset: 128, storedLength: 5, originalLength: 5, codec: .store, checksum: 1, authenticationTag: [])
        let entry = ZwzV2Entry(path: ".secret/hidden.txt", type: .file, originalSize: 5, modificationTime: Date(timeIntervalSince1970: 10), isHidden: true, blocks: [block])
        return ZwzV2Index(archiveID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, blockSize: 4 * 1024 * 1024, entries: [entry])
    }

    private func assertMalformed<T>(_ expression: @autoclosure () throws -> T) {
        XCTAssertThrowsError(try expression()) { error in
            guard case .malformedArchive = error as? ZwzV2Error else {
                return XCTFail("Expected a malformed archive error, got \(error)")
            }
        }
    }

    private func assertTampered<T>(_ expression: @autoclosure () throws -> T) {
        XCTAssertThrowsError(try expression()) { error in
            XCTAssertEqual(error as? ZwzV2Error, .wrongPasswordOrTamperedData)
        }
    }
}
