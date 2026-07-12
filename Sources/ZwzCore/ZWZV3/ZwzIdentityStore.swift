import CryptoKit
import Foundation

public struct ZwzPublicIdentity: Codable, Equatable, Sendable {
    public var name: String
    public let fingerprint: String
    public let agreementPublicKey: Data
    public let signingPublicKey: Data

    public init(
        name: String,
        fingerprint: String,
        agreementPublicKey: Data,
        signingPublicKey: Data
    ) {
        self.name = name
        self.fingerprint = fingerprint
        self.agreementPublicKey = agreementPublicKey
        self.signingPublicKey = signingPublicKey
    }
}

public struct ZwzIdentityMetadata: Codable, Equatable, Sendable {
    public var name: String
    public let fingerprint: String
    public let agreementPublicKey: Data
    public let signingPublicKey: Data
    public let creationDate: Date

    public init(
        name: String,
        fingerprint: String,
        agreementPublicKey: Data,
        signingPublicKey: Data,
        creationDate: Date
    ) {
        self.name = name
        self.fingerprint = fingerprint
        self.agreementPublicKey = agreementPublicKey
        self.signingPublicKey = signingPublicKey
        self.creationDate = creationDate
    }

    public var publicIdentity: ZwzPublicIdentity {
        ZwzPublicIdentity(
            name: name,
            fingerprint: fingerprint,
            agreementPublicKey: agreementPublicKey,
            signingPublicKey: signingPublicKey
        )
    }
}

public enum ZwzIdentityConflictPolicy: Sendable {
    case requireConfirmation
    case replaceExisting
}

public protocol ZwzIdentityStore: ZwzPrivateKeyProvider {
    func createIdentity(named name: String) throws -> ZwzIdentityMetadata
    func identities() throws -> [ZwzIdentityMetadata]
    func contacts() throws -> [ZwzPublicIdentity]
    func importPublicIdentity(
        _ data: Data, conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzPublicIdentity
    func exportPublicIdentity(fingerprint: String) throws -> Data
    func exportPrivateBackup(fingerprint: String, password: String) throws -> Data
    func importPrivateBackup(
        _ data: Data, password: String, conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzIdentityMetadata
    func rename(fingerprint: String, to name: String) throws
    func delete(fingerprint: String) throws
}

public final class InMemoryZwzIdentityStore: ZwzIdentityStore, @unchecked Sendable {
    enum ImportFailurePoint: Sendable { case afterAgreementPrivateKey }

    private struct StoredIdentity: Sendable {
        var metadata: ZwzIdentityMetadata
        let agreementPrivateKey: Data
        let signingPrivateKey: Data
    }

    private let lock = NSLock()
    private var storedIdentities: [String: StoredIdentity] = [:]
    private var storedContacts: [String: ZwzPublicIdentity] = [:]
    private let importFailurePoint: ImportFailurePoint?
    private let providerFailure: ZwzV3Error?

    public init() {
        importFailurePoint = nil
        providerFailure = nil
    }

    init(importFailurePoint: ImportFailurePoint? = nil, providerFailure: ZwzV3Error? = nil) {
        self.importFailurePoint = importFailurePoint
        self.providerFailure = providerFailure
    }

    public func createIdentity(named name: String) throws -> ZwzIdentityMetadata {
        let validatedName = try validateIdentityName(name)
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        let signing = Curve25519.Signing.PrivateKey()
        let fingerprint = ZwzV3Crypto.fingerprint(
            agreement: agreement.publicKey.rawRepresentation,
            signing: signing.publicKey.rawRepresentation
        )
        let identity = ZwzPrivateIdentity(
            name: validatedName,
            fingerprint: fingerprint,
            agreementPrivateKey: agreement.rawRepresentation,
            signingPrivateKey: signing.rawRepresentation
        )
        return try insert(identity, conflict: .requireConfirmation)
    }

    public func identities() throws -> [ZwzIdentityMetadata] {
        lock.withLock {
            storedIdentities.values.map(\.metadata).sorted { $0.creationDate < $1.creationDate }
        }
    }

    public func contacts() throws -> [ZwzPublicIdentity] {
        lock.withLock { storedContacts.values.sorted { $0.name < $1.name } }
    }

    public func importPublicIdentity(
        _ data: Data, conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzPublicIdentity {
        let identity = try ZwzKeyFileCodec.decodePublic(data)
        try lock.withLock {
            if storedContacts[identity.fingerprint] != nil
                || storedIdentities[identity.fingerprint] != nil {
                guard conflict == .replaceExisting else {
                    throw ZwzV3Error.identityConflict(identity.fingerprint)
                }
            }
            storedContacts[identity.fingerprint] = identity
        }
        return identity
    }

    public func exportPublicIdentity(fingerprint: String) throws -> Data {
        let identity = try lock.withLock {
            if let metadata = storedIdentities[fingerprint]?.metadata {
                return metadata.publicIdentity
            }
            if let contact = storedContacts[fingerprint] { return contact }
            throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
        }
        return try ZwzKeyFileCodec.encodePublic(identity)
    }

    public func exportPrivateBackup(fingerprint: String, password: String) throws -> Data {
        let identity = try lock.withLock { try privateIdentity(fingerprint: fingerprint) }
        return try ZwzKeyFileCodec.encodeBackup(identity, password: password)
    }

    public func importPrivateBackup(
        _ data: Data,
        password: String,
        conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzIdentityMetadata {
        let identity = try ZwzKeyFileCodec.decodeBackup(data, password: password)
        return try insert(identity, conflict: conflict)
    }

    public func rename(fingerprint: String, to name: String) throws {
        let validatedName = try validateIdentityName(name)
        try lock.withLock {
            if var stored = storedIdentities[fingerprint] {
                stored.metadata.name = validatedName
                storedIdentities[fingerprint] = stored
                return
            }
            if var contact = storedContacts[fingerprint] {
                contact.name = validatedName
                storedContacts[fingerprint] = contact
                return
            }
            throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
        }
    }

    public func delete(fingerprint: String) throws {
        lock.withLock {
            storedIdentities.removeValue(forKey: fingerprint)
            storedContacts.removeValue(forKey: fingerprint)
        }
    }

    public func agreementPrivateKey(fingerprint: String, reason: String) throws -> Data {
        try lock.withLock {
            if let providerFailure { throw providerFailure }
            guard let data = storedIdentities[fingerprint]?.agreementPrivateKey else {
                throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
            }
            return data
        }
    }

    public func signingPrivateKey(fingerprint: String, reason: String) throws -> Data {
        try lock.withLock {
            if let providerFailure { throw providerFailure }
            guard let data = storedIdentities[fingerprint]?.signingPrivateKey else {
                throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
            }
            return data
        }
    }

    public func isKnownSigningKey(fingerprint: String, signingPublicKey: Data) -> Bool {
        lock.withLock {
            storedIdentities[fingerprint]?.metadata.signingPublicKey == signingPublicKey
                || storedContacts[fingerprint]?.signingPublicKey == signingPublicKey
        }
    }

    private func insert(
        _ identity: ZwzPrivateIdentity, conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzIdentityMetadata {
        let publicIdentity = try identity.publicIdentity
        let metadata = ZwzIdentityMetadata(
            name: try validateIdentityName(identity.name),
            fingerprint: identity.fingerprint,
            agreementPublicKey: publicIdentity.agreementPublicKey,
            signingPublicKey: publicIdentity.signingPublicKey,
            creationDate: Date()
        )
        return try lock.withLock {
            if storedIdentities[identity.fingerprint] != nil
                || storedContacts[identity.fingerprint] != nil {
                guard conflict == .replaceExisting else {
                    throw ZwzV3Error.identityConflict(identity.fingerprint)
                }
            }
            let oldIdentity = storedIdentities[identity.fingerprint]
            let oldContact = storedContacts[identity.fingerprint]
            do {
                storedContacts.removeValue(forKey: identity.fingerprint)
                storedIdentities[identity.fingerprint] = StoredIdentity(
                    metadata: metadata,
                    agreementPrivateKey: identity.agreementPrivateKey,
                    signingPrivateKey: Data()
                )
                if importFailurePoint == .afterAgreementPrivateKey {
                    throw ZwzV3Error.keychainFailure(-1)
                }
                storedIdentities[identity.fingerprint] = StoredIdentity(
                    metadata: metadata,
                    agreementPrivateKey: identity.agreementPrivateKey,
                    signingPrivateKey: identity.signingPrivateKey
                )
                return metadata
            } catch {
                storedIdentities[identity.fingerprint] = oldIdentity
                storedContacts[identity.fingerprint] = oldContact
                throw error
            }
        }
    }

    private func privateIdentity(fingerprint: String) throws -> ZwzPrivateIdentity {
        guard let stored = storedIdentities[fingerprint] else {
            throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
        }
        return ZwzPrivateIdentity(
            name: stored.metadata.name,
            fingerprint: fingerprint,
            agreementPrivateKey: stored.agreementPrivateKey,
            signingPrivateKey: stored.signingPrivateKey
        )
    }
}

private func validateIdentityName(_ name: String) throws -> String {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ZwzV3Error.invalidIdentityName
    }
    return name
}
