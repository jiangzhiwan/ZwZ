import Foundation
import XCTest
@testable import ZwzCore

final class ZwzV3ArchiveInspectionTests: XCTestCase {
    func testUnsignedInspectionExposesRecipientsWithoutAnyKeyLookup() throws {
        let fixture = try ZwzV3APITestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let provider = InspectionTrackingKeyProvider()

        let inspection = try ZwzV3Extractor().inspectArchive(
            archivePath: fixture.archive.path,
            keyProvider: provider
        )

        XCTAssertEqual(inspection.recipients, [
            ZwzRecipientInfo(
                name: fixture.identity.recipient.name,
                fingerprint: fixture.identity.recipient.fingerprint
            ),
        ])
        XCTAssertEqual(
            inspection.securityInfo,
            ZwzArchiveSecurityInfo(
                encryption: .publicKey,
                recipientFingerprints: [fixture.identity.recipient.fingerprint],
                signature: .unsigned
            )
        )
        XCTAssertEqual(provider.lookupCounts, .zero)
    }

    func testSignedInspectionClassifiesExactKnownKeyWithoutPrivateKeyLookup() throws {
        let fixture = try ZwzV3APITestSupport.makeFixture(signer: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let provider = InspectionTrackingKeyProvider(knownSigningKeys: [
            fixture.identity.signingFingerprint: fixture.identity.signingIdentity.signingPublicKey,
        ])

        let inspection = try ZwzV3Extractor().inspectArchive(
            archivePath: fixture.archive.path,
            keyProvider: provider
        )

        XCTAssertEqual(
            inspection.securityInfo.signature,
            .validKnownSigner(
                name: fixture.identity.signingIdentity.name,
                fingerprint: fixture.identity.signingFingerprint
            )
        )
        XCTAssertEqual(provider.lookupCounts, KeyLookupCounts(agreement: 0, signing: 0, trust: 1))
    }

    func testSignedInspectionClassifiesUnknownWhenFingerprintKeyBindingDoesNotMatch() throws {
        let fixture = try ZwzV3APITestSupport.makeFixture(signer: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let provider = InspectionTrackingKeyProvider(knownSigningKeys: [
            fixture.identity.signingFingerprint: Data(repeating: 0xA5, count: 32),
        ])

        let inspection = try ZwzV3Extractor().inspectArchive(
            archivePath: fixture.archive.path,
            keyProvider: provider
        )

        XCTAssertEqual(
            inspection.securityInfo.signature,
            .validUnknownSigner(
                name: fixture.identity.signingIdentity.name,
                fingerprint: fixture.identity.signingFingerprint
            )
        )
        XCTAssertEqual(provider.lookupCounts, KeyLookupCounts(agreement: 0, signing: 0, trust: 1))
    }

    func testInvalidSignatureIsInspectableButContentOperationStillRejectsBeforeKeyLookup() throws {
        let fixture = try ZwzV3APITestSupport.makeFixture(signer: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let parsed = try ZwzV3BinaryCodec.parse(Data(contentsOf: fixture.archive))
        let invalid = try ZwzV3TestSupport.mutate(
            fixture.archive,
            at: Int(parsed.header.signatureOffset)
        )
        let provider = InspectionTrackingKeyProvider(agreementKeys: [
            fixture.identity.recipient.fingerprint: fixture.identity.agreementPrivateKey,
        ])

        let inspection = try ZwzV3Extractor().inspectArchive(
            archivePath: invalid.path,
            keyProvider: provider
        )

        XCTAssertEqual(inspection.securityInfo.signature, .invalid)
        XCTAssertEqual(inspection.recipients.count, 1)
        XCTAssertEqual(provider.lookupCounts, .zero)
        XCTAssertThrowsError(try ZwzV3Extractor().listEntries(
            archivePath: invalid.path,
            keyProvider: provider
        )) { error in
            XCTAssertEqual(error as? ZwzV3Error, .invalidSignature)
        }
        XCTAssertEqual(provider.lookupCounts, .zero)
    }

    func testInspectionSucceedsWhenMatchingPrivateKeyIsMissing() throws {
        let fixture = try ZwzV3APITestSupport.makeFixture(signer: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let provider = InspectionTrackingKeyProvider(knownSigningKeys: [
            fixture.identity.signingFingerprint: fixture.identity.signingIdentity.signingPublicKey,
        ])

        let inspection = try ZwzAPI().inspect(
            archivePath: fixture.archive.path,
            keyProvider: provider
        )

        XCTAssertEqual(inspection.securityInfo.signature, .validKnownSigner(
            name: fixture.identity.signingIdentity.name,
            fingerprint: fixture.identity.signingFingerprint
        ))
        XCTAssertEqual(provider.lookupCounts, KeyLookupCounts(agreement: 0, signing: 0, trust: 1))
        XCTAssertThrowsError(try ZwzAPI().list(
            archivePath: fixture.archive.path,
            password: nil,
            keyProvider: provider
        )) { error in
            guard case ZwzV3Error.noMatchingPrivateKey = error else {
                return XCTFail("expected noMatchingPrivateKey, got \(error)")
            }
        }
        XCTAssertEqual(provider.lookupCounts.agreement, 1)
        XCTAssertEqual(provider.lookupCounts.signing, 0)
    }

    func testPublicInspectionRoutesRenamedAndSplitV3Archives() throws {
        let renamedFixture = try ZwzV3APITestSupport.makeFixture(name: "original.zwz")
        defer { try? FileManager.default.removeItem(at: renamedFixture.directory) }
        let renamed = renamedFixture.directory.appendingPathComponent("renamed.bin")
        try FileManager.default.moveItem(at: renamedFixture.archive, to: renamed)

        let renamedInspection = try ZwzAPI().inspect(
            archivePath: renamed.path,
            keyProvider: nil
        )
        XCTAssertEqual(
            renamedInspection.securityInfo.recipientFingerprints,
            [renamedFixture.identity.recipient.fingerprint]
        )

        let splitFixture = try ZwzV3APITestSupport.makeFixture(
            name: "split.zwz",
            signer: true,
            splitVolume: .kiloBytes(1),
            contents: Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        )
        defer { try? FileManager.default.removeItem(at: splitFixture.directory) }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: splitFixture.directory.appendingPathComponent("split.z00").path
        ))

        let splitInspection = try ZwzAPI().inspect(
            archivePath: splitFixture.archive.path,
            keyProvider: nil
        )
        XCTAssertEqual(splitInspection.recipients, [ZwzRecipientInfo(
            name: splitFixture.identity.recipient.name,
            fingerprint: splitFixture.identity.recipient.fingerprint
        )])
        XCTAssertEqual(splitInspection.securityInfo.signature, .validUnknownSigner(
            name: splitFixture.identity.signingIdentity.name,
            fingerprint: splitFixture.identity.signingFingerprint
        ))
    }

    func testSignedStructuralCorruptionKeepsContentFailureSemantics() throws {
        let fixture = try ZwzV3APITestSupport.makeFixture(signer: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var bytes = try Data(contentsOf: fixture.archive)
        let parsed = try ZwzV3BinaryCodec.parse(bytes)
        Data.writeUInt32(.max, at: Int(parsed.header.signerRegionOffset), in: &bytes)
        let malformed = fixture.directory.appendingPathComponent("signed-malformed.zwz")
        try bytes.write(to: malformed)
        let provider = InspectionTrackingKeyProvider()

        XCTAssertThrowsError(try ZwzV3Extractor().inspectArchive(
            archivePath: malformed.path,
            keyProvider: provider
        )) { error in
            XCTAssertEqual(error as? ZwzV3Error, .invalidSignature)
        }
        XCTAssertThrowsError(try ZwzV3Extractor().listEntries(
            archivePath: malformed.path,
            keyProvider: provider
        )) { error in
            XCTAssertEqual(error as? ZwzV3Error, .invalidSignature)
        }
        XCTAssertEqual(provider.lookupCounts, .zero)
    }

    func testUnsignedStructuralCorruptionRemainsMalformed() throws {
        let fixture = try ZwzV3APITestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var bytes = try Data(contentsOf: fixture.archive)
        bytes[128] = 1
        let malformed = fixture.directory.appendingPathComponent("unsigned-malformed.zwz")
        try bytes.write(to: malformed)
        let provider = InspectionTrackingKeyProvider()

        XCTAssertThrowsError(try ZwzV3Extractor().inspectArchive(
            archivePath: malformed.path,
            keyProvider: provider
        )) { error in
            guard case ZwzV3Error.malformedArchive = error else {
                return XCTFail("expected malformedArchive, got \(error)")
            }
        }
        XCTAssertEqual(provider.lookupCounts, .zero)
    }
}

private struct KeyLookupCounts: Equatable {
    var agreement: Int
    var signing: Int
    var trust: Int

    static let zero = Self(agreement: 0, signing: 0, trust: 0)
}

private final class InspectionTrackingKeyProvider: ZwzPrivateKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let agreementKeys: [String: Data]
    private let knownSigningKeys: [String: Data]
    private var counts = KeyLookupCounts.zero

    init(
        agreementKeys: [String: Data] = [:],
        knownSigningKeys: [String: Data] = [:]
    ) {
        self.agreementKeys = agreementKeys
        self.knownSigningKeys = knownSigningKeys
    }

    var lookupCounts: KeyLookupCounts {
        lock.withLock { counts }
    }

    func agreementPrivateKey(fingerprint: String, reason: String) throws -> Data {
        try lock.withLock {
            counts.agreement += 1
            guard let key = agreementKeys[fingerprint] else {
                throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
            }
            return key
        }
    }

    func signingPrivateKey(fingerprint: String, reason: String) throws -> Data {
        lock.withLock { counts.signing += 1 }
        throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
    }

    func isKnownSigningKey(fingerprint: String, signingPublicKey: Data) -> Bool {
        lock.withLock {
            counts.trust += 1
            return knownSigningKeys[fingerprint] == signingPublicKey
        }
    }
}
