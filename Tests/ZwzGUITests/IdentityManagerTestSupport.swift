import CryptoKit
import Foundation
import ZwzCore
@testable import ZwzGUI

final class IdentityManagerControlledStore: ZwzIdentityStore, @unchecked Sendable {
    enum Operation: Hashable, Sendable {
        case create
        case identities
        case contacts
        case importPublic
        case exportPublic
        case exportBackup
        case restoreBackup
        case rename
        case delete
    }

    private let lock = NSLock()
    private var storedIdentities: [String: ZwzIdentityMetadata]
    private var storedContacts: [String: ZwzPublicIdentity]
    private var failures: [Operation: ZwzV3Error] = [:]
    private var calls: [Operation: Int] = [:]
    private var mainThreadCalls: Set<Operation> = []
    private var nextIdentityIndex = 30
    private var delay: TimeInterval = 0
    private var listingDelay: TimeInterval = 0

    let rawAgreementPrivateKey = Data((1...32).map(UInt8.init))
    let rawSigningPrivateKey = Data((65...96).map(UInt8.init))
    let encryptedBackup = Data("ZWZK-encrypted-test-backup".utf8)
    let restorableIdentity: ZwzIdentityMetadata

    init(
        identities: [ZwzIdentityMetadata] = [],
        contacts: [ZwzPublicIdentity] = [],
        restorableIdentity: ZwzIdentityMetadata = IdentityManagerTestSupport.identity(
            name: "Restored Mac", seed: 12
        )
    ) {
        storedIdentities = Dictionary(uniqueKeysWithValues: identities.map { ($0.fingerprint, $0) })
        storedContacts = Dictionary(uniqueKeysWithValues: contacts.map { ($0.fingerprint, $0) })
        self.restorableIdentity = restorableIdentity
    }

    func fail(_ operation: Operation, with error: ZwzV3Error) {
        lock.withLock { failures[operation] = error }
    }

    func clearFailure(_ operation: Operation) {
        _ = lock.withLock { failures.removeValue(forKey: operation) }
    }

    func setOperationDelay(_ delay: TimeInterval) {
        lock.withLock { self.delay = delay }
    }

    func setListingDelay(_ delay: TimeInterval) {
        lock.withLock { listingDelay = delay }
    }

    func callCount(_ operation: Operation) -> Int {
        lock.withLock { calls[operation, default: 0] }
    }

    func wasCalledOnMainThread(_ operation: Operation) -> Bool {
        lock.withLock { mainThreadCalls.contains(operation) }
    }

    func contains(fingerprint: String) -> Bool {
        lock.withLock {
            storedIdentities[fingerprint] != nil || storedContacts[fingerprint] != nil
        }
    }

    func createIdentity(named name: String) throws -> ZwzIdentityMetadata {
        try begin(.create)
        let seed = lock.withLock { () -> UInt8 in
            defer { nextIdentityIndex += 1 }
            return UInt8(nextIdentityIndex)
        }
        let identity = IdentityManagerTestSupport.identity(name: name, seed: seed)
        lock.withLock { storedIdentities[identity.fingerprint] = identity }
        return identity
    }

    func identities() throws -> [ZwzIdentityMetadata] {
        try begin(.identities, shouldDelay: false)
        return lock.withLock {
            storedIdentities.values.sorted { $0.creationDate < $1.creationDate }
        }
    }

    func contacts() throws -> [ZwzPublicIdentity] {
        try begin(.contacts, shouldDelay: false)
        return lock.withLock { storedContacts.values.sorted { $0.name < $1.name } }
    }

    func importPublicIdentity(
        _ data: Data,
        conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzPublicIdentity {
        try begin(.importPublic)
        let incoming = try ZwzKeyFileCodec.decodePublic(data)
        return try lock.withLock {
            if let local = storedIdentities[incoming.fingerprint] {
                guard conflict == .replaceExisting else {
                    throw ZwzV3Error.identityConflict(incoming.fingerprint)
                }
                storedIdentities[incoming.fingerprint] = ZwzIdentityMetadata(
                    name: incoming.name,
                    fingerprint: local.fingerprint,
                    agreementPublicKey: local.agreementPublicKey,
                    signingPublicKey: local.signingPublicKey,
                    creationDate: local.creationDate
                )
                return incoming
            }
            if storedContacts[incoming.fingerprint] != nil,
               conflict == .requireConfirmation {
                throw ZwzV3Error.identityConflict(incoming.fingerprint)
            }
            storedContacts[incoming.fingerprint] = incoming
            return incoming
        }
    }

    func exportPublicIdentity(fingerprint: String) throws -> Data {
        try begin(.exportPublic)
        let identity = try lock.withLock { () throws -> ZwzPublicIdentity in
            if let local = storedIdentities[fingerprint] { return local.publicIdentity }
            if let contact = storedContacts[fingerprint] { return contact }
            throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
        }
        return try ZwzKeyFileCodec.encodePublic(identity)
    }

    func exportPrivateBackup(fingerprint: String, password: String) throws -> Data {
        try begin(.exportBackup)
        return try lock.withLock {
            guard storedIdentities[fingerprint] != nil else {
                throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
            }
            return encryptedBackup
        }
    }

    func importPrivateBackup(
        _ data: Data,
        password: String,
        conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzIdentityMetadata {
        try begin(.restoreBackup)
        guard data == encryptedBackup, password == "correct horse battery staple" else {
            throw ZwzV3Error.invalidBackup
        }
        return try lock.withLock {
            if storedIdentities[restorableIdentity.fingerprint] != nil,
               conflict == .requireConfirmation {
                throw ZwzV3Error.identityConflict(restorableIdentity.fingerprint)
            }
            storedContacts.removeValue(forKey: restorableIdentity.fingerprint)
            storedIdentities[restorableIdentity.fingerprint] = restorableIdentity
            return restorableIdentity
        }
    }

    func rename(fingerprint: String, to name: String) throws {
        try begin(.rename)
        try lock.withLock {
            if let identity = storedIdentities[fingerprint] {
                storedIdentities[fingerprint] = ZwzIdentityMetadata(
                    name: name,
                    fingerprint: identity.fingerprint,
                    agreementPublicKey: identity.agreementPublicKey,
                    signingPublicKey: identity.signingPublicKey,
                    creationDate: identity.creationDate
                )
                return
            }
            if var contact = storedContacts[fingerprint] {
                contact.name = name
                storedContacts[fingerprint] = contact
                return
            }
            throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
        }
    }

    func delete(fingerprint: String) throws {
        try begin(.delete)
        lock.withLock {
            storedIdentities.removeValue(forKey: fingerprint)
            storedContacts.removeValue(forKey: fingerprint)
        }
    }

    func agreementPrivateKey(fingerprint: String, reason: String) throws -> Data {
        rawAgreementPrivateKey
    }

    func signingPrivateKey(fingerprint: String, reason: String) throws -> Data {
        rawSigningPrivateKey
    }

    func isKnownSigningKey(fingerprint: String, signingPublicKey: Data) -> Bool {
        lock.withLock {
            storedIdentities[fingerprint]?.signingPublicKey == signingPublicKey
                || storedContacts[fingerprint]?.signingPublicKey == signingPublicKey
        }
    }

    private func begin(_ operation: Operation, shouldDelay: Bool = true) throws {
        let state = lock.withLock { () -> (ZwzV3Error?, TimeInterval) in
            calls[operation, default: 0] += 1
            if Thread.isMainThread { mainThreadCalls.insert(operation) }
            return (failures[operation], shouldDelay ? delay : listingDelay)
        }
        if state.1 > 0 {
            Thread.sleep(forTimeInterval: state.1)
        }
        if let error = state.0 { throw error }
    }
}

enum IdentityManagerTestSupport {
    static func identity(name: String, seed: UInt8) -> ZwzIdentityMetadata {
        let agreementBytes = Data((0..<32).map { seed &+ UInt8($0) &+ 1 })
        let signingBytes = Data((0..<32).map { seed &+ UInt8($0) &+ 65 })
        let agreement = try! Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: agreementBytes
        )
        let signing = try! Curve25519.Signing.PrivateKey(rawRepresentation: signingBytes)
        let agreementPublic = agreement.publicKey.rawRepresentation
        let signingPublic = signing.publicKey.rawRepresentation
        return ZwzIdentityMetadata(
            name: name,
            fingerprint: ZwzV3Crypto.fingerprint(
                agreement: agreementPublic,
                signing: signingPublic
            ),
            agreementPublicKey: agreementPublic,
            signingPublicKey: signingPublic,
            creationDate: Date(timeIntervalSince1970: TimeInterval(seed))
        )
    }

    static func contact(name: String, seed: UInt8) -> ZwzPublicIdentity {
        identity(name: name, seed: seed).publicIdentity
    }

    @MainActor
    static func modelWithIdentity(
        onRestore: (@MainActor @Sendable () -> Void)? = nil
    ) async throws -> (IdentityManagerViewModel, IdentityManagerControlledStore) {
        let identity = identity(name: "Alice", seed: 1)
        let store = IdentityManagerControlledStore(identities: [identity])
        let model = IdentityManagerViewModel(store: store, onPrivateRestore: onRestore)
        try await model.refresh()
        return (model, store)
    }

    @MainActor
    static func capturedError<T>(
        _ operation: @MainActor () async throws -> T
    ) async -> Error? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }
}
