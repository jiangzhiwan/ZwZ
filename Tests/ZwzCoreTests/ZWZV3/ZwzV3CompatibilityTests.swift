import CryptoKit
import Foundation
import XCTest
@testable import ZwzCore

final class ZwzV3CompatibilityTests: XCTestCase {
    func testV1HeaderIsDetectedAndTruthfullyRejectedAsUnsupported() throws {
        let archive = try fixture("v1-header.zwz")

        XCTAssertEqual(try ZwzAPI().detectFormat(archivePath: archive.path), .zwz)
        XCTAssertThrowsError(try ZwzAPI().list(archivePath: archive.path)) { error in
            XCTAssertEqual(error as? ZwzV2Error, .unsupportedVersion(1))
        }
    }

    func testFixedV2UnencryptedFixtureCanBeDetectedListedAndExtracted() throws {
        let archive = try fixture("v2-unencrypted.zwz")
        let api = ZwzAPI()
        XCTAssertEqual(try api.detectFormat(archivePath: archive.path), .zwz)

        let listing = try api.list(archivePath: archive.path, keyProvider: nil)
        XCTAssertEqual(listing.version, 2)
        XCTAssertEqual(listing.securityInfo?.encryption, ZwzArchiveEncryptionKind.none)
        XCTAssertEqual(listing.entries.map(\.path), expectedEntryPaths)

        try assertExtractedFixture(archive: archive, password: nil, keyProvider: nil)
    }

    func testFixedV2PasswordFixtureCanBeDetectedListedAndExtracted() throws {
        let archive = try fixture("v2-password.zwz")
        let api = ZwzAPI()
        XCTAssertEqual(try api.detectFormat(archivePath: archive.path), .zwz)

        let listing = try api.list(
            archivePath: archive.path,
            password: CompatibilityMaterial.v2Password,
            keyProvider: nil
        )
        XCTAssertEqual(listing.version, 2)
        XCTAssertEqual(listing.securityInfo?.encryption, .password)
        XCTAssertEqual(listing.entries.map(\.path), expectedEntryPaths)

        try assertExtractedFixture(
            archive: archive,
            password: CompatibilityMaterial.v2Password,
            keyProvider: nil
        )
        XCTAssertThrowsError(try api.list(
            archivePath: archive.path,
            password: "TEST-ONLY wrong fixture password",
            keyProvider: nil
        )) { error in
            XCTAssertEqual(error as? ZwzV2Error, .wrongPasswordOrTamperedData)
        }
    }

    func testFixedUnsignedV3FixtureCanBeOpenedByEveryIntendedRecipient() throws {
        let archive = try fixture("v3-unsigned-multi-recipient.zwz")
        let api = ZwzAPI()
        XCTAssertEqual(try api.detectFormat(archivePath: archive.path), .zwz)
        let inspection = try api.inspect(archivePath: archive.path)
        XCTAssertEqual(inspection.recipients.count, 2)
        XCTAssertEqual(inspection.securityInfo.signature, .unsigned)

        for identity in try CompatibilityMaterial.recipientIdentities() {
            let listing = try api.list(
                archivePath: archive.path,
                password: nil,
                keyProvider: identity.provider
            )
            XCTAssertEqual(listing.version, 3)
            XCTAssertEqual(listing.securityInfo?.encryption, .publicKey)
            XCTAssertEqual(listing.securityInfo?.signature, .unsigned)
            XCTAssertEqual(listing.securityInfo?.recipientFingerprints.count, 2)
            XCTAssertEqual(listing.entries.map(\.path), expectedEntryPaths)
            try assertExtractedFixture(archive: archive, password: nil, keyProvider: identity.provider)
        }
    }

    func testFixedSignedV3FixtureClassifiesKnownAndUnknownSigner() throws {
        let archive = try fixture("v3-signed-multi-recipient.zwz")
        let identities = try CompatibilityMaterial.recipientIdentities()
        let alice = try XCTUnwrap(identities.first)
        let signing = try CompatibilityMaterial.signingMaterial()
        let api = ZwzAPI()

        let unknownInspection = try api.inspect(archivePath: archive.path)
        XCTAssertEqual(unknownInspection.recipients.count, 2)
        XCTAssertEqual(
            unknownInspection.securityInfo.signature,
            .validUnknownSigner(name: "Fixture Alice", fingerprint: signing.fingerprint)
        )
        let unknown = try api.list(
            archivePath: archive.path,
            password: nil,
            keyProvider: alice.provider
        )
        XCTAssertEqual(
            unknown.securityInfo?.signature,
            .validUnknownSigner(name: "Fixture Alice", fingerprint: signing.fingerprint)
        )

        let knownProvider = CompatibilityProvider(
            agreementKeys: [alice.recipient.fingerprint: alice.agreementPrivateKey],
            knownSigningKeys: [signing.fingerprint: signing.publicKey]
        )
        let knownInspection = try api.inspect(archivePath: archive.path, keyProvider: knownProvider)
        XCTAssertEqual(
            knownInspection.securityInfo.signature,
            .validKnownSigner(name: "Fixture Alice", fingerprint: signing.fingerprint)
        )
        let known = try api.list(
            archivePath: archive.path,
            password: nil,
            keyProvider: knownProvider
        )
        XCTAssertEqual(
            known.securityInfo?.signature,
            .validKnownSigner(name: "Fixture Alice", fingerprint: signing.fingerprint)
        )

        for identity in identities {
            try assertExtractedFixture(archive: archive, password: nil, keyProvider: identity.provider)
        }
    }

    func testOneByteMutationOfSignedCanonicalBytesIsRefused() throws {
        let archive = try fixture("v3-signed-multi-recipient.zwz")
        let parsed = try ZwzV3BinaryCodec.parse(Data(contentsOf: archive))
        let mutated = try mutatedCopy(of: archive, offset: Int(parsed.header.dataRegionOffset))
        defer { try? FileManager.default.removeItem(at: mutated.deletingLastPathComponent()) }
        let alice = try XCTUnwrap(CompatibilityMaterial.recipientIdentities().first)

        XCTAssertThrowsError(try ZwzAPI().list(
            archivePath: mutated.path,
            password: nil,
            keyProvider: alice.provider
        )) { error in
            XCTAssertEqual(error as? ZwzV3Error, .invalidSignature)
        }
    }

    func testOneByteMutationOfAuthenticatedEncryptedDataIsRefused() throws {
        let archive = try fixture("v3-unsigned-multi-recipient.zwz")
        let parsed = try ZwzV3BinaryCodec.parse(Data(contentsOf: archive))
        let mutated = try mutatedCopy(of: archive, offset: Int(parsed.header.dataRegionOffset) + 32)
        defer { try? FileManager.default.removeItem(at: mutated.deletingLastPathComponent()) }
        let alice = try XCTUnwrap(CompatibilityMaterial.recipientIdentities().first)

        XCTAssertThrowsError(try ZwzAPI().list(
            archivePath: mutated.path,
            password: nil,
            keyProvider: alice.provider
        )) { error in
            XCTAssertEqual(error as? ZwzV3Error, .authenticationFailed)
        }
    }

    func testCommittedFixtureSHA256DigestsAreLocked() throws {
        // V2 archive IDs/salts and V3 content/ephemeral keys are intentionally random.
        // Fixed fixture hashes provide a stable compatibility contract instead of regeneration.
        let expected = [
            "v1-header.zwz": "73cec77339335583c48e6ee2aca6c75a7c3279cffa633fea299258833716a3ed",
            "v2-password.zwz": "7d5d2ad28238e61b8d00720d93789963235792650599e18bb5016715454889b6",
            "v2-unencrypted.zwz": "49db99117788d180850e1856e59d8e914034fefaaa59aec4344e799abfa0b3d4",
            "v3-signed-multi-recipient.zwz": "fcf6e395bebb10db6ae68a20c321bd1203c83274321507d100c4d76314267007",
            "v3-unsigned-multi-recipient.zwz": "edb480f7e291c59d26acccac2f618747ab64d22a9a40afe72154b49c262fc7e2",
        ]

        for (name, digest) in expected {
            let bytes = try Data(contentsOf: fixture(name))
            XCTAssertEqual(SHA256.hash(data: bytes).hexString, digest, name)
        }
    }

    private let expectedEntryPaths = ["hello.txt", "nested", "nested/data.bin"]

    private func fixture(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            throw FixtureError.missing(name)
        }
        return url
    }

    private func assertExtractedFixture(
        archive: URL,
        password: String?,
        keyProvider: ZwzPrivateKeyProvider?
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zwz-compat-extract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try ZwzAPI().extract(
            archivePath: archive.path,
            destinationPath: directory.path,
            password: password,
            keyProvider: keyProvider
        )
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("hello.txt")),
            Data("fixture hello\n".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("nested/data.bin")),
            Data(0..<16)
        )
    }

    private func mutatedCopy(of archive: URL, offset: Int) throws -> URL {
        var bytes = try Data(contentsOf: archive)
        bytes[offset] ^= 0x01
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zwz-compat-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = directory.appendingPathComponent("mutated.zwz")
        try bytes.write(to: result)
        return result
    }
}

// These constants are deterministic compatibility-test secrets only. They are
// not generated from, shared with, or suitable for any production identity.
private enum CompatibilityMaterial {
    static let v2Password = "TEST-ONLY fixture password: v2"
    static let aliceAgreementPrivateKey = Data((1...32).map(UInt8.init))
    static let bobAgreementPrivateKey = Data((33...64).map(UInt8.init))
    static let aliceSigningPrivateKey = Data((65...96).map(UInt8.init))

    struct RecipientIdentity {
        let recipient: ZwzRecipient
        let agreementPrivateKey: Data

        var provider: CompatibilityProvider {
            CompatibilityProvider(agreementKeys: [recipient.fingerprint: agreementPrivateKey])
        }
    }

    struct SigningMaterial {
        let identity: ZwzSigningIdentity
        let privateKey: Data
        let publicKey: Data
        let fingerprint: String
    }

    static func recipientIdentities() throws -> [RecipientIdentity] {
        try [
            recipient(name: "Fixture Alice", privateKey: aliceAgreementPrivateKey, signingPrivateKey: aliceSigningPrivateKey),
            recipient(name: "Fixture Bob", privateKey: bobAgreementPrivateKey, signingPrivateKey: nil),
        ]
    }

    static func signingMaterial() throws -> SigningMaterial {
        let agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: aliceAgreementPrivateKey)
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: aliceSigningPrivateKey)
        let fingerprint = ZwzV3Crypto.fingerprint(
            agreement: agreement.publicKey.rawRepresentation,
            signing: signing.publicKey.rawRepresentation
        )
        return SigningMaterial(
            identity: ZwzSigningIdentity(
                name: "Fixture Alice",
                fingerprint: fingerprint,
                agreementPublicKey: agreement.publicKey.rawRepresentation,
                signingPublicKey: signing.publicKey.rawRepresentation
            ),
            privateKey: signing.rawRepresentation,
            publicKey: signing.publicKey.rawRepresentation,
            fingerprint: fingerprint
        )
    }

    private static func recipient(
        name: String,
        privateKey: Data,
        signingPrivateKey: Data?
    ) throws -> RecipientIdentity {
        let agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let signingPublicKey = try signingPrivateKey.map {
            try Curve25519.Signing.PrivateKey(rawRepresentation: $0).publicKey.rawRepresentation
        }
        let fingerprint = ZwzV3Crypto.fingerprint(
            agreement: agreement.publicKey.rawRepresentation,
            signing: signingPublicKey
        )
        return RecipientIdentity(
            recipient: ZwzRecipient(
                name: name,
                fingerprint: fingerprint,
                agreementPublicKey: agreement.publicKey.rawRepresentation
            ),
            agreementPrivateKey: agreement.rawRepresentation
        )
    }
}

private final class CompatibilityProvider: ZwzPrivateKeyProvider, @unchecked Sendable {
    private let agreementKeys: [String: Data]
    private let knownSigningKeys: [String: Data]

    init(agreementKeys: [String: Data], knownSigningKeys: [String: Data] = [:]) {
        self.agreementKeys = agreementKeys
        self.knownSigningKeys = knownSigningKeys
    }

    func agreementPrivateKey(fingerprint: String, reason: String) throws -> Data {
        guard let key = agreementKeys[fingerprint] else {
            throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
        }
        return key
    }

    func signingPrivateKey(fingerprint: String, reason: String) throws -> Data {
        throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
    }

    func isKnownSigningKey(fingerprint: String, signingPublicKey: Data) -> Bool {
        knownSigningKeys[fingerprint] == signingPublicKey
    }
}

private enum FixtureError: Error {
    case missing(String)
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
