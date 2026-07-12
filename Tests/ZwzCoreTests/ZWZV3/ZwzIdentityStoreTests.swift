import CryptoKit
import Foundation
import Security
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
        let original = try XCTUnwrap(try store.identities().first)
        XCTAssertThrowsError(try store.importPrivateBackup(
            backup, password: "correct horse battery staple", conflict: .requireConfirmation
        )) { XCTAssertEqual($0 as? ZwzV3Error, .identityConflict(
            try! ZwzKeyFileTestSupport.privateIdentity().fingerprint
        )) }
        _ = try store.importPrivateBackup(
            backup, password: "correct horse battery staple", conflict: .replaceExisting
        )
        let preserved = try XCTUnwrap(try store.identities().first)
        XCTAssertEqual(preserved.creationDate, original.creationDate)
        let agreementPrivate = try store.agreementPrivateKey(
            fingerprint: preserved.fingerprint, reason: "Decrypt"
        )
        let renamedPublic = ZwzPublicIdentity(
            name: "Alice Public Rename",
            fingerprint: preserved.fingerprint,
            agreementPublicKey: preserved.agreementPublicKey,
            signingPublicKey: preserved.signingPublicKey
        )
        _ = try store.importPublicIdentity(
            ZwzKeyFileCodec.encodePublic(renamedPublic), conflict: .replaceExisting
        )
        let renamed = try XCTUnwrap(try store.identities().first)
        XCTAssertEqual(renamed.name, "Alice Public Rename")
        XCTAssertEqual(renamed.creationDate, preserved.creationDate)
        XCTAssertTrue(try store.contacts().isEmpty)
        XCTAssertEqual(
            try store.agreementPrivateKey(fingerprint: preserved.fingerprint, reason: "Decrypt"),
            agreementPrivate
        )
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

    func testMacReplaceIdentityUpdateFailurePreservesMetadataAndPrivateKeys() throws {
        let fixture = try ZwzKeyFileTestSupport.privateIdentity(name: "Old Name")
        let publicIdentity = try fixture.publicIdentity
        let oldMetadata = ZwzIdentityMetadata(
            name: "Old Name",
            fingerprint: fixture.fingerprint,
            agreementPublicKey: publicIdentity.agreementPublicKey,
            signingPublicKey: publicIdentity.signingPublicKey,
            creationDate: Date(timeIntervalSince1970: 123)
        )
        let backend = FakeZwzKeychainBackend()
        backend.seed(
            kind: .identity,
            fingerprint: fixture.fingerprint,
            data: try JSONEncoder().encode(oldMetadata)
        )
        backend.seed(
            kind: .agreement,
            fingerprint: fixture.fingerprint,
            data: fixture.agreementPrivateKey
        )
        backend.seed(
            kind: .signing,
            fingerprint: fixture.fingerprint,
            data: fixture.signingPrivateKey
        )
        backend.updateFailures[.identity] = errSecInteractionNotAllowed
        let store = MacKeychainIdentityStore(backend: backend)

        var replacement = fixture
        replacement = ZwzPrivateIdentity(
            name: "New Name",
            fingerprint: replacement.fingerprint,
            agreementPrivateKey: replacement.agreementPrivateKey,
            signingPrivateKey: replacement.signingPrivateKey
        )
        XCTAssertThrowsError(try store.importPrivateIdentity(
            replacement, conflict: .replaceExisting
        )) { XCTAssertEqual($0 as? ZwzV3Error, .keychainFailure(errSecInteractionNotAllowed)) }

        XCTAssertEqual(try store.identities(), [oldMetadata])
        XCTAssertEqual(
            try store.agreementPrivateKey(fingerprint: fixture.fingerprint, reason: "Decrypt"),
            fixture.agreementPrivateKey
        )
        XCTAssertEqual(
            try store.signingPrivateKey(fingerprint: fixture.fingerprint, reason: "Sign"),
            fixture.signingPrivateKey
        )

        backend.updateFailures.removeValue(forKey: .identity)
        let replacementPublic = try replacement.publicIdentity
        let priorWriteCount = backend.transactionWrites.count
        _ = try store.importPublicIdentity(
            ZwzKeyFileCodec.encodePublic(replacementPublic),
            conflict: .replaceExisting
        )
        XCTAssertEqual(
            Array(backend.transactionWrites.dropFirst(priorWriteCount)),
            [.update(.identity)]
        )
        let renamed = try XCTUnwrap(try store.identities().first)
        XCTAssertEqual(renamed.name, "New Name")
        XCTAssertEqual(renamed.creationDate, oldMetadata.creationDate)
        XCTAssertTrue(try store.contacts().isEmpty)
        XCTAssertEqual(
            try store.agreementPrivateKey(fingerprint: fixture.fingerprint, reason: "Decrypt"),
            fixture.agreementPrivateKey
        )
    }

    func testMacContactUpgradeFailuresRollbackNewItemsAndPreserveContact() throws {
        let identity = try ZwzKeyFileTestSupport.privateIdentity()
        let contact = try identity.publicIdentity

        for failureKind in [ZwzKeychainItemKind.signing, .identity] {
            let backend = FakeZwzKeychainBackend()
            backend.seed(
                kind: .contact,
                fingerprint: identity.fingerprint,
                data: try JSONEncoder().encode(contact)
            )
            backend.addFailures[failureKind] = errSecInteractionNotAllowed
            let store = MacKeychainIdentityStore(backend: backend)

            XCTAssertThrowsError(try store.importPrivateIdentity(
                identity, conflict: .replaceExisting
            ))
            XCTAssertEqual(try store.contacts(), [contact])
            XCTAssertTrue(try store.identities().isEmpty)
            XCTAssertNil(backend.data(kind: .agreement, fingerprint: identity.fingerprint))
            XCTAssertNil(backend.data(kind: .signing, fingerprint: identity.fingerprint))
            XCTAssertNil(backend.data(kind: .identity, fingerprint: identity.fingerprint))
        }

        let backend = FakeZwzKeychainBackend()
        backend.seed(
            kind: .contact,
            fingerprint: identity.fingerprint,
            data: try JSONEncoder().encode(contact)
        )
        backend.deleteFailures[.contact] = errSecInteractionNotAllowed
        let store = MacKeychainIdentityStore(backend: backend)
        XCTAssertThrowsError(try store.importPrivateIdentity(
            identity, conflict: .replaceExisting
        ))
        XCTAssertEqual(try store.contacts(), [contact])
        XCTAssertTrue(try store.identities().isEmpty)
        XCTAssertNil(backend.data(kind: .agreement, fingerprint: identity.fingerprint))
        XCTAssertNil(backend.data(kind: .signing, fingerprint: identity.fingerprint))
    }

    func testMacContactUpgradeCommitsIdentityBeforeRemovingContact() throws {
        let identity = try ZwzKeyFileTestSupport.privateIdentity()
        let contact = try identity.publicIdentity
        let backend = FakeZwzKeychainBackend()
        backend.seed(
            kind: .contact,
            fingerprint: identity.fingerprint,
            data: try JSONEncoder().encode(contact)
        )
        let store = MacKeychainIdentityStore(backend: backend)

        let metadata = try store.importPrivateIdentity(identity, conflict: .replaceExisting)

        XCTAssertEqual(try store.identities().map(\.fingerprint), [metadata.fingerprint])
        XCTAssertTrue(try store.contacts().isEmpty)
        XCTAssertEqual(
            backend.transactionWrites,
            [.add(.agreement), .add(.signing), .add(.identity), .delete(.contact)]
        )
    }

    func testMacStoreSerializesConcurrentPublicOperations() throws {
        let backend = FakeZwzKeychainBackend()
        backend.operationDelay = 0.01
        let store = MacKeychainIdentityStore(backend: backend)

        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            _ = try? store.contacts()
        }

        XCTAssertEqual(backend.maximumConcurrentCalls, 1)
    }

    func testMacDeleteAttemptsEveryItemAfterFirstFailure() throws {
        let identity = try ZwzKeyFileTestSupport.privateIdentity()
        let backend = FakeZwzKeychainBackend()
        for kind in [
            ZwzKeychainItemKind.identity, .contact, .agreement, .signing
        ] {
            backend.seed(kind: kind, fingerprint: identity.fingerprint, data: Data([1]))
        }
        backend.deleteFailures[.identity] = errSecInteractionNotAllowed
        let store = MacKeychainIdentityStore(backend: backend)

        XCTAssertThrowsError(try store.delete(fingerprint: identity.fingerprint)) {
            XCTAssertEqual($0 as? ZwzV3Error, .keychainFailure(errSecInteractionNotAllowed))
        }
        XCTAssertEqual(backend.deleteCalls, [.identity, .contact, .agreement, .signing])
        XCTAssertNotNil(backend.data(kind: .identity, fingerprint: identity.fingerprint))
        XCTAssertNil(backend.data(kind: .contact, fingerprint: identity.fingerprint))
        XCTAssertNil(backend.data(kind: .agreement, fingerprint: identity.fingerprint))
        XCTAssertNil(backend.data(kind: .signing, fingerprint: identity.fingerprint))
    }
}
