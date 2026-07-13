import CryptoSwift
import Foundation

public struct ZwzV2CryptoContext: Sendable {
    public let archiveID: UUID
    public let salt: Data
    public let iterations: UInt32

    fileprivate let key: [UInt8]

    fileprivate init(archiveID: UUID, salt: Data, iterations: UInt32, key: [UInt8]) {
        self.archiveID = archiveID
        self.salt = salt
        self.iterations = iterations
        self.key = key
    }
}

public enum ZwzV2Crypto {
    private static let saltLength = 16
    private static let tagLength = 16
    private static let blockDomain: UInt8 = 0x42
    private static let indexDomain: UInt8 = 0x49

    public static func makeSalt() -> Data {
        Data((0..<saltLength).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
    }

    public static func deriveContext(
        password: String,
        salt: Data,
        iterations: UInt32,
        archiveID: UUID
    ) throws -> ZwzV2CryptoContext {
        guard !salt.isEmpty, iterations > 0 else {
            throw ZwzV2Error.malformedArchive("Invalid encryption parameters.")
        }

        let key = try PKCS5.PBKDF2(
            password: Array(password.utf8),
            salt: Array(salt),
            iterations: Int(iterations),
            keyLength: 32,
            variant: .sha2(.sha256)
        ).calculate()

        return ZwzV2CryptoContext(archiveID: archiveID, salt: salt, iterations: iterations, key: key)
    }

    public static func sealBlock(
        _ plaintext: Data,
        sequence: UInt64,
        context: ZwzV2CryptoContext
    ) throws -> (ciphertext: Data, tag: Data) {
        try seal(plaintext, nonce: makeNonce(domain: blockDomain, sequence: sequence, archiveID: context.archiveID), context: context)
    }

    public static func openBlock(
        _ ciphertext: Data,
        tag: Data,
        sequence: UInt64,
        context: ZwzV2CryptoContext
    ) throws -> Data {
        try open(ciphertext, tag: tag, nonce: makeNonce(domain: blockDomain, sequence: sequence, archiveID: context.archiveID), context: context)
    }

    public static func sealIndex(
        _ plaintext: Data,
        context: ZwzV2CryptoContext
    ) throws -> (ciphertext: Data, tag: Data) {
        try seal(plaintext, nonce: makeNonce(domain: indexDomain, sequence: 0, archiveID: context.archiveID), context: context)
    }

    public static func openIndex(
        _ ciphertext: Data,
        tag: Data,
        context: ZwzV2CryptoContext
    ) throws -> Data {
        try open(ciphertext, tag: tag, nonce: makeNonce(domain: indexDomain, sequence: 0, archiveID: context.archiveID), context: context)
    }
}

private extension ZwzV2Crypto {
    static func seal(
        _ plaintext: Data,
        nonce: [UInt8],
        context: ZwzV2CryptoContext
    ) throws -> (ciphertext: Data, tag: Data) {
        let gcm = GCM(iv: nonce, tagLength: tagLength, mode: .detached)
        let aes = try AES(key: context.key, blockMode: gcm, padding: .noPadding)
        let ciphertext = try aes.encrypt(Array(plaintext))
        guard let tag = gcm.authenticationTag else {
            throw ZwzV2Error.malformedArchive("Encryption failed to produce an authentication tag.")
        }
        return (Data(ciphertext), Data(tag))
    }

    static func open(
        _ ciphertext: Data,
        tag: Data,
        nonce: [UInt8],
        context: ZwzV2CryptoContext
    ) throws -> Data {
        do {
            let gcm = GCM(iv: nonce, authenticationTag: Array(tag), mode: .detached)
            let aes = try AES(key: context.key, blockMode: gcm, padding: .noPadding)
            return Data(try aes.decrypt(Array(ciphertext)))
        } catch {
            throw ZwzV2Error.wrongPasswordOrTamperedData
        }
    }

    static func makeNonce(domain: UInt8, sequence: UInt64, archiveID: UUID) -> [UInt8] {
        var nonce = [domain]
        var littleEndianSequence = sequence.littleEndian
        nonce.append(contentsOf: withUnsafeBytes(of: &littleEndianSequence, Array.init))
        nonce.append(contentsOf: withUnsafeBytes(of: archiveID.uuid, Array.init).prefix(3))
        return nonce
    }
}
