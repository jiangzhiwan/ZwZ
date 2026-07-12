import Foundation

public enum ZwzEncryptionMode: Equatable, Sendable {
    case none
    case password(String)
    case publicKey(recipients: [ZwzRecipient], signer: ZwzSigningIdentity?)

    public func validated() throws -> Self {
        if case .publicKey(let recipients, _) = self, recipients.isEmpty {
            throw ZwzV3Error.recipientRequired
        }
        return self
    }
}

public struct ZwzRecipient: Equatable, Sendable {
    public let name: String
    public let fingerprint: String
    public let agreementPublicKey: Data

    public init(name: String, fingerprint: String, agreementPublicKey: Data) {
        self.name = name
        self.fingerprint = fingerprint
        self.agreementPublicKey = agreementPublicKey
    }
}

public struct ZwzSigningIdentity: Equatable, Sendable {
    public let name: String
    public let fingerprint: String

    public init(name: String, fingerprint: String) {
        self.name = name
        self.fingerprint = fingerprint
    }
}

public enum ZwzSignatureVerification: Equatable, Sendable {
    case unsigned
    case validKnownSigner(name: String, fingerprint: String)
    case validUnknownSigner(name: String, fingerprint: String)
    case invalid
}

public enum ZwzArchiveEncryptionKind: UInt8, Equatable, Sendable {
    case none = 0
    case password = 1
    case publicKey = 2
}

public struct ZwzArchiveSecurityInfo: Equatable, Sendable {
    public let encryption: ZwzArchiveEncryptionKind
    public let recipientFingerprints: [String]
    public let signature: ZwzSignatureVerification

    public init(
        encryption: ZwzArchiveEncryptionKind,
        recipientFingerprints: [String] = [],
        signature: ZwzSignatureVerification = .unsigned
    ) {
        self.encryption = encryption
        self.recipientFingerprints = recipientFingerprints
        self.signature = signature
    }
}

public enum ZwzV3Error: LocalizedError, Equatable, Sendable {
    case recipientRequired
    case invalidRecipientPublicKey(String)
    case keyUnwrapFailed
    case authenticationFailed
    case malformedArchive(String)
    case noMatchingPrivateKey([String])
    case userAuthenticationCancelled
    case invalidSignature
    case invalidBackup
    case identityConflict(String)
    case unsupportedVersion(UInt16)

    public var errorDescription: String? {
        switch self {
        case .recipientRequired:
            return "At least one recipient is required"
        case .invalidRecipientPublicKey:
            return "A recipient public key is invalid"
        case .keyUnwrapFailed:
            return "Unable to unlock the archive key"
        case .authenticationFailed:
            return "Archive authentication failed"
        case .malformedArchive:
            return "The archive is malformed"
        case .noMatchingPrivateKey:
            return "No matching private key is available"
        case .userAuthenticationCancelled:
            return "User authentication was cancelled"
        case .invalidSignature:
            return "The archive signature is invalid"
        case .invalidBackup:
            return "The identity backup is invalid"
        case .identityConflict:
            return "An identity conflict was detected"
        case .unsupportedVersion(let version):
            return "Unsupported ZWZ version: \(version)"
        }
    }
}
