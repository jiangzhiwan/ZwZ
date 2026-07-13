import Foundation
import ZwzCore

struct ArchiveProtectionDescriptor: Codable, Equatable, Sendable {
    enum SignatureKind: String, Codable, Sendable {
        case unsigned
        case signed
        case invalid
    }

    let encryptionRawValue: UInt8
    let recipientFingerprints: [String]
    let signatureKind: SignatureKind
    let signerFingerprint: String?
    let signerSigningPublicKey: Data?

    init(securityInfo: ZwzArchiveSecurityInfo) {
        encryptionRawValue = securityInfo.encryption.rawValue
        recipientFingerprints = securityInfo.recipientFingerprints
        switch securityInfo.signature {
        case .validKnownSigner(_, let fingerprint),
             .validUnknownSigner(_, let fingerprint):
            signatureKind = .signed
            signerFingerprint = fingerprint
        case .unsigned:
            signatureKind = .unsigned
            signerFingerprint = nil
        case .invalid:
            signatureKind = .invalid
            signerFingerprint = nil
        }
        signerSigningPublicKey = securityInfo.signerSigningPublicKey
    }

    var securityInfo: ZwzArchiveSecurityInfo? {
        guard let encryption = ZwzArchiveEncryptionKind(rawValue: encryptionRawValue) else {
            return nil
        }
        let signature: ZwzSignatureVerification
        switch signatureKind {
        case .unsigned:
            signature = .unsigned
        case .signed:
            guard let signerFingerprint else { return nil }
            signature = .validKnownSigner(name: "", fingerprint: signerFingerprint)
        case .invalid:
            signature = .invalid
        }
        return ZwzArchiveSecurityInfo(
            encryption: encryption,
            recipientFingerprints: recipientFingerprints,
            signature: signature,
            signerSigningPublicKey: signerSigningPublicKey
        )
    }
}

enum ArchiveEncryptionResolutionError: LocalizedError, Equatable {
    case passwordRequired
    case missingRecipient(String)
    case missingSigner(String)
    case invalidSignature

    var errorDescription: String? {
        switch self {
        case .passwordRequired:
            return "The original archive password is required to preserve its encryption."
        case .missingRecipient(let fingerprint):
            return "The original recipient \(fingerprint) is unavailable. The archive was not saved."
        case .missingSigner(let fingerprint):
            return "The original signer \(fingerprint) is not available as a local identity. The archive was not saved."
        case .invalidSignature:
            return "The archive has an invalid signature and cannot be opened or saved."
        }
    }
}

enum ArchiveEncryptionResolver {
    static func resolve(
        securityInfo: ZwzArchiveSecurityInfo?,
        password: String?,
        identityStore: any ZwzIdentityStore
    ) throws -> ZwzEncryptionMode {
        guard let securityInfo else {
            return normalizedPassword(password).map(ZwzEncryptionMode.password) ?? .none
        }

        switch securityInfo.encryption {
        case .none:
            return .none
        case .password:
            guard let password = normalizedPassword(password) else {
                throw ArchiveEncryptionResolutionError.passwordRequired
            }
            return .password(password)
        case .publicKey:
            return try resolvePublicKey(
                securityInfo: securityInfo,
                identityStore: identityStore
            )
        }
    }

    private static func resolvePublicKey(
        securityInfo: ZwzArchiveSecurityInfo,
        identityStore: any ZwzIdentityStore
    ) throws -> ZwzEncryptionMode {
        guard securityInfo.signature != .invalid else {
            throw ArchiveEncryptionResolutionError.invalidSignature
        }

        let identities = try identityStore.identities()
        let contacts = try identityStore.contacts()
        var recipientsByFingerprint: [String: ZwzPublicIdentity] = [:]
        for contact in contacts {
            recipientsByFingerprint[contact.fingerprint] = contact
        }
        for identity in identities {
            recipientsByFingerprint[identity.fingerprint] = identity.publicIdentity
        }

        let fingerprints = Array(Set(securityInfo.recipientFingerprints)).sorted()
        let recipients = try fingerprints.map { fingerprint -> ZwzRecipient in
            guard let identity = recipientsByFingerprint[fingerprint] else {
                throw ArchiveEncryptionResolutionError.missingRecipient(fingerprint)
            }
            return ZwzRecipient(
                name: identity.name,
                fingerprint: identity.fingerprint,
                agreementPublicKey: identity.agreementPublicKey
            )
        }

        guard !recipients.isEmpty else {
            throw ZwzV3Error.recipientRequired
        }

        let signer: ZwzSigningIdentity?
        switch securityInfo.signature {
        case .unsigned:
            signer = nil
        case .validKnownSigner(_, let fingerprint),
             .validUnknownSigner(_, let fingerprint):
            guard let expectedSigningPublicKey = securityInfo.signerSigningPublicKey,
                  let identity = identities.first(where: {
                      $0.fingerprint == fingerprint
                          && $0.signingPublicKey == expectedSigningPublicKey
                  }) else {
                throw ArchiveEncryptionResolutionError.missingSigner(fingerprint)
            }
            signer = ZwzSigningIdentity(
                name: identity.name,
                fingerprint: identity.fingerprint,
                agreementPublicKey: identity.agreementPublicKey,
                signingPublicKey: identity.signingPublicKey
            )
        case .invalid:
            throw ArchiveEncryptionResolutionError.invalidSignature
        }

        return .publicKey(recipients: recipients, signer: signer)
    }

    private static func normalizedPassword(_ password: String?) -> String? {
        guard let password, !password.isEmpty else { return nil }
        return password
    }
}
