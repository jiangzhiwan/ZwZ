import CryptoKit
import XCTest
@testable import ZwzCore

final class ZwzV3CryptoTests: XCTestCase {
    func testAnyRecipientCanUnwrapSameContentKey() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let contentKey = SymmetricKey(size: .bits256)
        let archiveID = UUID()
        let envelopes = try ZwzV3Crypto.wrap(contentKey: contentKey, recipients: [
            recipient(named: "Alice", key: alice),
            recipient(named: "Bob", key: bob)
        ], archiveID: archiveID)

        XCTAssertEqual(
            try ZwzV3Crypto.unwrap(envelopes[0], privateKey: alice, archiveID: archiveID).testBytes,
            contentKey.testBytes
        )
        XCTAssertEqual(
            try ZwzV3Crypto.unwrap(envelopes[1], privateKey: bob, archiveID: archiveID).testBytes,
            contentKey.testBytes
        )
        XCTAssertEqual(envelopes[0].ephemeralPublicKey, envelopes[1].ephemeralPublicKey)
        XCTAssertNotEqual(envelopes[0].nonce, envelopes[1].nonce)
    }

    func testWrongRecipientFailsWithoutLeakingCryptoDetails() throws {
        let fixture = try makeWrappedFixture()

        XCTAssertThrowsError(try ZwzV3Crypto.unwrap(
            fixture.envelopes[0], privateKey: fixture.wrongKey, archiveID: fixture.archiveID
        )) { error in
            XCTAssertEqual(error as? ZwzV3Error, .keyUnwrapFailed)
        }
    }

    func testEveryEnvelopeByteMutationFailsAuthentication() throws {
        let fixture = try makeWrappedFixture()
        let envelope = fixture.envelopes[0]

        for index in envelope.nonce.indices {
            var mutated = envelope
            mutated.nonce[index] ^= 0x01
            XCTAssertThrowsError(try ZwzV3Crypto.unwrap(
                mutated, privateKey: fixture.recipientKey, archiveID: fixture.archiveID
            ))
        }
        for index in envelope.encryptedContentKey.indices {
            var mutated = envelope
            mutated.encryptedContentKey[index] ^= 0x01
            XCTAssertThrowsError(try ZwzV3Crypto.unwrap(
                mutated, privateKey: fixture.recipientKey, archiveID: fixture.archiveID
            ))
        }
        for index in envelope.authenticationTag.indices {
            var mutated = envelope
            mutated.authenticationTag[index] ^= 0x01
            XCTAssertThrowsError(try ZwzV3Crypto.unwrap(
                mutated, privateKey: fixture.recipientKey, archiveID: fixture.archiveID
            ))
        }
    }

    func testAuthenticatedMetadataMutationFailsUnwrap() throws {
        let fixture = try makeWrappedFixture()
        let envelope = fixture.envelopes[0]
        let changedFingerprint = ZwzV3RecipientEnvelope(
            recipientName: envelope.recipientName,
            recipientFingerprint: envelope.recipientFingerprint + "0",
            ephemeralPublicKey: envelope.ephemeralPublicKey,
            nonce: envelope.nonce,
            encryptedContentKey: envelope.encryptedContentKey,
            authenticationTag: envelope.authenticationTag
        )
        var ephemeralPublicKey = envelope.ephemeralPublicKey
        ephemeralPublicKey[0] ^= 0x01
        let changedEphemeralKey = ZwzV3RecipientEnvelope(
            recipientName: envelope.recipientName,
            recipientFingerprint: envelope.recipientFingerprint,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: envelope.nonce,
            encryptedContentKey: envelope.encryptedContentKey,
            authenticationTag: envelope.authenticationTag
        )

        XCTAssertThrowsError(try ZwzV3Crypto.unwrap(
            changedFingerprint, privateKey: fixture.recipientKey, archiveID: fixture.archiveID
        ))
        XCTAssertThrowsError(try ZwzV3Crypto.unwrap(
            changedEphemeralKey, privateKey: fixture.recipientKey, archiveID: fixture.archiveID
        ))
        XCTAssertThrowsError(try ZwzV3Crypto.unwrap(
            envelope, privateKey: fixture.recipientKey, archiveID: UUID()
        ))
    }

    func testSealRoundTripsAndChangedAADFailsAuthentication() throws {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let sealed = try ZwzV3Crypto.seal(
            Data("payload".utf8), key: key, nonce: nonce, aad: Data("header".utf8)
        )

        XCTAssertEqual(
            try ZwzV3Crypto.open(sealed, key: key, aad: Data("header".utf8)),
            Data("payload".utf8)
        )
        XCTAssertThrowsError(try ZwzV3Crypto.open(
            sealed, key: key, aad: Data("Header".utf8)
        )) { error in
            XCTAssertEqual(error as? ZwzV3Error, .authenticationFailed)
        }
    }

    func testEd25519SignatureRejectsChangedCanonicalBytes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let original = Data("archive".utf8)
        let signature = try ZwzV3Crypto.sign(original, privateKey: key)

        XCTAssertTrue(ZwzV3Crypto.verify(
            signature, bytes: original, publicKey: key.publicKey.rawRepresentation
        ))
        XCTAssertFalse(ZwzV3Crypto.verify(
            signature, bytes: Data("Archive".utf8), publicKey: key.publicKey.rawRepresentation
        ))
        XCTAssertFalse(ZwzV3Crypto.verify(
            signature, bytes: original, publicKey: Data(repeating: 0, count: 3)
        ))
    }

    private func recipient(
        named name: String,
        key: Curve25519.KeyAgreement.PrivateKey
    ) -> ZwzRecipient {
        let publicKey = key.publicKey.rawRepresentation
        return ZwzRecipient(
            name: name,
            fingerprint: ZwzV3Crypto.fingerprint(agreement: publicKey, signing: nil),
            agreementPublicKey: publicKey
        )
    }
}
