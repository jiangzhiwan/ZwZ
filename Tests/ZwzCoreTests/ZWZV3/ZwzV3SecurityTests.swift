import CryptoKit
import Foundation
import XCTest
@testable import ZwzCore

final class ZwzV3SecurityTests: XCTestCase {
    private enum KeychainFailure: Error, Equatable {
        case unavailable
    }

    func testWrongRecipientAndCancelledAuthenticationRemainDistinct() throws {
        let fixture = try makeArchive(signed: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let mallory = ZwzV3IdentityFixture.make(name: "Mallory")
        XCTAssertThrowsError(try ZwzV3Extractor().listEntries(
            archivePath: fixture.archive.path,
            keyProvider: mallory.provider
        )) { error in
            guard case ZwzV3Error.noMatchingPrivateKey = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let cancelled = ZwzV3MemoryKeyProvider()
        cancelled.lookupError = ZwzV3Error.userAuthenticationCancelled
        XCTAssertThrowsError(try ZwzV3Extractor().listEntries(
            archivePath: fixture.archive.path,
            keyProvider: cancelled
        )) { error in
            XCTAssertEqual(error as? ZwzV3Error, .userAuthenticationCancelled)
        }
    }

    func testUnsignedMutationsOfEveryAuthenticatedRegionFailBeforeListingPaths() throws {
        let fixture = try makeArchive(signed: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let archiveBytes = try Data(contentsOf: fixture.archive)
        let parsed = try ZwzV3BinaryCodec.parse(archiveBytes)
        let offsets = [
            13,
            Int(parsed.header.recipientRegionOffset) + 8,
            Int(parsed.header.recipientRegionOffset) + 48,
            Int(parsed.header.dataRegionOffset) + 4,
            Int(parsed.header.dataRegionOffset) + 16,
            Int(parsed.header.dataRegionOffset) + 24,
            Int(parsed.header.dataRegionOffset) + 36,
            Int(parsed.header.dataRegionOffset) + 24
                + Int(readUInt32(archiveBytes, at: Int(parsed.header.dataRegionOffset) + 20)) - 1,
            Int(parsed.header.encryptedIndexOffset) + 12,
        ]
        for offset in offsets {
            let mutated = try ZwzV3TestSupport.mutate(fixture.archive, at: offset)
            XCTAssertThrowsError(try ZwzV3Extractor().listEntries(
                archivePath: mutated.path,
                keyProvider: fixture.identity.provider
            ), "mutation at \(offset) was accepted")
        }
    }

    func testSignedArchiveReportsKnownAndUnknownSignerAndRejectsMutations() throws {
        let fixture = try makeArchive(signed: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let unknown = fixture.identity.provider
        let unknownListing = try ZwzV3Extractor().listEntries(
            archivePath: fixture.archive.path,
            keyProvider: unknown
        )
        XCTAssertEqual(
            unknownListing.securityInfo.signature,
            .validUnknownSigner(name: fixture.identity.signingIdentity.name, fingerprint: fixture.identity.signingFingerprint)
        )

        let known = fixture.identity.provider
        known.knownSigningKeys[fixture.identity.signingFingerprint]
            = fixture.identity.signingIdentity.signingPublicKey
        let knownListing = try ZwzV3Extractor().listEntries(archivePath: fixture.archive.path, keyProvider: known)
        XCTAssertEqual(
            knownListing.securityInfo.signature,
            .validKnownSigner(name: fixture.identity.signingIdentity.name, fingerprint: fixture.identity.signingFingerprint)
        )

        let parsed = try ZwzV3BinaryCodec.parse(Data(contentsOf: fixture.archive))
        for offset in [Int(parsed.header.signerRegionOffset) + 8, Int(parsed.header.signatureOffset)] {
            let mutated = try ZwzV3TestSupport.mutate(fixture.archive, at: offset)
            XCTAssertThrowsError(try ZwzV3Extractor().listEntries(
                archivePath: mutated.path,
                keyProvider: known
            )) { error in
                XCTAssertEqual(error as? ZwzV3Error, .invalidSignature)
            }
        }
    }

    func testKnownFingerprintWithDifferentValidSigningKeyRemainsUnknown() throws {
        let fixture = try makeArchive(signed: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let parsed = try ZwzV3BinaryCodec.parse(Data(contentsOf: fixture.archive))
        let attacker = Curve25519.Signing.PrivateKey()
        let placeholder = ZwzV3SignerRecord(
            name: "Attacker",
            fingerprint: fixture.identity.signingFingerprint,
            signingPublicKey: attacker.publicKey.rawRepresentation,
            signature: Data(repeating: 0, count: 64)
        )
        var forged = try ZwzV3ArchiveCodec.encode(
            recipients: parsed.recipients,
            dataRegion: parsed.dataRegion,
            encryptedIndex: parsed.encryptedIndex,
            signer: placeholder,
            archiveID: parsed.header.archiveID,
            dataBlockCount: parsed.header.dataBlockCount
        )
        let unsigned = try ZwzV3BinaryCodec.parse(forged)
        let signature = try ZwzV3Crypto.sign(unsigned.canonicalSignedBytes, privateKey: attacker)
        forged.replaceSubrange(
            Int(unsigned.header.signatureOffset)..<(Int(unsigned.header.signatureOffset) + 64),
            with: signature
        )
        let url = fixture.directory.appendingPathComponent("forged-known-fingerprint.zwz")
        try forged.write(to: url)
        let provider = fixture.identity.provider
        provider.knownSigningKeys[fixture.identity.signingFingerprint]
            = fixture.identity.signingIdentity.signingPublicKey

        let listing = try ZwzV3Extractor().listEntries(archivePath: url.path, keyProvider: provider)
        XCTAssertEqual(
            listing.securityInfo.signature,
            .validUnknownSigner(name: "Attacker", fingerprint: fixture.identity.signingFingerprint)
        )
    }

    func testNonMissingProviderFailureIsPropagated() throws {
        let fixture = try makeArchive(signed: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let provider = ZwzV3MemoryKeyProvider()
        provider.lookupError = KeychainFailure.unavailable
        XCTAssertThrowsError(try ZwzV3Extractor().listEntries(
            archivePath: fixture.archive.path,
            keyProvider: provider
        )) { error in
            XCTAssertEqual(error as? KeychainFailure, .unavailable)
        }
    }

    func testSecondMatchingEnvelopeCanSucceedAfterFirstKeyFails() throws {
        let directory = try ZwzV3TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZwzV3TestSupport.makeSource(in: directory)
        let identity = ZwzV3IdentityFixture.make(name: "Alice")
        let archive = directory.appendingPathComponent("duplicate-recipient.zwz")
        try ZwzV3Compressor().compress(
            sourcePath: source.path,
            destinationPath: archive.path,
            options: CompressionOptions(
                encryption: .publicKey(
                    recipients: [identity.recipient, identity.recipient],
                    signer: nil
                ),
                format: .zwz
            ),
            keyProvider: nil,
            progress: nil,
            cancellationToken: nil
        )
        let provider = identity.provider
        provider.agreementKeyResponses[identity.recipient.fingerprint] = [
            .success(Data(repeating: 0, count: 31)),
            .success(identity.agreementPrivateKey),
        ]
        XCTAssertFalse(try ZwzV3Extractor().listEntries(
            archivePath: archive.path,
            keyProvider: provider
        ).entries.isEmpty)
    }

    func testSigningPrivateKeyMustMatchSelectedFingerprint() throws {
        let directory = try ZwzV3TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZwzV3TestSupport.makeSource(in: directory)
        let identity = ZwzV3IdentityFixture.make(name: "Alice")
        let wrong = Curve25519.Signing.PrivateKey()
        let provider = identity.provider
        provider.signingKeys[identity.signingFingerprint] = wrong.rawRepresentation
        XCTAssertThrowsError(try ZwzV3Compressor().compress(
            sourcePath: source.path,
            destinationPath: directory.appendingPathComponent("mismatch.zwz").path,
            options: CompressionOptions(
                encryption: .publicKey(recipients: [identity.recipient], signer: identity.signingIdentity),
                format: .zwz
            ),
            keyProvider: provider,
            progress: nil,
            cancellationToken: nil
        ))
    }

    func testSignerDoesNotNeedToBeARecipient() throws {
        let directory = try ZwzV3TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZwzV3TestSupport.makeSource(in: directory)
        let recipient = ZwzV3IdentityFixture.make(name: "Recipient")
        let sender = ZwzV3IdentityFixture.make(name: "Sender")
        let signingProvider = sender.provider
        let archive = directory.appendingPathComponent("independent-signer.zwz")
        try ZwzV3Compressor().compress(
            sourcePath: source.path,
            destinationPath: archive.path,
            options: CompressionOptions(
                encryption: .publicKey(
                    recipients: [recipient.recipient],
                    signer: sender.signingIdentity
                ),
                format: .zwz
            ),
            keyProvider: signingProvider,
            progress: nil,
            cancellationToken: nil
        )

        let listing = try ZwzV3Extractor().listEntries(
            archivePath: archive.path,
            keyProvider: recipient.provider
        )
        XCTAssertEqual(
            listing.securityInfo.signature,
            .validUnknownSigner(name: "Sender", fingerprint: sender.signingFingerprint)
        )
    }

    func testMaliciousRecordLengthsAndCountsNeverTrap() throws {
        let fixture = try makeArchive(signed: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let parsed = try ZwzV3BinaryCodec.parse(Data(contentsOf: fixture.archive))
        for mutation in [(Int(parsed.header.dataRegionOffset), UInt32.max), (120, UInt32.max)] {
            var bytes = try Data(contentsOf: fixture.archive)
            Data.writeUInt32(mutation.1, at: mutation.0, in: &bytes)
            let url = fixture.directory.appendingPathComponent("malicious-\(mutation.0).zwz")
            try bytes.write(to: url)
            XCTAssertThrowsError(try ZwzV3Extractor().listEntries(
                archivePath: url.path,
                keyProvider: fixture.identity.provider
            ))
        }
    }

    func testAuthenticatedIndexWithDescriptorOffsetMismatchIsRejected() throws {
        let directory = try ZwzV3TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = ZwzV3IdentityFixture.make(name: "Alice")
        let archiveID = UUID()
        let contentKey = SymmetricKey(size: .bits256)
        let envelopes = try ZwzV3Crypto.wrap(
            contentKey: contentKey,
            recipients: [identity.recipient],
            archiveID: archiveID
        )
        let recipientRegion = try envelopes.reduce(into: Data()) {
            $0.append(try ZwzV3BinaryCodec.encodeRecipient($1))
        }
        let plain = Data("payload".utf8)
        let encoded = try ZwzV2BlockCodec.encode(plain, level: .none)
        let sealed = try ZwzV3Crypto.seal(
            encoded.payload,
            key: contentKey,
            nonce: AES.GCM.Nonce(),
            aad: ZwzV3PayloadCodec.blockAAD(
                archiveID: archiveID,
                sequence: 0,
                codec: encoded.codec,
                originalLength: UInt32(plain.count)
            )
        )
        let dataRegion = try ZwzV3PayloadCodec.encodeRecord(
            sequence: 0,
            codec: encoded.codec,
            originalLength: UInt32(plain.count),
            sealed: sealed
        )
        let canonicalOffset = UInt64(ZwzV3Header.encodedLength + recipientRegion.count)
        let index = ZwzV2Index(
            archiveID: archiveID,
            blockSize: 4_096,
            entries: [ZwzV2Entry(
                path: "file.txt",
                type: .file,
                originalSize: UInt64(plain.count),
                modificationTime: Date(timeIntervalSince1970: 0),
                isHidden: false,
                blocks: [ZwzV2BlockDescriptor(
                    sequence: 0,
                    fileOffset: 0,
                    archiveOffset: canonicalOffset + 1,
                    storedLength: UInt32(sealed.count),
                    originalLength: UInt32(plain.count),
                    codec: encoded.codec,
                    checksum: encoded.checksum,
                    authenticationTag: []
                )]
            )]
        )
        let encryptedIndex = try ZwzV3Crypto.seal(
            ZwzV2IndexCodec.encodePlain(index),
            key: contentKey,
            nonce: AES.GCM.Nonce(),
            aad: ZwzV3PayloadCodec.indexAAD(
                archiveID: archiveID,
                recipientCount: 1,
                recipientRegion: recipientRegion,
                dataBlockCount: 1,
                dataRegion: dataRegion,
                signatureAlgorithm: .none
            )
        )
        let archive = try ZwzV3ArchiveCodec.encode(
            recipients: envelopes,
            dataRegion: dataRegion,
            encryptedIndex: encryptedIndex,
            signer: nil,
            archiveID: archiveID,
            dataBlockCount: 1
        )
        let url = directory.appendingPathComponent("offset-mismatch.zwz")
        try archive.write(to: url)
        XCTAssertThrowsError(try ZwzV3Extractor().listEntries(
            archivePath: url.path,
            keyProvider: identity.provider
        )) { error in
            guard case ZwzV3Error.malformedArchive = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testExistingSymlinkTraversalIsRejectedAndPartialFileIsRemoved() throws {
        let fixture = try makeArchive(signed: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let destination = fixture.directory.appendingPathComponent("out")
        let outside = fixture.directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("nested"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try ZwzV3Extractor().extractAll(
            archivePath: fixture.archive.path,
            destinationPath: destination.path,
            keyProvider: fixture.identity.provider,
            progress: nil,
            cancellationToken: nil
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("multi.bin").path))
    }

    func testExtractionCancellationRemovesTheCurrentPartialFile() throws {
        let fixture = try makeArchive(signed: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let destination = fixture.directory.appendingPathComponent("cancelled-out")
        let token = CancellationToken()
        XCTAssertThrowsError(try ZwzV3Extractor().extractAll(
            archivePath: fixture.archive.path,
            destinationPath: destination.path,
            keyProvider: fixture.identity.provider,
            progress: { value in if value > 0 { token.cancel() } },
            cancellationToken: token
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".hidden").path))
    }

    private func makeArchive(signed: Bool) throws -> (
        directory: URL, archive: URL, identity: ZwzV3IdentityFixture
    ) {
        let directory = try ZwzV3TestSupport.makeTempDirectory()
        let source = try ZwzV3TestSupport.makeSource(in: directory)
        let identity = ZwzV3IdentityFixture.make(name: "Alice")
        let archive = directory.appendingPathComponent(signed ? "signed.zwz" : "unsigned.zwz")
        try ZwzV3Compressor(blockSize: 4_096).compress(
            sourcePath: source.path,
            destinationPath: archive.path,
            options: CompressionOptions(
                encryption: .publicKey(
                    recipients: [identity.recipient],
                    signer: signed ? identity.signingIdentity : nil
                ),
                format: .zwz
            ),
            keyProvider: signed ? identity.provider : nil,
            progress: nil,
            cancellationToken: nil
        )
        return (directory, archive, identity)
    }


    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].enumerated().reduce(into: UInt32.zero) { value, byte in
            value |= UInt32(byte.element) << (byte.offset * 8)
        }
    }
}
