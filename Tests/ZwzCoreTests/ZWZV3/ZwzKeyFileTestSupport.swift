import CryptoKit
import Foundation
@testable import ZwzCore

enum ZwzKeyFileTestSupport {
    static let agreementPrivateKey = Data((0..<32).map { UInt8($0 + 1) })
    static let signingPrivateKey = Data((0..<32).map { UInt8($0 + 65) })
    static let salt = Data((0..<16).map(UInt8.init))
    static let nonce = Data((16..<28).map(UInt8.init))
    static let fastDerivedKey = Data(repeating: 0xa5, count: 32)

    static func privateIdentity(name: String = "Alice") throws -> ZwzPrivateIdentity {
        let agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementPrivateKey)
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
        return ZwzPrivateIdentity(
            name: name,
            fingerprint: ZwzV3Crypto.fingerprint(
                agreement: agreement.publicKey.rawRepresentation,
                signing: signing.publicKey.rawRepresentation
            ),
            agreementPrivateKey: agreementPrivateKey,
            signingPrivateKey: signingPrivateKey
        )
    }

    static func publicIdentity(name: String = "Alice") throws -> ZwzPublicIdentity {
        try privateIdentity(name: name).publicIdentity
    }

    static func backup(password: String = "correct horse battery staple") throws -> Data {
        try ZwzKeyFileCodec.encodeBackup(
            privateIdentity(), password: password, salt: salt, nonce: nonce
        )
    }

    static func fastBackup(password: String = "correct horse battery staple") throws -> Data {
        try ZwzKeyFileCodec.encodeBackup(
            privateIdentity(),
            password: password,
            salt: salt,
            nonce: nonce,
            deriveKey: { _, _ in fastDerivedKey }
        )
    }

    static func replacing(_ data: Data, at offset: Int, with byte: UInt8) -> Data {
        var result = data
        result[offset] = byte
        return result
    }

    static func writing<T: FixedWidthInteger>(_ value: T, to data: Data, at offset: Int) -> Data {
        var result = data
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            result.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        return result
    }
}
