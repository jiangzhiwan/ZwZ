import Foundation
import XCTest
@testable import ZwzCore

final class ZwzV3BinaryCodecTests: XCTestCase {
    func testHeaderRoundTripPreservesAlgorithmsAndOffsets() throws {
        let header = ZwzV3Header(
            archiveID: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
            recipientCount: 2,
            recipientRegionOffset: 160,
            recipientRegionLength: 300,
            dataRegionOffset: 460,
            dataRegionLength: 100,
            encryptedIndexOffset: 560,
            encryptedIndexLength: 40,
            signerRegionOffset: 600,
            signerRegionLength: 130,
            signatureOffset: 666,
            signatureLength: 64,
            dataBlockCount: 3,
            signatureAlgorithm: .ed25519
        )

        XCTAssertEqual(
            try ZwzV3BinaryCodec.decodeHeader(ZwzV3BinaryCodec.encodeHeader(header)),
            header
        )
    }

    func testUnsignedArchiveRoundTripPreservesOpaqueRegionsAndRecipients() throws {
        let archive = try Data.fixture()
        let parsed = try ZwzV3BinaryCodec.parse(archive)

        XCTAssertEqual(parsed.recipients, [.codecFixture()])
        XCTAssertEqual(parsed.dataRegion, Data([0x70, 0x71, 0x72]))
        XCTAssertEqual(parsed.encryptedIndex, Data([0x80, 0x81]))
        XCTAssertNil(parsed.signer)
        XCTAssertEqual(parsed.canonicalSignedBytes, archive)
    }

    func testSignedArchiveRoundTripAndCanonicalBytesExcludeOnlySignatureValue() throws {
        let firstArchive = try Data.signedFixture(signature: Data(repeating: 1, count: 64))
        let secondArchive = try Data.signedFixture(signature: Data(repeating: 2, count: 64))
        let first = try ZwzV3BinaryCodec.parse(firstArchive)
        let second = try ZwzV3BinaryCodec.parse(secondArchive)

        XCTAssertEqual(first.signer, .codecFixture(signature: Data(repeating: 1, count: 64)))
        XCTAssertEqual(first.canonicalSignedBytes, second.canonicalSignedBytes)
        XCTAssertEqual(first.canonicalSignedBytes.count, firstArchive.count - 64)
        XCTAssertEqual(
            first.canonicalSignedBytes,
            firstArchive.prefix(Int(first.header.signatureOffset))
        )
    }

    func testParserRejectsEveryTruncationBoundary() throws {
        let archives = [
            try Data.fixture(),
            try Data.signedFixture(signature: Data(repeating: 1, count: 64)),
        ]

        for archive in archives {
            for length in 0..<archive.count {
                assertMalformed(archive.prefix(length), "accepted truncation at byte \(length)")
            }
        }
    }

    func testParserRejectsOverlappingGappedAndTrailingRegions() throws {
        assertMalformed(try Data.fixtureWithOverlappingIndex())

        var gapped = try Data.fixture()
        Data.writeUInt64(Data.readUInt64(at: 72, in: gapped) + 1, at: 72, in: &gapped)
        assertMalformed(gapped)

        var trailing = try Data.fixture()
        trailing.append(0)
        assertMalformed(trailing)
    }

    func testParserRejectsCorruptRecordLengthsAndInvalidUTF8() throws {
        let fixture = try Data.fixture()
        let recipientOffset = Int(Data.readUInt64(at: 40, in: fixture))

        var impossibleRecipientCount = fixture
        Data.writeUInt32(.max, at: 36, in: &impossibleRecipientCount)
        assertMalformed(impossibleRecipientCount)

        for length: UInt32 in [0, 1, UInt32.max] {
            var archive = fixture
            Data.writeUInt32(length, at: recipientOffset, in: &archive)
            assertMalformed(archive)
        }

        var invalidUTF8 = fixture
        invalidUTF8[recipientOffset + 8] = 0xFF
        assertMalformed(invalidUTF8)

        var corruptNameLength = fixture
        Data.writeUInt32(.max, at: recipientOffset + 4, in: &corruptNameLength)
        assertMalformed(corruptNameLength)

        var signed = try Data.signedFixture(signature: Data(repeating: 1, count: 64))
        let signerOffset = Int(Data.readUInt64(at: 88, in: signed))
        Data.writeUInt32(.max, at: signerOffset, in: &signed)
        assertMalformed(signed)
    }

    func testParserRejectsUnknownFlagsAlgorithmsReservedBytesAndInconsistentSignature() throws {
        let fixture = try Data.fixture()
        for mutation: (inout Data) -> Void in [
            { $0[8] = 0x02 },
            { $0[12] = 0xFF },
            { $0[13] = 0xFF },
            { $0[14] = 0xFF },
            { $0[15] = 0xFF },
            { $0[16] = 0xFF },
            { $0[17] = 0xFF },
            { $0[18] = 0xFF },
            { $0[19] = 0x01 },
            { $0[128] = 0x01 },
            { $0[8] = 0x01 },
        ] {
            var archive = fixture
            mutation(&archive)
            assertMalformed(archive)
        }

        var overflowing = fixture
        Data.writeUInt64(.max, at: 40, in: &overflowing)
        assertMalformed(overflowing)
    }

    func testEncoderRejectsEmptyRequiredRegionsAndWrongCryptoFieldSizes() throws {
        let recipient = ZwzV3RecipientEnvelope.codecFixture()
        let arguments: [(ZwzV3RecipientEnvelope, Data)] = [
            (ZwzV3RecipientEnvelope(
                recipientName: recipient.recipientName,
                recipientFingerprint: recipient.recipientFingerprint,
                ephemeralPublicKey: Data(repeating: 0, count: 31),
                nonce: recipient.nonce,
                encryptedContentKey: recipient.encryptedContentKey,
                authenticationTag: recipient.authenticationTag
            ), Data([1])),
            (ZwzV3RecipientEnvelope(
                recipientName: recipient.recipientName,
                recipientFingerprint: recipient.recipientFingerprint,
                ephemeralPublicKey: recipient.ephemeralPublicKey,
                nonce: Data(repeating: 0, count: 11),
                encryptedContentKey: recipient.encryptedContentKey,
                authenticationTag: recipient.authenticationTag
            ), Data([1])),
        ]

        for (invalidRecipient, index) in arguments {
            XCTAssertThrowsError(try encode(recipients: [invalidRecipient], encryptedIndex: index))
        }
        XCTAssertThrowsError(try encode(recipients: [], encryptedIndex: Data([1])))
        XCTAssertThrowsError(try encode(recipients: [recipient], encryptedIndex: Data()))
        XCTAssertThrowsError(try encode(recipients: [recipient], dataRegion: Data(), dataBlockCount: 1))
        XCTAssertNoThrow(try encode(recipients: [recipient], dataRegion: Data(), dataBlockCount: 0))
        XCTAssertThrowsError(try encode(
            recipients: [recipient],
            signer: .codecFixture(signature: Data(repeating: 0, count: 63))
        ))
    }

    private func encode(
        recipients: [ZwzV3RecipientEnvelope],
        dataRegion: Data = Data([1]),
        encryptedIndex: Data = Data([2]),
        signer: ZwzV3SignerRecord? = nil,
        dataBlockCount: UInt64 = 1
    ) throws -> Data {
        try ZwzV3ArchiveCodec.encode(
            recipients: recipients,
            dataRegion: dataRegion,
            encryptedIndex: encryptedIndex,
            signer: signer,
            archiveID: UUID(),
            dataBlockCount: dataBlockCount
        )
    }

    private func assertMalformed<T: DataProtocol>(
        _ bytes: T,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ZwzV3BinaryCodec.parse(Data(bytes)), message, file: file, line: line) {
            guard case .malformedArchive = $0 as? ZwzV3Error else {
                return XCTFail("expected malformedArchive, got \($0)", file: file, line: line)
            }
        }
    }
}
