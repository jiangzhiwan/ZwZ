import CryptoKit
import XCTest
@testable import ZwzCore

final class ZwzKeyFileCodecTests: XCTestCase {
    func testPublicGoldenBytesAndRoundTrip() throws {
        let identity = try ZwzKeyFileTestSupport.publicIdentity()
        let encoded = try ZwzKeyFileCodec.encodePublic(identity)

        XCTAssertEqual(encoded.prefix(4), Data("ZWZP".utf8))
        XCTAssertEqual(encoded.count, 32 + 5 + 64 + 32 + 32)
        XCTAssertEqual(Array(encoded.prefix(32)), [
            0x5a, 0x57, 0x5a, 0x50, 0x01, 0x00, 0x20, 0x00,
            0x01, 0x01, 0x01, 0x00, 0x05, 0x00, 0x00, 0x00,
            0x40, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00,
            0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ])
        XCTAssertEqual(try ZwzKeyFileCodec.decodePublic(encoded), identity)
    }

    func testPublicEncoderRecomputesFingerprint() throws {
        let valid = try ZwzKeyFileTestSupport.publicIdentity()
        let mismatched = ZwzPublicIdentity(
            name: valid.name,
            fingerprint: String(repeating: "0", count: 64),
            agreementPublicKey: valid.agreementPublicKey,
            signingPublicKey: valid.signingPublicKey
        )
        let decoded = try ZwzKeyFileCodec.decodePublic(ZwzKeyFileCodec.encodePublic(mismatched))
        XCTAssertEqual(decoded.fingerprint, valid.fingerprint)
    }

    func testPublicParserRejectsEveryHeaderFieldTruncationAndTrailingBytes() throws {
        let encoded = try ZwzKeyFileCodec.encodePublic(ZwzKeyFileTestSupport.publicIdentity())
        let mutations: [Data] = [
            ZwzKeyFileTestSupport.replacing(encoded, at: 0, with: 0),
            ZwzKeyFileTestSupport.replacing(encoded, at: 4, with: 2),
            ZwzKeyFileTestSupport.replacing(encoded, at: 6, with: 31),
            ZwzKeyFileTestSupport.replacing(encoded, at: 8, with: 2),
            ZwzKeyFileTestSupport.replacing(encoded, at: 9, with: 2),
            ZwzKeyFileTestSupport.replacing(encoded, at: 10, with: 2),
            ZwzKeyFileTestSupport.replacing(encoded, at: 11, with: 1),
            ZwzKeyFileTestSupport.writing(UInt32(0), to: encoded, at: 12),
            ZwzKeyFileTestSupport.writing(UInt32(63), to: encoded, at: 16),
            ZwzKeyFileTestSupport.writing(UInt32.max, to: encoded, at: 20),
            ZwzKeyFileTestSupport.writing(UInt32(31), to: encoded, at: 24),
            ZwzKeyFileTestSupport.replacing(encoded, at: 28, with: 1),
            Data(encoded.dropLast()),
            encoded + Data([0])
        ]
        for mutation in mutations {
            XCTAssertThrowsError(try ZwzKeyFileCodec.decodePublic(mutation)) {
                XCTAssertEqual($0 as? ZwzV3Error, .invalidKeyFile)
            }
        }
    }

    func testPublicParserRejectsInvalidUTF8FingerprintAndKeyBinding() throws {
        let encoded = try ZwzKeyFileCodec.encodePublic(ZwzKeyFileTestSupport.publicIdentity())
        for offset in [32, 37, 37 + 64, 37 + 64 + 32] {
            var mutation = encoded
            mutation[offset] ^= 0xff
            XCTAssertThrowsError(try ZwzKeyFileCodec.decodePublic(mutation)) {
                XCTAssertEqual($0 as? ZwzV3Error, .invalidKeyFile)
            }
        }
    }

    func testBackupRoundTripsWithoutPlaintextSecretsOrName() throws {
        let backup = try ZwzKeyFileTestSupport.backup()
        XCTAssertEqual(backup.prefix(4), Data("ZWZB".utf8))
        XCTAssertNil(backup.range(of: ZwzKeyFileTestSupport.agreementPrivateKey))
        XCTAssertNil(backup.range(of: ZwzKeyFileTestSupport.signingPrivateKey))
        XCTAssertNil(backup.range(of: Data("Alice".utf8)))
        XCTAssertEqual(
            try ZwzKeyFileCodec.decodeBackup(
                backup, password: "correct horse battery staple"
            ),
            try ZwzKeyFileTestSupport.privateIdentity()
        )
    }

    func testBackupRejectsEmptyPasswordWrongPasswordAndAuthenticatedMutations() throws {
        let backup = try ZwzKeyFileTestSupport.backup()
        XCTAssertThrowsError(try ZwzKeyFileCodec.encodeBackup(
            ZwzKeyFileTestSupport.privateIdentity(), password: ""
        ))
        XCTAssertThrowsError(try ZwzKeyFileCodec.decodeBackup(backup, password: ""))
        XCTAssertThrowsError(try ZwzKeyFileCodec.decodeBackup(backup, password: "wrong"))

        let fastBackup = try ZwzKeyFileTestSupport.fastBackup()
        for offset in [64, 80, 92, fastBackup.count - 1] {
            var mutation = fastBackup
            mutation[offset] ^= 1
            XCTAssertThrowsError(try ZwzKeyFileCodec.decodeBackup(
                mutation,
                password: "correct horse battery staple",
                deriveKey: { _, _ in ZwzKeyFileTestSupport.fastDerivedKey }
            )) { XCTAssertEqual($0 as? ZwzV3Error, .invalidBackup) }
        }
    }

    func testBackupRejectsUnsupportedHeaderAndLengthBeforeDerivation() throws {
        let backup = try ZwzKeyFileTestSupport.fastBackup()
        let mutations: [Data] = [
            ZwzKeyFileTestSupport.replacing(backup, at: 0, with: 0),
            ZwzKeyFileTestSupport.replacing(backup, at: 4, with: 2),
            ZwzKeyFileTestSupport.replacing(backup, at: 6, with: 63),
            ZwzKeyFileTestSupport.replacing(backup, at: 8, with: 2),
            ZwzKeyFileTestSupport.replacing(backup, at: 9, with: 2),
            ZwzKeyFileTestSupport.replacing(backup, at: 10, with: 2),
            ZwzKeyFileTestSupport.replacing(backup, at: 11, with: 2),
            ZwzKeyFileTestSupport.writing(UInt32(32_768), to: backup, at: 12),
            ZwzKeyFileTestSupport.writing(UInt32(9), to: backup, at: 16),
            ZwzKeyFileTestSupport.writing(UInt32(2), to: backup, at: 20),
            ZwzKeyFileTestSupport.writing(UInt16(15), to: backup, at: 24),
            ZwzKeyFileTestSupport.writing(UInt16(11), to: backup, at: 26),
            ZwzKeyFileTestSupport.writing(UInt64.max, to: backup, at: 28),
            ZwzKeyFileTestSupport.replacing(backup, at: 36, with: 1),
            Data(backup.dropLast()),
            backup + Data([0])
        ]

        for mutation in mutations {
            var derivationCount = 0
            XCTAssertThrowsError(try ZwzKeyFileCodec.decodeBackup(
                mutation,
                password: "correct horse battery staple",
                deriveKey: { _, _ in derivationCount += 1; return Data(repeating: 0, count: 32) }
            )) { XCTAssertEqual($0 as? ZwzV3Error, .invalidBackup) }
            XCTAssertEqual(derivationCount, 0)
        }
    }
}
