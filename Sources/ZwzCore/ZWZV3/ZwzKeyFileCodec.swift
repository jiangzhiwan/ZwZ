import CryptoKit
import CryptoSwift
import Foundation
import Security

struct ZwzPrivateIdentity: Equatable, Sendable {
    let name: String
    let fingerprint: String
    let agreementPrivateKey: Data
    let signingPrivateKey: Data

    var publicIdentity: ZwzPublicIdentity {
        get throws {
            let agreement = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: agreementPrivateKey
            )
            let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
            return ZwzPublicIdentity(
                name: name,
                fingerprint: fingerprint,
                agreementPublicKey: agreement.publicKey.rawRepresentation,
                signingPublicKey: signing.publicKey.rawRepresentation
            )
        }
    }
}

public enum ZwzKeyFileCodec {
    private static let publicHeaderLength = 32
    private static let backupHeaderLength = 64
    private static let backupSaltLength = 16
    private static let backupNonceLength = 12
    private static let backupTagLength = 16
    private static let privateHeaderLength = 24

    public static func encodePublic(_ identity: ZwzPublicIdentity) throws -> Data {
        do {
            let name = Data(identity.name.utf8)
            guard !name.isEmpty,
                  identity.agreementPublicKey.count == 32,
                  identity.signingPublicKey.count == 32,
                  name.count <= Int(UInt32.max) else {
                throw ZwzV3Error.invalidKeyFile
            }
            _ = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: identity.agreementPublicKey
            )
            _ = try Curve25519.Signing.PublicKey(rawRepresentation: identity.signingPublicKey)
            let fingerprint = ZwzV3Crypto.fingerprint(
                agreement: identity.agreementPublicKey,
                signing: identity.signingPublicKey
            )
            let fingerprintData = Data(fingerprint.utf8)
            var header = Data(repeating: 0, count: publicHeaderLength)
            header.replaceSubrange(0..<4, with: Data("ZWZP".utf8))
            write(UInt16(1), to: &header, at: 4)
            write(UInt16(publicHeaderLength), to: &header, at: 6)
            header[8] = 1
            header[9] = 1
            header[10] = 1
            write(UInt32(name.count), to: &header, at: 12)
            write(UInt32(fingerprintData.count), to: &header, at: 16)
            write(UInt32(32), to: &header, at: 20)
            write(UInt32(32), to: &header, at: 24)
            return header + name + fingerprintData + identity.agreementPublicKey
                + identity.signingPublicKey
        } catch {
            throw ZwzV3Error.invalidKeyFile
        }
    }

    public static func decodePublic(_ input: Data) throws -> ZwzPublicIdentity {
        do {
            let data = Data(input)
            guard data.count >= publicHeaderLength,
                  data.prefix(4) == Data("ZWZP".utf8),
                  try readUInt16(data, at: 4) == 1,
                  try readUInt16(data, at: 6) == UInt16(publicHeaderLength),
                  data[8] == 1, data[9] == 1, data[10] == 1, data[11] == 0,
                  data[28..<32].allSatisfy({ $0 == 0 }) else {
                throw ZwzV3Error.invalidKeyFile
            }
            let nameLength = UInt64(try readUInt32(data, at: 12))
            let fingerprintLength = UInt64(try readUInt32(data, at: 16))
            let agreementLength = UInt64(try readUInt32(data, at: 20))
            let signingLength = UInt64(try readUInt32(data, at: 24))
            guard nameLength > 0, fingerprintLength == 64,
                  agreementLength == 32, signingLength == 32 else {
                throw ZwzV3Error.invalidKeyFile
            }
            let end = try checkedSum([
                UInt64(publicHeaderLength), nameLength, fingerprintLength,
                agreementLength, signingLength
            ])
            guard end == UInt64(data.count) else { throw ZwzV3Error.invalidKeyFile }

            var offset = publicHeaderLength
            let nameData = try take(data, offset: &offset, count: nameLength)
            let fingerprintData = try take(data, offset: &offset, count: fingerprintLength)
            let agreement = try take(data, offset: &offset, count: agreementLength)
            let signing = try take(data, offset: &offset, count: signingLength)
            guard let name = String(data: nameData, encoding: .utf8), !name.isEmpty,
                  let fingerprint = String(data: fingerprintData, encoding: .utf8),
                  isCanonicalFingerprint(fingerprint) else {
                throw ZwzV3Error.invalidKeyFile
            }
            _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreement)
            _ = try Curve25519.Signing.PublicKey(rawRepresentation: signing)
            guard fingerprint == ZwzV3Crypto.fingerprint(
                agreement: agreement, signing: signing
            ) else { throw ZwzV3Error.invalidKeyFile }
            return ZwzPublicIdentity(
                name: name,
                fingerprint: fingerprint,
                agreementPublicKey: agreement,
                signingPublicKey: signing
            )
        } catch {
            throw ZwzV3Error.invalidKeyFile
        }
    }

    static func encodeBackup(_ identity: ZwzPrivateIdentity, password: String) throws -> Data {
        var salt = Data(repeating: 0, count: backupSaltLength)
        let randomStatus = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw ZwzV3Error.invalidBackup
        }
        return try encodeBackup(
            identity,
            password: password,
            salt: salt,
            nonce: Data(AES.GCM.Nonce()),
            deriveKey: deriveBackupKey
        )
    }

    static func encodeBackup(
        _ identity: ZwzPrivateIdentity,
        password: String,
        salt: Data,
        nonce: Data
    ) throws -> Data {
        try encodeBackup(
            identity,
            password: password,
            salt: salt,
            nonce: nonce,
            deriveKey: deriveBackupKey
        )
    }

    static func encodeBackup(
        _ identity: ZwzPrivateIdentity,
        password: String,
        salt: Data,
        nonce: Data,
        deriveKey: (_ password: String, _ salt: Data) throws -> Data
    ) throws -> Data {
        do {
            guard !password.isEmpty, salt.count == backupSaltLength,
                  nonce.count == backupNonceLength else { throw ZwzV3Error.invalidBackup }
            let plaintext = try encodePrivateIdentity(identity)
            var header = Data(repeating: 0, count: backupHeaderLength)
            header.replaceSubrange(0..<4, with: Data("ZWZB".utf8))
            write(UInt16(1), to: &header, at: 4)
            write(UInt16(backupHeaderLength), to: &header, at: 6)
            header[8] = 1
            header[9] = 1
            header[10] = 1
            header[11] = 1
            write(UInt32(65_536), to: &header, at: 12)
            write(UInt32(8), to: &header, at: 16)
            write(UInt32(1), to: &header, at: 20)
            write(UInt16(backupSaltLength), to: &header, at: 24)
            write(UInt16(backupNonceLength), to: &header, at: 26)
            write(UInt64(plaintext.count), to: &header, at: 28)
            let aad = header + salt + nonce
            let key = try deriveKey(password, salt)
            guard key.count == 32 else { throw ZwzV3Error.invalidBackup }
            let sealed = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: key),
                nonce: AES.GCM.Nonce(data: nonce),
                authenticating: aad
            )
            guard sealed.ciphertext.count == plaintext.count,
                  sealed.tag.count == backupTagLength else { throw ZwzV3Error.invalidBackup }
            return aad + sealed.ciphertext + sealed.tag
        } catch {
            throw ZwzV3Error.invalidBackup
        }
    }

    static func decodeBackup(_ input: Data, password: String) throws -> ZwzPrivateIdentity {
        try decodeBackup(input, password: password, deriveKey: deriveBackupKey)
    }

    static func decodeBackup(
        _ input: Data,
        password: String,
        deriveKey: (_ password: String, _ salt: Data) throws -> Data
    ) throws -> ZwzPrivateIdentity {
        do {
            let data = Data(input)
            guard !password.isEmpty, data.count >= backupHeaderLength,
                  data.prefix(4) == Data("ZWZB".utf8),
                  try readUInt16(data, at: 4) == 1,
                  try readUInt16(data, at: 6) == UInt16(backupHeaderLength),
                  data[8] == 1, data[9] == 1, data[10] == 1, data[11] == 1,
                  try readUInt32(data, at: 12) == 65_536,
                  try readUInt32(data, at: 16) == 8,
                  try readUInt32(data, at: 20) == 1,
                  try readUInt16(data, at: 24) == UInt16(backupSaltLength),
                  try readUInt16(data, at: 26) == UInt16(backupNonceLength),
                  data[36..<64].allSatisfy({ $0 == 0 }) else {
                throw ZwzV3Error.invalidBackup
            }
            let ciphertextLength = try readUInt64(data, at: 28)
            let minimumPlaintextLength = UInt64(privateHeaderLength + 1 + 64 + 32 + 32)
            guard ciphertextLength >= minimumPlaintextLength else {
                throw ZwzV3Error.invalidBackup
            }
            let expectedLength = try checkedSum([
                UInt64(backupHeaderLength), UInt64(backupSaltLength),
                UInt64(backupNonceLength), ciphertextLength, UInt64(backupTagLength)
            ])
            guard expectedLength == UInt64(data.count) else { throw ZwzV3Error.invalidBackup }

            var offset = backupHeaderLength
            let salt = try take(data, offset: &offset, count: UInt64(backupSaltLength))
            let nonceData = try take(data, offset: &offset, count: UInt64(backupNonceLength))
            let ciphertext = try take(data, offset: &offset, count: ciphertextLength)
            let tag = try take(data, offset: &offset, count: UInt64(backupTagLength))
            let keyData = try deriveKey(password, salt)
            guard keyData.count == 32 else { throw ZwzV3Error.invalidBackup }
            let sealed = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData), ciphertext: ciphertext, tag: tag
            )
            let aadEnd = backupHeaderLength + backupSaltLength + backupNonceLength
            let plaintext = try AES.GCM.open(
                sealed,
                using: SymmetricKey(data: keyData),
                authenticating: data.subdata(in: 0..<aadEnd)
            )
            return try decodePrivateIdentity(plaintext)
        } catch {
            throw ZwzV3Error.invalidBackup
        }
    }

    private static func encodePrivateIdentity(_ identity: ZwzPrivateIdentity) throws -> Data {
        let name = Data(identity.name.utf8)
        guard !name.isEmpty, name.count <= Int(UInt32.max),
              isCanonicalFingerprint(identity.fingerprint),
              identity.agreementPrivateKey.count == 32,
              identity.signingPrivateKey.count == 32 else { throw ZwzV3Error.invalidBackup }
        let agreement = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: identity.agreementPrivateKey
        )
        let signing = try Curve25519.Signing.PrivateKey(
            rawRepresentation: identity.signingPrivateKey
        )
        let fingerprint = ZwzV3Crypto.fingerprint(
            agreement: agreement.publicKey.rawRepresentation,
            signing: signing.publicKey.rawRepresentation
        )
        guard fingerprint == identity.fingerprint else { throw ZwzV3Error.invalidBackup }

        var header = Data(repeating: 0, count: privateHeaderLength)
        header.replaceSubrange(0..<4, with: Data("ZWZI".utf8))
        write(UInt16(1), to: &header, at: 4)
        write(UInt32(name.count), to: &header, at: 8)
        write(UInt32(64), to: &header, at: 12)
        write(UInt32(32), to: &header, at: 16)
        write(UInt32(32), to: &header, at: 20)
        return header + name + Data(fingerprint.utf8)
            + identity.agreementPrivateKey + identity.signingPrivateKey
    }

    private static func decodePrivateIdentity(_ input: Data) throws -> ZwzPrivateIdentity {
        let data = Data(input)
        guard data.count >= privateHeaderLength,
              data.prefix(4) == Data("ZWZI".utf8),
              try readUInt16(data, at: 4) == 1,
              try readUInt16(data, at: 6) == 0 else { throw ZwzV3Error.invalidBackup }
        let nameLength = UInt64(try readUInt32(data, at: 8))
        let fingerprintLength = UInt64(try readUInt32(data, at: 12))
        let agreementLength = UInt64(try readUInt32(data, at: 16))
        let signingLength = UInt64(try readUInt32(data, at: 20))
        guard nameLength > 0, fingerprintLength == 64,
              agreementLength == 32, signingLength == 32,
              try checkedSum([
                UInt64(privateHeaderLength), nameLength, fingerprintLength,
                agreementLength, signingLength
              ]) == UInt64(data.count) else { throw ZwzV3Error.invalidBackup }
        var offset = privateHeaderLength
        let nameData = try take(data, offset: &offset, count: nameLength)
        let fingerprintData = try take(data, offset: &offset, count: fingerprintLength)
        let agreementData = try take(data, offset: &offset, count: agreementLength)
        let signingData = try take(data, offset: &offset, count: signingLength)
        guard let name = String(data: nameData, encoding: .utf8), !name.isEmpty,
              let fingerprint = String(data: fingerprintData, encoding: .utf8),
              isCanonicalFingerprint(fingerprint) else { throw ZwzV3Error.invalidBackup }
        let agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementData)
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: signingData)
        guard fingerprint == ZwzV3Crypto.fingerprint(
            agreement: agreement.publicKey.rawRepresentation,
            signing: signing.publicKey.rawRepresentation
        ) else { throw ZwzV3Error.invalidBackup }
        return ZwzPrivateIdentity(
            name: name,
            fingerprint: fingerprint,
            agreementPrivateKey: agreementData,
            signingPrivateKey: signingData
        )
    }

    private static func deriveBackupKey(password: String, salt: Data) throws -> Data {
        Data(try Scrypt(
            password: Array(password.utf8), salt: Array(salt), dkLen: 32,
            N: 65_536, r: 8, p: 1
        ).calculate())
    }

    private static func isCanonicalFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func checkedSum(_ values: [UInt64]) throws -> UInt64 {
        try values.reduce(0) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            guard !overflow else { throw ZwzV3Error.invalidBackup }
            return result
        }
    }

    private static func take(_ data: Data, offset: inout Int, count: UInt64) throws -> Data {
        guard count <= UInt64(Int.max) else { throw ZwzV3Error.invalidBackup }
        let intCount = Int(count)
        let (end, overflow) = offset.addingReportingOverflow(intCount)
        guard !overflow, end <= data.count else { throw ZwzV3Error.invalidBackup }
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }

    private static func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        try readInteger(data, at: offset, as: UInt16.self)
    }

    private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        try readInteger(data, at: offset, as: UInt32.self)
    }

    private static func readUInt64(_ data: Data, at offset: Int) throws -> UInt64 {
        try readInteger(data, at: offset, as: UInt64.self)
    }

    private static func readInteger<T: FixedWidthInteger>(
        _ data: Data, at offset: Int, as: T.Type
    ) throws -> T {
        let (end, overflow) = offset.addingReportingOverflow(MemoryLayout<T>.size)
        guard !overflow, offset >= 0, end <= data.count else { throw ZwzV3Error.invalidBackup }
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { destination in
            data.copyBytes(to: destination, from: offset..<end)
        }
        return T(littleEndian: value)
    }

    private static func write<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
    }
}
