import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// User-presence prompts, password fallback, and cancellation mapping require a signed app.
/// They are manual integration checks and intentionally cannot run under `swift test`.
public final class MacKeychainIdentityStore: ZwzIdentityStore, @unchecked Sendable {
    private enum Kind: String {
        case identity = "com.zwz.identity.metadata"
        case contact = "com.zwz.contact.metadata"
        case agreement = "com.zwz.identity.agreement-private"
        case signing = "com.zwz.identity.signing-private"
    }

    private let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    public func createIdentity(named name: String) throws -> ZwzIdentityMetadata {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ZwzV3Error.invalidIdentityName }
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        let signing = Curve25519.Signing.PrivateKey()
        let fingerprint = ZwzV3Crypto.fingerprint(
            agreement: agreement.publicKey.rawRepresentation,
            signing: signing.publicKey.rawRepresentation
        )
        let identity = ZwzPrivateIdentity(
            name: name,
            fingerprint: fingerprint,
            agreementPrivateKey: agreement.rawRepresentation,
            signingPrivateKey: signing.rawRepresentation
        )
        return try writeIdentity(identity, conflict: .requireConfirmation)
    }

    public func identities() throws -> [ZwzIdentityMetadata] {
        try readAll(kind: .identity, as: ZwzIdentityMetadata.self)
            .sorted { $0.creationDate < $1.creationDate }
    }

    public func contacts() throws -> [ZwzPublicIdentity] {
        try readAll(kind: .contact, as: ZwzPublicIdentity.self).sorted { $0.name < $1.name }
    }

    public func importPublicIdentity(
        _ data: Data, conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzPublicIdentity {
        let identity = try ZwzKeyFileCodec.decodePublic(data)
        if try itemExists(kind: .contact, fingerprint: identity.fingerprint)
            || itemExists(kind: .identity, fingerprint: identity.fingerprint) {
            guard conflict == .replaceExisting else {
                throw ZwzV3Error.identityConflict(identity.fingerprint)
            }
            try deleteItem(kind: .contact, fingerprint: identity.fingerprint, ignoreMissing: true)
        }
        try addPublicItem(
            kind: .contact,
            fingerprint: identity.fingerprint,
            data: try JSONEncoder().encode(identity)
        )
        return identity
    }

    public func exportPublicIdentity(fingerprint: String) throws -> Data {
        if let metadata: ZwzIdentityMetadata = try readOptional(
            kind: .identity, fingerprint: fingerprint
        ) {
            return try ZwzKeyFileCodec.encodePublic(metadata.publicIdentity)
        }
        if let contact: ZwzPublicIdentity = try readOptional(
            kind: .contact, fingerprint: fingerprint
        ) {
            return try ZwzKeyFileCodec.encodePublic(contact)
        }
        throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
    }

    public func exportPrivateBackup(fingerprint: String, password: String) throws -> Data {
        guard let metadata: ZwzIdentityMetadata = try readOptional(
            kind: .identity, fingerprint: fingerprint
        ) else { throw ZwzV3Error.noMatchingPrivateKey([fingerprint]) }
        let agreement = try privateData(
            kind: .agreement, fingerprint: fingerprint,
            reason: "Authenticate to export the agreement key backup"
        )
        let signing = try privateData(
            kind: .signing, fingerprint: fingerprint,
            reason: "Authenticate to export the signing key backup"
        )
        return try ZwzKeyFileCodec.encodeBackup(
            ZwzPrivateIdentity(
                name: metadata.name,
                fingerprint: fingerprint,
                agreementPrivateKey: agreement,
                signingPrivateKey: signing
            ),
            password: password
        )
    }

    public func importPrivateBackup(
        _ data: Data,
        password: String,
        conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzIdentityMetadata {
        let identity = try ZwzKeyFileCodec.decodeBackup(data, password: password)
        return try writeIdentity(identity, conflict: conflict)
    }

    public func rename(fingerprint: String, to name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ZwzV3Error.invalidIdentityName
        }
        if var metadata: ZwzIdentityMetadata = try readOptional(
            kind: .identity, fingerprint: fingerprint
        ) {
            metadata.name = name
            try replacePublicItem(
                kind: .identity,
                fingerprint: fingerprint,
                data: try JSONEncoder().encode(metadata)
            )
            return
        }
        if var contact: ZwzPublicIdentity = try readOptional(
            kind: .contact, fingerprint: fingerprint
        ) {
            contact.name = name
            try replacePublicItem(
                kind: .contact,
                fingerprint: fingerprint,
                data: try JSONEncoder().encode(contact)
            )
            return
        }
        throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
    }

    public func delete(fingerprint: String) throws {
        for kind in [Kind.identity, .contact, .agreement, .signing] {
            try deleteItem(kind: kind, fingerprint: fingerprint, ignoreMissing: true)
        }
    }

    public func agreementPrivateKey(fingerprint: String, reason: String) throws -> Data {
        try privateData(kind: .agreement, fingerprint: fingerprint, reason: reason)
    }

    public func signingPrivateKey(fingerprint: String, reason: String) throws -> Data {
        try privateData(kind: .signing, fingerprint: fingerprint, reason: reason)
    }

    public func isKnownSigningKey(fingerprint: String, signingPublicKey: Data) -> Bool {
        if let metadata: ZwzIdentityMetadata = try? readOptional(
            kind: .identity, fingerprint: fingerprint
        ), metadata.signingPublicKey == signingPublicKey {
            return true
        }
        if let contact: ZwzPublicIdentity = try? readOptional(
            kind: .contact, fingerprint: fingerprint
        ), contact.signingPublicKey == signingPublicKey {
            return true
        }
        return false
    }

    private func writeIdentity(
        _ identity: ZwzPrivateIdentity,
        conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzIdentityMetadata {
        let publicIdentity = try identity.publicIdentity
        let metadata = ZwzIdentityMetadata(
            name: identity.name,
            fingerprint: identity.fingerprint,
            agreementPublicKey: publicIdentity.agreementPublicKey,
            signingPublicKey: publicIdentity.signingPublicKey,
            creationDate: Date()
        )
        if try itemExists(kind: .identity, fingerprint: identity.fingerprint)
            || itemExists(kind: .contact, fingerprint: identity.fingerprint) {
            guard conflict == .replaceExisting else {
                throw ZwzV3Error.identityConflict(identity.fingerprint)
            }
            try delete(fingerprint: identity.fingerprint)
        }

        var written: [Kind] = []
        do {
            try addPrivateItem(
                kind: .agreement,
                fingerprint: identity.fingerprint,
                data: identity.agreementPrivateKey
            )
            written.append(.agreement)
            try addPrivateItem(
                kind: .signing,
                fingerprint: identity.fingerprint,
                data: identity.signingPrivateKey
            )
            written.append(.signing)
            try addPublicItem(
                kind: .identity,
                fingerprint: identity.fingerprint,
                data: try JSONEncoder().encode(metadata)
            )
            written.append(.identity)
            return metadata
        } catch {
            for kind in written {
                try? deleteItem(kind: kind, fingerprint: identity.fingerprint, ignoreMissing: true)
            }
            throw error
        }
    }

    private func addPrivateItem(kind: Kind, fingerprint: String, data: Data) throws {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessError
        ) else { throw ZwzV3Error.keychainFailure(errSecParam) }
        var query = baseQuery(kind: kind, fingerprint: fingerprint)
        query[kSecValueData] = data
        query[kSecAttrAccessControl] = access
        try check(SecItemAdd(query as CFDictionary, nil), fingerprint: fingerprint)
    }

    private func addPublicItem(kind: Kind, fingerprint: String, data: Data) throws {
        var query = baseQuery(kind: kind, fingerprint: fingerprint)
        query[kSecValueData] = data
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try check(SecItemAdd(query as CFDictionary, nil), fingerprint: fingerprint)
    }

    private func replacePublicItem(kind: Kind, fingerprint: String, data: Data) throws {
        let status = SecItemUpdate(
            baseQuery(kind: kind, fingerprint: fingerprint) as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        try check(status, fingerprint: fingerprint)
    }

    private func privateData(kind: Kind, fingerprint: String, reason: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = reason
        var query = baseQuery(kind: kind, fingerprint: fingerprint)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        try check(status, fingerprint: fingerprint)
        guard let data = item as? Data else { throw ZwzV3Error.keychainFailure(errSecDecode) }
        return data
    }

    private func readOptional<T: Decodable>(kind: Kind, fingerprint: String) throws -> T? {
        var query = baseQuery(kind: kind, fingerprint: fingerprint)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status, fingerprint: fingerprint)
        guard let data = item as? Data else { throw ZwzV3Error.keychainFailure(errSecDecode) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ZwzV3Error.keychainFailure(errSecDecode)
        }
    }

    private func readAll<T: Decodable>(kind: Kind, as: T.Type) throws -> [T] {
        var query = baseQuery(kind: kind, fingerprint: nil)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        try check(status, fingerprint: "")
        let values: [Data]
        if let array = item as? [Data] { values = array }
        else if let data = item as? Data { values = [data] }
        else { throw ZwzV3Error.keychainFailure(errSecDecode) }
        do {
            return try values.map { try JSONDecoder().decode(T.self, from: $0) }
        } catch {
            throw ZwzV3Error.keychainFailure(errSecDecode)
        }
    }

    private func itemExists(kind: Kind, fingerprint: String) throws -> Bool {
        var query = baseQuery(kind: kind, fingerprint: fingerprint)
        query[kSecMatchLimit] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        try check(status, fingerprint: fingerprint)
        return true
    }

    private func deleteItem(kind: Kind, fingerprint: String, ignoreMissing: Bool) throws {
        let status = SecItemDelete(baseQuery(kind: kind, fingerprint: fingerprint) as CFDictionary)
        if ignoreMissing && status == errSecItemNotFound { return }
        try check(status, fingerprint: fingerprint)
    }

    private func baseQuery(kind: Kind, fingerprint: String?) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: kind.rawValue
        ]
        if let fingerprint { query[kSecAttrAccount] = fingerprint }
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        return query
    }

    private func check(_ status: OSStatus, fingerprint: String) throws {
        switch status {
        case errSecSuccess:
            return
        case errSecUserCanceled:
            throw ZwzV3Error.userAuthenticationCancelled
        case errSecItemNotFound:
            throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
        default:
            throw ZwzV3Error.keychainFailure(status)
        }
    }
}
