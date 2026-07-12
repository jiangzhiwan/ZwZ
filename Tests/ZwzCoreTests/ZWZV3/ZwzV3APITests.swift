import Foundation
import XCTest
@testable import ZwzCore

final class ZwzV3APITests: XCTestCase {
    func testPublicAPIWritesV3OnlyForPublicKeyMode() throws {
        let fixture = try ZwzV3APITestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        XCTAssertEqual(try ZwzV3APITestSupport.logicalMagic(at: fixture.archive), [0x5A, 0x57, 0x5A, 0x33])
        let unsigned = try ZwzAPI().list(
            archivePath: fixture.archive.path,
            password: nil,
            keyProvider: fixture.identity.provider
        )
        XCTAssertEqual(unsigned.securityInfo?.signature, .unsigned)

        for (name, options) in [
            ("plain.zwz", CompressionOptions(format: .zwz)),
            ("password.zwz", CompressionOptions(password: "correct horse battery staple", format: .zwz))
        ] {
            let archive = fixture.directory.appendingPathComponent(name)
            _ = try ZwzAPI().compress(
                sourcePath: fixture.source.path,
                destinationPath: archive.path,
                options: options,
                keyProvider: nil
            )
            XCTAssertEqual(try ZwzV3APITestSupport.logicalMagic(at: archive), ZwzV2Format.magic)
        }
    }

    func testSingleAndSplitV3UseLogicalMagicAndReportSecurity() throws {
        for split in [nil, SplitVolume.kiloBytes(1)] {
            let fixture = try ZwzV3APITestSupport.makeFixture(signer: true, splitVolume: split)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let bob = ZwzV3IdentityFixture.make(name: "Bob")
            _ = try ZwzAPI().compress(
                sourcePath: fixture.source.path,
                destinationPath: fixture.archive.path,
                options: CompressionOptions(
                    level: .none,
                    encryption: .publicKey(
                        recipients: [fixture.identity.recipient, bob.recipient],
                        signer: fixture.identity.signingIdentity
                    ),
                    splitVolume: split,
                    format: .zwz
                ),
                keyProvider: fixture.identity.provider
            )
            for identity in [fixture.identity, bob] {
                let listing = try ZwzAPI().list(
                    archivePath: fixture.archive.path,
                    password: nil,
                    keyProvider: identity.provider
                )
                XCTAssertEqual(listing.version, 3)
                XCTAssertEqual(listing.entries.map(\.path), ["file.txt"])
                XCTAssertEqual(listing.securityInfo?.encryption, .publicKey)
                XCTAssertEqual(listing.securityInfo?.recipientFingerprints.count, 2)
                XCTAssertEqual(
                    listing.securityInfo?.signature,
                    .validUnknownSigner(name: "Alice", fingerprint: fixture.identity.signingFingerprint)
                )

                let destination = fixture.directory.appendingPathComponent("out-\(identity.recipient.name)")
                let extracted = try ZwzAPI().extract(
                    archivePath: fixture.archive.path,
                    destinationPath: destination.path,
                    password: nil,
                    keyProvider: identity.provider
                )
                XCTAssertEqual(extracted.version, 3)
                XCTAssertEqual(extracted.securityInfo, listing.securityInfo)
                XCTAssertEqual(
                    try Data(contentsOf: destination.appendingPathComponent("file.txt")),
                    Data("public api".utf8)
                )
            }
        }
    }

    func testV2DetailedMetadataComesFromHeaderFlags() throws {
        let fixture = try ZwzV3APITestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let api = ZwzAPI()
        let cases: [(String, String?, ZwzArchiveEncryptionKind)] = [
            ("v2-plain.zwz", nil, .none),
            ("v2-password.zwz", "correct horse battery staple", .password)
        ]
        for (name, password, expected) in cases {
            let archive = fixture.directory.appendingPathComponent(name)
            _ = try api.compress(
                sourcePath: fixture.source.path,
                destinationPath: archive.path,
                options: CompressionOptions(password: password, format: .zwz)
            )
            let listing = try api.list(archivePath: archive.path, password: password, keyProvider: nil)
            XCTAssertEqual(listing.version, 2)
            XCTAssertEqual(listing.securityInfo, ZwzArchiveSecurityInfo(encryption: expected))
        }
    }

    func testV2SplitDetailedListingAndExtractionRemainVersionTwo() throws {
        let fixture = try ZwzV3APITestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let payload = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0) })
        try payload.write(to: fixture.source.appendingPathComponent("large.bin"))
        let archive = fixture.directory.appendingPathComponent("v2-split.zwz")
        let api = ZwzAPI()
        _ = try api.compress(
            sourcePath: fixture.source.path,
            destinationPath: archive.path,
            options: CompressionOptions(level: .none, splitVolume: .kiloBytes(1), format: .zwz)
        )
        XCTAssertEqual(Array(try Data(contentsOf: archive).prefix(4)), ZwzV2Format.splitMagic)
        let listing = try api.list(archivePath: archive.path, password: "unused", keyProvider: nil)
        XCTAssertEqual(listing.version, 2)
        XCTAssertEqual(listing.securityInfo, ZwzArchiveSecurityInfo(encryption: .none))
        let destination = fixture.directory.appendingPathComponent("v2-split-out")
        let result = try api.extract(
            archivePath: archive.path,
            destinationPath: destination.path,
            password: "unused",
            keyProvider: nil
        )
        XCTAssertEqual(result.version, 2)
        XCTAssertEqual(result.securityInfo, listing.securityInfo)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("large.bin")), payload)
    }

    func testV3ErrorsPassThroughAdaptersUnchanged() throws {
        let fixture = try ZwzV3APITestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let expected = ZwzV3Error.userAuthenticationCancelled
        let provider = fixture.identity.provider
        provider.lookupError = expected

        XCTAssertThrowsError(try ArchivePreviewer().preview(
            archivePath: fixture.archive.path,
            keyProvider: provider
        )) { XCTAssertEqual($0 as? ZwzV3Error, expected) }
        XCTAssertThrowsError(try ArchiveExtractor().extract(
            archivePath: fixture.archive.path,
            destinationPath: fixture.directory.appendingPathComponent("failed").path,
            keyProvider: provider
        )) { XCTAssertEqual($0 as? ZwzV3Error, expected) }
    }

    func testMissingWrongAndKeychainProviderErrorsRemainConcrete() throws {
        let fixture = try ZwzV3APITestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let api = ZwzAPI()

        XCTAssertThrowsError(try api.list(
            archivePath: fixture.archive.path,
            password: nil,
            keyProvider: nil
        )) { error in
            guard case ZwzV3Error.noMatchingPrivateKey = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let wrong = ZwzV3IdentityFixture.make(name: "Mallory").provider
        XCTAssertThrowsError(try api.extractEntryToTemp(
            archivePath: fixture.archive.path,
            entryPath: "file.txt",
            keyProvider: wrong
        )) { error in
            guard case ZwzV3Error.noMatchingPrivateKey = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let failed = fixture.identity.provider
        failed.lookupError = ZwzV3Error.keychainFailure(-50)
        XCTAssertThrowsError(try api.extract(
            archivePath: fixture.archive.path,
            destinationPath: fixture.directory.appendingPathComponent("keychain-failed").path,
            keyProvider: failed
        )) { XCTAssertEqual($0 as? ZwzV3Error, .keychainFailure(-50)) }
    }

    func testInvalidSignatureAndAuthenticationErrorsPassThroughPublicAPI() throws {
        let signed = try ZwzV3APITestSupport.makeFixture(signer: true)
        defer { try? FileManager.default.removeItem(at: signed.directory) }
        let signedBytes = try Data(contentsOf: signed.archive)
        let signedParsed = try ZwzV3BinaryCodec.parse(signedBytes)
        let badSignature = try ZwzV3TestSupport.mutate(
            signed.archive,
            at: Int(signedParsed.header.signatureOffset)
        )
        XCTAssertThrowsError(try ZwzAPI().list(
            archivePath: badSignature.path,
            password: nil,
            keyProvider: signed.identity.provider
        )) { XCTAssertEqual($0 as? ZwzV3Error, .invalidSignature) }

        let unsigned = try ZwzV3APITestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: unsigned.directory) }
        let parsed = try ZwzV3BinaryCodec.parse(Data(contentsOf: unsigned.archive))
        let badIndex = try ZwzV3TestSupport.mutate(
            unsigned.archive,
            at: Int(parsed.header.encryptedIndexOffset) + 12
        )
        XCTAssertThrowsError(try ZwzAPI().list(
            archivePath: badIndex.path,
            password: nil,
            keyProvider: unsigned.identity.provider
        )) { XCTAssertEqual($0 as? ZwzV3Error, .authenticationFailed) }
    }

    func testV1UnknownAndTruncatedArchivesFailSafely() throws {
        let directory = try ZwzV3TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(String, Data)] = [
            ("v1.zwz", Data(ZwzFormat.magic + [0, 0, 0, 0])),
            ("unknown.zwz", Data("NOPE".utf8)),
            ("truncated.zwz", Data([0x5A, 0x57, 0x5A]))
        ]
        for (name, bytes) in cases {
            let archive = directory.appendingPathComponent(name)
            try bytes.write(to: archive)
            XCTAssertThrowsError(try ZwzAPI().list(
                archivePath: archive.path,
                password: nil,
                keyProvider: nil
            ))
        }
        let v1 = directory.appendingPathComponent("v1.zwz")
        XCTAssertThrowsError(try ZwzAPI().list(
            archivePath: v1.path,
            password: nil,
            keyProvider: nil
        )) { XCTAssertEqual($0 as? ZwzV2Error, .unsupportedVersion(1)) }
    }

    func testZIPIgnoresKeyProviderAndReturnsNoZwzMetadata() throws {
        let fixture = try ZwzV3APITestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let zip = fixture.directory.appendingPathComponent("archive.zip")
        _ = try ZwzAPI().compress(
            sourcePath: fixture.source.path,
            destinationPath: zip.path,
            options: CompressionOptions(
                encryption: .publicKey(recipients: [fixture.identity.recipient], signer: nil),
                format: .zip
            ),
            keyProvider: fixture.identity.provider
        )
        XCTAssertEqual(Array(try Data(contentsOf: zip).prefix(2)), [0x50, 0x4B])
        let listing = try ZwzAPI().list(archivePath: zip.path, password: nil, keyProvider: fixture.identity.provider)
        XCTAssertNil(listing.version)
        XCTAssertNil(listing.securityInfo)
        XCTAssertEqual(listing.entries.map(\.path), ["file.txt"])
    }

    func testV3SingleEntryFailureLeavesNoAdapterTemporaryDirectory() throws {
        let fixture = try ZwzV3APITestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let temporary = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path)
            .filter { $0.hasPrefix("zwz-drag-") || $0.hasPrefix("zwz-v3-entry-") })
        XCTAssertThrowsError(try ArchiveExtractor().extractEntryToTemp(
            archivePath: fixture.archive.path,
            entryPath: "missing.txt",
            keyProvider: fixture.identity.provider
        ))
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path)
            .filter { $0.hasPrefix("zwz-drag-") || $0.hasPrefix("zwz-v3-entry-") })
        XCTAssertEqual(after, before)
    }

    func testLegacySignaturesKeepTheirShapes() throws {
        let fixture = try ZwzV3APITestSupport.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let api = ZwzAPI()
        let archive = fixture.directory.appendingPathComponent("legacy-v2.zwz")
        _ = try api.compress(
            sourcePath: fixture.source.path,
            destinationPath: archive.path,
            options: CompressionOptions(format: .zwz)
        )
        let entries: [ArchiveEntry] = try api.list(archivePath: archive.path)
        let output: String = try api.extract(
            archivePath: archive.path,
            destinationPath: fixture.directory.appendingPathComponent("legacy-out").path
        )
        let entry: URL = try api.extractEntryToTemp(
            archivePath: archive.path,
            entryPath: "file.txt"
        )
        XCTAssertFalse(entries.isEmpty)
        XCTAssertFalse(output.isEmpty)
        XCTAssertEqual(try Data(contentsOf: entry), Data("public api".utf8))
    }
}
