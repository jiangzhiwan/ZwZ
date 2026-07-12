import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum ZwzKeychainItemKind: String, Hashable, Sendable {
    case identity = "com.zwz.identity.metadata"
    case contact = "com.zwz.contact.metadata"
    case agreement = "com.zwz.identity.agreement-private"
    case signing = "com.zwz.identity.signing-private"

    var isPrivate: Bool { self == .agreement || self == .signing }
}

struct ZwzKeychainReadResult: Sendable {
    let status: OSStatus
    let items: [Data]
}

protocol ZwzKeychainBackend: AnyObject, Sendable {
    func add(kind: ZwzKeychainItemKind, fingerprint: String, data: Data) -> OSStatus
    func update(kind: ZwzKeychainItemKind, fingerprint: String, data: Data) -> OSStatus
    func read(
        kind: ZwzKeychainItemKind,
        fingerprint: String,
        authenticationReason: String?
    ) -> ZwzKeychainReadResult
    func readAll(kind: ZwzKeychainItemKind) -> ZwzKeychainReadResult
    func delete(kind: ZwzKeychainItemKind, fingerprint: String) -> OSStatus
}

final class SecurityZwzKeychainBackend: ZwzKeychainBackend, @unchecked Sendable {
    private let accessGroup: String?

    init(accessGroup: String?) {
        self.accessGroup = accessGroup
    }

    func add(kind: ZwzKeychainItemKind, fingerprint: String, data: Data) -> OSStatus {
        var query = baseQuery(kind: kind, fingerprint: fingerprint)
        query[kSecValueData] = data
        if kind.isPrivate {
            var accessError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                &accessError
            ) else { return errSecParam }
            query[kSecAttrAccessControl] = access
        } else {
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return SecItemAdd(query as CFDictionary, nil)
    }

    func update(kind: ZwzKeychainItemKind, fingerprint: String, data: Data) -> OSStatus {
        guard !kind.isPrivate else { return errSecParam }
        return SecItemUpdate(
            baseQuery(kind: kind, fingerprint: fingerprint) as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
    }

    func read(
        kind: ZwzKeychainItemKind,
        fingerprint: String,
        authenticationReason: String?
    ) -> ZwzKeychainReadResult {
        var query = baseQuery(kind: kind, fingerprint: fingerprint)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        if kind.isPrivate {
            guard let authenticationReason, !authenticationReason.isEmpty else {
                return ZwzKeychainReadResult(status: errSecParam, items: [])
            }
            let context = LAContext()
            context.localizedReason = authenticationReason
            query[kSecUseAuthenticationContext] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return ZwzKeychainReadResult(
                status: status == errSecSuccess ? errSecDecode : status,
                items: []
            )
        }
        return ZwzKeychainReadResult(status: status, items: [data])
    }

    func readAll(kind: ZwzKeychainItemKind) -> ZwzKeychainReadResult {
        guard !kind.isPrivate else {
            return ZwzKeychainReadResult(status: errSecParam, items: [])
        }
        var query = baseQuery(kind: kind, fingerprint: nil)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return ZwzKeychainReadResult(status: status, items: [])
        }
        if let values = item as? [Data] {
            return ZwzKeychainReadResult(status: status, items: values)
        }
        if let value = item as? Data {
            return ZwzKeychainReadResult(status: status, items: [value])
        }
        return ZwzKeychainReadResult(status: errSecDecode, items: [])
    }

    func delete(kind: ZwzKeychainItemKind, fingerprint: String) -> OSStatus {
        SecItemDelete(baseQuery(kind: kind, fingerprint: fingerprint) as CFDictionary)
    }

    private func baseQuery(
        kind: ZwzKeychainItemKind,
        fingerprint: String?
    ) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: kind.rawValue
        ]
        if let fingerprint { query[kSecAttrAccount] = fingerprint }
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        return query
    }
}

/// User-presence prompts, password fallback, and cancellation mapping require a signed app.
/// They are manual integration checks and intentionally cannot run under `swift test`.
public final class MacKeychainIdentityStore: ZwzIdentityStore, @unchecked Sendable {
    private let backend: any ZwzKeychainBackend
    private let lock = NSRecursiveLock()

    public convenience init(accessGroup: String? = nil) {
        self.init(backend: SecurityZwzKeychainBackend(accessGroup: accessGroup))
    }

    init(backend: any ZwzKeychainBackend) {
        self.backend = backend
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
        return try lock.withLock {
            try writeIdentity(identity, conflict: .requireConfirmation)
        }
    }

    public func identities() throws -> [ZwzIdentityMetadata] {
        return try lock.withLock {
            try readAll(kind: .identity, as: ZwzIdentityMetadata.self)
                .sorted { $0.creationDate < $1.creationDate }
        }
    }

    public func contacts() throws -> [ZwzPublicIdentity] {
        return try lock.withLock {
            try readAll(kind: .contact, as: ZwzPublicIdentity.self)
                .sorted { $0.name < $1.name }
        }
    }

    public func importPublicIdentity(
        _ data: Data,
        conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzPublicIdentity {
        let incoming = try ZwzKeyFileCodec.decodePublic(data)
        return try lock.withLock {
            if let existing: ZwzIdentityMetadata = try readOptional(
                kind: .identity,
                fingerprint: incoming.fingerprint
            ) {
                guard conflict == .replaceExisting else {
                    throw ZwzV3Error.identityConflict(incoming.fingerprint)
                }
                try validateBinding(existing.publicIdentity, incoming)
                let updated = ZwzIdentityMetadata(
                    name: incoming.name,
                    fingerprint: existing.fingerprint,
                    agreementPublicKey: existing.agreementPublicKey,
                    signingPublicKey: existing.signingPublicKey,
                    creationDate: existing.creationDate
                )
                try updatePublic(.identity, fingerprint: incoming.fingerprint, value: updated)
                return incoming
            }
            if let existing: ZwzPublicIdentity = try readOptional(
                kind: .contact,
                fingerprint: incoming.fingerprint
            ) {
                guard conflict == .replaceExisting else {
                    throw ZwzV3Error.identityConflict(incoming.fingerprint)
                }
                try validateBinding(existing, incoming)
                try updatePublic(.contact, fingerprint: incoming.fingerprint, value: incoming)
                return incoming
            }
            try addPublic(.contact, fingerprint: incoming.fingerprint, value: incoming)
            return incoming
        }
    }

    public func exportPublicIdentity(fingerprint: String) throws -> Data {
        let identity: ZwzPublicIdentity = try lock.withLock {
            if let metadata: ZwzIdentityMetadata = try readOptional(
                kind: .identity,
                fingerprint: fingerprint
            ) {
                return metadata.publicIdentity
            }
            if let contact: ZwzPublicIdentity = try readOptional(
                kind: .contact,
                fingerprint: fingerprint
            ) {
                return contact
            }
            throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
        }
        return try ZwzKeyFileCodec.encodePublic(identity)
    }

    public func exportPrivateBackup(fingerprint: String, password: String) throws -> Data {
        let identity = try lock.withLock {
            guard let metadata: ZwzIdentityMetadata = try readOptional(
                kind: .identity,
                fingerprint: fingerprint
            ) else { throw ZwzV3Error.noMatchingPrivateKey([fingerprint]) }
            let agreement = try privateData(
                kind: .agreement,
                fingerprint: fingerprint,
                reason: "Authenticate to export the agreement key backup"
            )
            let signing = try privateData(
                kind: .signing,
                fingerprint: fingerprint,
                reason: "Authenticate to export the signing key backup"
            )
            return ZwzPrivateIdentity(
                name: metadata.name,
                fingerprint: fingerprint,
                agreementPrivateKey: agreement,
                signingPrivateKey: signing
            )
        }
        return try ZwzKeyFileCodec.encodeBackup(identity, password: password)
    }

    public func importPrivateBackup(
        _ data: Data,
        password: String,
        conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzIdentityMetadata {
        let identity = try ZwzKeyFileCodec.decodeBackup(data, password: password)
        return try lock.withLock {
            try writeIdentity(identity, conflict: conflict)
        }
    }

    func importPrivateIdentity(
        _ identity: ZwzPrivateIdentity,
        conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzIdentityMetadata {
        try lock.withLock { try writeIdentity(identity, conflict: conflict) }
    }

    public func rename(fingerprint: String, to name: String) throws {
        try lock.withLock {
            let validatedName = try validateIdentityName(name)
            if let metadata: ZwzIdentityMetadata = try readOptional(
                kind: .identity,
                fingerprint: fingerprint
            ) {
                let updated = ZwzIdentityMetadata(
                    name: validatedName,
                    fingerprint: metadata.fingerprint,
                    agreementPublicKey: metadata.agreementPublicKey,
                    signingPublicKey: metadata.signingPublicKey,
                    creationDate: metadata.creationDate
                )
                try updatePublic(.identity, fingerprint: fingerprint, value: updated)
                return
            }
            if let contact: ZwzPublicIdentity = try readOptional(
                kind: .contact,
                fingerprint: fingerprint
            ) {
                let updated = ZwzPublicIdentity(
                    name: validatedName,
                    fingerprint: contact.fingerprint,
                    agreementPublicKey: contact.agreementPublicKey,
                    signingPublicKey: contact.signingPublicKey
                )
                try updatePublic(.contact, fingerprint: fingerprint, value: updated)
                return
            }
            throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
        }
    }

    public func delete(fingerprint: String) throws {
        try lock.withLock {
            var firstError: Error?
            for kind in [
                ZwzKeychainItemKind.identity, .contact, .agreement, .signing
            ] {
                let status = backend.delete(kind: kind, fingerprint: fingerprint)
                if status != errSecSuccess, status != errSecItemNotFound, firstError == nil {
                    firstError = mappedError(status, fingerprint: fingerprint)
                }
            }
            if let firstError { throw firstError }
        }
    }

    public func agreementPrivateKey(fingerprint: String, reason: String) throws -> Data {
        try lock.withLock {
            try privateData(kind: .agreement, fingerprint: fingerprint, reason: reason)
        }
    }

    public func signingPrivateKey(fingerprint: String, reason: String) throws -> Data {
        try lock.withLock {
            try privateData(kind: .signing, fingerprint: fingerprint, reason: reason)
        }
    }

    public func isKnownSigningKey(fingerprint: String, signingPublicKey: Data) -> Bool {
        lock.withLock {
            if let metadata: ZwzIdentityMetadata = try? readOptional(
                kind: .identity,
                fingerprint: fingerprint
            ), metadata.signingPublicKey == signingPublicKey {
                return true
            }
            if let contact: ZwzPublicIdentity = try? readOptional(
                kind: .contact,
                fingerprint: fingerprint
            ), contact.signingPublicKey == signingPublicKey {
                return true
            }
            return false
        }
    }

    private func writeIdentity(
        _ identity: ZwzPrivateIdentity,
        conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzIdentityMetadata {
        let incomingPublic = try identity.publicIdentity
        if let existing: ZwzIdentityMetadata = try readOptional(
            kind: .identity,
            fingerprint: identity.fingerprint
        ) {
            guard conflict == .replaceExisting else {
                throw ZwzV3Error.identityConflict(identity.fingerprint)
            }
            try validateBinding(existing.publicIdentity, incomingPublic)
            let updated = ZwzIdentityMetadata(
                name: try validateIdentityName(identity.name),
                fingerprint: existing.fingerprint,
                agreementPublicKey: existing.agreementPublicKey,
                signingPublicKey: existing.signingPublicKey,
                creationDate: existing.creationDate
            )
            try updatePublic(.identity, fingerprint: identity.fingerprint, value: updated)
            return updated
        }

        let contact: ZwzPublicIdentity? = try readOptional(
            kind: .contact,
            fingerprint: identity.fingerprint
        )
        if let contact {
            guard conflict == .replaceExisting else {
                throw ZwzV3Error.identityConflict(identity.fingerprint)
            }
            try validateBinding(contact, incomingPublic)
        }

        let metadata = ZwzIdentityMetadata(
            name: try validateIdentityName(identity.name),
            fingerprint: identity.fingerprint,
            agreementPublicKey: incomingPublic.agreementPublicKey,
            signingPublicKey: incomingPublic.signingPublicKey,
            creationDate: Date()
        )
        var written: [ZwzKeychainItemKind] = []
        do {
            try addPrivate(.agreement, fingerprint: identity.fingerprint, data: identity.agreementPrivateKey)
            written.append(.agreement)
            try addPrivate(.signing, fingerprint: identity.fingerprint, data: identity.signingPrivateKey)
            written.append(.signing)
            try addPublic(.identity, fingerprint: identity.fingerprint, value: metadata)
            written.append(.identity)
            if contact != nil {
                let status = backend.delete(kind: .contact, fingerprint: identity.fingerprint)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw mappedError(status, fingerprint: identity.fingerprint)
                }
            }
            return metadata
        } catch {
            for kind in written.reversed() {
                _ = backend.delete(kind: kind, fingerprint: identity.fingerprint)
            }
            throw error
        }
    }

    private func addPrivate(
        _ kind: ZwzKeychainItemKind,
        fingerprint: String,
        data: Data
    ) throws {
        try check(backend.add(kind: kind, fingerprint: fingerprint, data: data), fingerprint: fingerprint)
    }

    private func addPublic<T: Encodable>(
        _ kind: ZwzKeychainItemKind,
        fingerprint: String,
        value: T
    ) throws {
        let data = try JSONEncoder().encode(value)
        try check(backend.add(kind: kind, fingerprint: fingerprint, data: data), fingerprint: fingerprint)
    }

    private func updatePublic<T: Encodable>(
        _ kind: ZwzKeychainItemKind,
        fingerprint: String,
        value: T
    ) throws {
        let data = try JSONEncoder().encode(value)
        try check(backend.update(kind: kind, fingerprint: fingerprint, data: data), fingerprint: fingerprint)
    }

    private func privateData(
        kind: ZwzKeychainItemKind,
        fingerprint: String,
        reason: String
    ) throws -> Data {
        let result = backend.read(
            kind: kind,
            fingerprint: fingerprint,
            authenticationReason: reason
        )
        try check(result.status, fingerprint: fingerprint)
        guard result.items.count == 1 else { throw ZwzV3Error.keychainFailure(errSecDecode) }
        return result.items[0]
    }

    private func readOptional<T: Decodable>(
        kind: ZwzKeychainItemKind,
        fingerprint: String
    ) throws -> T? {
        let result = backend.read(
            kind: kind,
            fingerprint: fingerprint,
            authenticationReason: nil
        )
        if result.status == errSecItemNotFound { return nil }
        try check(result.status, fingerprint: fingerprint)
        guard result.items.count == 1 else { throw ZwzV3Error.keychainFailure(errSecDecode) }
        return try decode(T.self, from: result.items[0])
    }

    private func readAll<T: Decodable>(
        kind: ZwzKeychainItemKind,
        as: T.Type
    ) throws -> [T] {
        let result = backend.readAll(kind: kind)
        if result.status == errSecItemNotFound { return [] }
        try check(result.status, fingerprint: "")
        return try result.items.map { try decode(T.self, from: $0) }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ZwzV3Error.keychainFailure(errSecDecode)
        }
    }

    private func validateBinding(
        _ existing: ZwzPublicIdentity,
        _ incoming: ZwzPublicIdentity
    ) throws {
        guard existing.fingerprint == incoming.fingerprint,
              existing.agreementPublicKey == incoming.agreementPublicKey,
              existing.signingPublicKey == incoming.signingPublicKey else {
            throw ZwzV3Error.identityConflict(incoming.fingerprint)
        }
    }

    private func check(_ status: OSStatus, fingerprint: String) throws {
        guard status == errSecSuccess else { throw mappedError(status, fingerprint: fingerprint) }
    }

    private func mappedError(_ status: OSStatus, fingerprint: String) -> ZwzV3Error {
        switch status {
        case errSecUserCanceled:
            return .userAuthenticationCancelled
        case errSecItemNotFound:
            return .noMatchingPrivateKey([fingerprint])
        default:
            return .keychainFailure(status)
        }
    }
}
