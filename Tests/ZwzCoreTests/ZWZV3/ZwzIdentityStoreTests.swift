import CryptoKit
import XCTest
@testable import ZwzCore

final class ZwzIdentityStoreTests: XCTestCase {
    func testCreateRenameExportAndDeletePreserveKeyBinding() throws {
        let store = InMemoryZwzIdentityStore()
        XCTAssertThrowsError(try store.createIdentity(named: "   ")) {
            XCTAssertEqual($0 as? ZwzV3Error, .invalidIdentityName)
        }
        let created = try store.createIdentity(named: "Alice")
        XCTAssertEqual(try store.identities().map(\.fingerprint), [created.fingerprint])

        let exported = try store.exportPublicIdentity(fingerprint: created.fingerprint)
        let publicIdentity = try ZwzKeyFileCodec.decodePublic(exported)
        XCTAssertEqual(publicIdentity.fingerprint, created.fingerprint)

        try store.rename(fingerprint: created.fingerprint, to: "Alice Renamed")
        let renamed = try XCTUnwrap(try store.identities().first)
        XCTAssertEqual(renamed.name, "Alice Renamed")
        XCTAssertEqual(renamed.fingerprint, created.fingerprint)
        XCTAssertEqual(renamed.agreementPublicKey, created.agreementPublicKey)
        XCTAssertEqual(renamed.signingPublicKey, created.signingPublicKey)

        try store.delete(fingerprint: created.fingerprint)
        XCTAssertTrue(try store.identities().isEmpty)
        XCTAssertThrowsError(try store.agreementPrivateKey(
            fingerprint: created.fingerprint, reason: "Decrypt"
        )) { XCTAssertEqual($0 as? ZwzV3Error, .noMatchingPrivateKey([created.fingerprint])) }
    }

    func testDuplicateIdentityRequiresExplicitReplacement() throws {
        let store = InMemoryZwzIdentityStore()
        let backup = try ZwzKeyFileTestSupport.backup()
        _ = try store.importPrivateBackup(
            backup, password: "correct horse battery staple", conflict: .requireConfirmation
        )
        XCTAssertThrowsError(try store.importPrivateBackup(
            backup, password: "correct horse battery staple", conflict: .requireConfirmation
        )) { XCTAssertEqual($0 as? ZwzV3Error, .identityConflict(
            try! ZwzKeyFileTestSupport.privateIdentity().fingerprint
        )) }
        _ = try store.importPrivateBackup(
            backup, password: "correct horse battery staple", conflict: .replaceExisting
        )
        XCTAssertEqual(try store.identities().count, 1)
    }

    func testContactTrustRequiresFingerprintAndSigningKeyBinding() throws {
        let store = InMemoryZwzIdentityStore()
        let identity = try ZwzKeyFileTestSupport.publicIdentity()
        let encoded = try ZwzKeyFileCodec.encodePublic(identity)
        _ = try store.importPublicIdentity(encoded, conflict: .requireConfirmation)

        XCTAssertTrue(store.isKnownSigningKey(
            fingerprint: identity.fingerprint, signingPublicKey: identity.signingPublicKey
        ))
        XCTAssertFalse(store.isKnownSigningKey(
            fingerprint: identity.fingerprint, signingPublicKey: Data(repeating: 7, count: 32)
        ))
        XCTAssertFalse(store.isKnownSigningKey(
            fingerprint: String(repeating: "0", count: 64),
            signingPublicKey: identity.signingPublicKey
        ))

        try store.rename(fingerprint: identity.fingerprint, to: "Alice Contact")
        let renamed = try XCTUnwrap(try store.contacts().first)
        XCTAssertEqual(renamed.name, "Alice Contact")
        XCTAssertEqual(renamed.fingerprint, identity.fingerprint)
        XCTAssertEqual(renamed.signingPublicKey, identity.signingPublicKey)
        XCTAssertThrowsError(try store.agreementPrivateKey(
            fingerprint: identity.fingerprint, reason: "Decrypt"
        ))

        try store.delete(fingerprint: identity.fingerprint)
        XCTAssertTrue(try store.contacts().isEmpty)
        XCTAssertFalse(store.isKnownSigningKey(
            fingerprint: identity.fingerprint, signingPublicKey: identity.signingPublicKey
        ))
    }

    func testRestoredIdentityDecryptsAndSigns() throws {
        let store = InMemoryZwzIdentityStore()
        let metadata = try store.importPrivateBackup(
            ZwzKeyFileTestSupport.backup(),
            password: "correct horse battery staple",
            conflict: .requireConfirmation
        )
        let agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation:
            store.agreementPrivateKey(fingerprint: metadata.fingerprint, reason: "Decrypt")
        )
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation:
            store.signingPrivateKey(fingerprint: metadata.fingerprint, reason: "Sign")
        )
        XCTAssertEqual(agreement.publicKey.rawRepresentation, metadata.agreementPublicKey)
        let message = Data("message".utf8)
        XCTAssertTrue(signing.publicKey.isValidSignature(try signing.signature(for: message), for: message))
    }

    func testFailedTransactionalImportLeavesNoPartialIdentity() throws {
        let store = InMemoryZwzIdentityStore(importFailurePoint: .afterAgreementPrivateKey)
        XCTAssertThrowsError(try store.importPrivateBackup(
            ZwzKeyFileTestSupport.backup(),
            password: "correct horse battery staple",
            conflict: .requireConfirmation
        ))
        XCTAssertTrue(try store.identities().isEmpty)
    }

    func testProviderCancellationAndFailureRemainDistinct() throws {
        let cancelled = InMemoryZwzIdentityStore(providerFailure: .userAuthenticationCancelled)
        XCTAssertThrowsError(try cancelled.agreementPrivateKey(
            fingerprint: "fingerprint", reason: "Decrypt"
        )) { XCTAssertEqual($0 as? ZwzV3Error, .userAuthenticationCancelled) }

        let failed = InMemoryZwzIdentityStore(providerFailure: .keychainFailure(-50))
        XCTAssertThrowsError(try failed.signingPrivateKey(
            fingerprint: "fingerprint", reason: "Sign"
        )) { XCTAssertEqual($0 as? ZwzV3Error, .keychainFailure(-50)) }
    }
}
