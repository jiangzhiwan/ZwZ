import CryptoKit
import Foundation

public struct ZwzV3RecipientEnvelope: Equatable, Sendable {
    public let recipientName: String
    public let recipientFingerprint: String
    public let ephemeralPublicKey: Data
    public var nonce: Data
    public var encryptedContentKey: Data
    public var authenticationTag: Data

    public init(
        recipientName: String,
        recipientFingerprint: String,
        ephemeralPublicKey: Data,
        nonce: Data,
        encryptedContentKey: Data,
        authenticationTag: Data
    ) {
        self.recipientName = recipientName
        self.recipientFingerprint = recipientFingerprint
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
        self.encryptedContentKey = encryptedContentKey
        self.authenticationTag = authenticationTag
    }
}

public struct ZwzV3SignerRecord: Equatable, Sendable {
    public let name: String
    public let fingerprint: String
    public let signingPublicKey: Data
    public let signature: Data

    public init(name: String, fingerprint: String, signingPublicKey: Data, signature: Data) {
        self.name = name
        self.fingerprint = fingerprint
        self.signingPublicKey = signingPublicKey
        self.signature = signature
    }
}

public enum ZwzV3Crypto {
    private static let wrapDomain = Data("ZWZ3 key wrap".utf8)
    private static let envelopeDomain = Data("ZWZ3 recipient envelope".utf8)

    public static func fingerprint(agreement: Data, signing: Data?) -> String {
        var canonical = Data("ZWZ3 fingerprint".utf8)
        canonical.appendLengthPrefixed(agreement)
        canonical.appendLengthPrefixed(signing ?? Data())
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    public static func wrap(
        contentKey: SymmetricKey,
        recipients: [ZwzRecipient],
        archiveID: UUID
    ) throws -> [ZwzV3RecipientEnvelope] {
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublicKey = ephemeralKey.publicKey.rawRepresentation

        return try recipients.map { recipient in
            do {
                let publicKey = try Curve25519.KeyAgreement.PublicKey(
                    rawRepresentation: recipient.agreementPublicKey
                )
                let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: publicKey)
                let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
                    using: SHA256.self,
                    salt: archiveID.bytes,
                    sharedInfo: wrapDomain,
                    outputByteCount: 32
                )
                let nonce = AES.GCM.Nonce()
                let sealed = try AES.GCM.seal(
                    contentKey.data,
                    using: wrappingKey,
                    nonce: nonce,
                    authenticating: envelopeAAD(
                        archiveID: archiveID,
                        recipientFingerprint: recipient.fingerprint,
                        ephemeralPublicKey: ephemeralPublicKey
                    )
                )
                return ZwzV3RecipientEnvelope(
                    recipientName: recipient.name,
                    recipientFingerprint: recipient.fingerprint,
                    ephemeralPublicKey: ephemeralPublicKey,
                    nonce: Data(nonce),
                    encryptedContentKey: sealed.ciphertext,
                    authenticationTag: sealed.tag
                )
            } catch {
                throw ZwzV3Error.invalidRecipientPublicKey(recipient.name)
            }
        }
    }

    public static func unwrap(
        _ envelope: ZwzV3RecipientEnvelope,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        archiveID: UUID
    ) throws -> SymmetricKey {
        do {
            let ephemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: envelope.ephemeralPublicKey
            )
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
            let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: archiveID.bytes,
                sharedInfo: wrapDomain,
                outputByteCount: 32
            )
            let nonce = try AES.GCM.Nonce(data: envelope.nonce)
            let sealed = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: envelope.encryptedContentKey,
                tag: envelope.authenticationTag
            )
            let contentKey = try AES.GCM.open(
                sealed,
                using: wrappingKey,
                authenticating: envelopeAAD(
                    archiveID: archiveID,
                    recipientFingerprint: envelope.recipientFingerprint,
                    ephemeralPublicKey: envelope.ephemeralPublicKey
                )
            )
            guard contentKey.count == 32 else { throw ZwzV3Error.keyUnwrapFailed }
            return SymmetricKey(data: contentKey)
        } catch {
            throw ZwzV3Error.keyUnwrapFailed
        }
    }

    public static func seal(
        _ plaintext: Data,
        key: SymmetricKey,
        nonce: AES.GCM.Nonce,
        aad: Data
    ) throws -> Data {
        do {
            guard let combined = try AES.GCM.seal(
                plaintext, using: key, nonce: nonce, authenticating: aad
            ).combined else {
                throw ZwzV3Error.authenticationFailed
            }
            return combined
        } catch {
            throw ZwzV3Error.authenticationFailed
        }
    }

    public static func open(_ combined: Data, key: SymmetricKey, aad: Data) throws -> Data {
        do {
            return try AES.GCM.open(
                AES.GCM.SealedBox(combined: combined), using: key, authenticating: aad
            )
        } catch {
            throw ZwzV3Error.authenticationFailed
        }
    }

    public static func sign(
        _ bytes: Data,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        do {
            return try privateKey.signature(for: bytes)
        } catch {
            throw ZwzV3Error.authenticationFailed
        }
    }

    public static func verify(_ signature: Data, bytes: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: bytes)
    }

    private static func envelopeAAD(
        archiveID: UUID,
        recipientFingerprint: String,
        ephemeralPublicKey: Data
    ) -> Data {
        var aad = envelopeDomain
        aad.append(archiveID.bytes)
        aad.appendLengthPrefixed(Data(recipientFingerprint.utf8))
        aad.append(ephemeralPublicKey)
        return aad
    }
}

extension UUID {
    var bytes: Data {
        var value = uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

private extension Data {
    mutating func appendLengthPrefixed(_ value: Data) {
        var length = UInt32(value.count).bigEndian
        append(Swift.withUnsafeBytes(of: &length) { Data($0) })
        append(value)
    }
}

private extension SymmetricKey {
    var data: Data { withUnsafeBytes { Data($0) } }
}
