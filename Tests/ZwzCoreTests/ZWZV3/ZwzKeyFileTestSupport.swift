import CryptoKit
import Foundation
import Security
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

final class FakeZwzKeychainBackend: ZwzKeychainBackend, @unchecked Sendable {
    enum WriteOperation: Equatable {
        case add(ZwzKeychainItemKind)
        case update(ZwzKeychainItemKind)
        case delete(ZwzKeychainItemKind)
    }

    struct ItemKey: Hashable {
        let kind: ZwzKeychainItemKind
        let fingerprint: String
    }

    private let lock = NSLock()
    private var items: [ItemKey: Data] = [:]
    private var activeCalls = 0
    private(set) var maximumConcurrentCalls = 0
    private(set) var deleteCalls: [ZwzKeychainItemKind] = []
    private(set) var transactionWrites: [WriteOperation] = []
    var addFailures: [ZwzKeychainItemKind: OSStatus] = [:]
    var updateFailures: [ZwzKeychainItemKind: OSStatus] = [:]
    var deleteFailures: [ZwzKeychainItemKind: OSStatus] = [:]
    var operationDelay: TimeInterval = 0

    func seed(kind: ZwzKeychainItemKind, fingerprint: String, data: Data) {
        lock.withLock { items[ItemKey(kind: kind, fingerprint: fingerprint)] = data }
    }

    func data(kind: ZwzKeychainItemKind, fingerprint: String) -> Data? {
        lock.withLock { items[ItemKey(kind: kind, fingerprint: fingerprint)] }
    }

    func add(kind: ZwzKeychainItemKind, fingerprint: String, data: Data) -> OSStatus {
        call {
            transactionWrites.append(.add(kind))
            if let failure = addFailures[kind] { return failure }
            let key = ItemKey(kind: kind, fingerprint: fingerprint)
            guard items[key] == nil else { return errSecDuplicateItem }
            items[key] = data
            return errSecSuccess
        }
    }

    func update(kind: ZwzKeychainItemKind, fingerprint: String, data: Data) -> OSStatus {
        call {
            transactionWrites.append(.update(kind))
            if let failure = updateFailures[kind] { return failure }
            let key = ItemKey(kind: kind, fingerprint: fingerprint)
            guard items[key] != nil else { return errSecItemNotFound }
            items[key] = data
            return errSecSuccess
        }
    }

    func read(
        kind: ZwzKeychainItemKind,
        fingerprint: String,
        authenticationReason: String?
    ) -> ZwzKeychainReadResult {
        call {
            guard let data = items[ItemKey(kind: kind, fingerprint: fingerprint)] else {
                return ZwzKeychainReadResult(status: errSecItemNotFound, items: [])
            }
            return ZwzKeychainReadResult(status: errSecSuccess, items: [data])
        }
    }

    func readAll(kind: ZwzKeychainItemKind) -> ZwzKeychainReadResult {
        call {
            let values = items.compactMap { $0.key.kind == kind ? $0.value : nil }
            return ZwzKeychainReadResult(
                status: values.isEmpty ? errSecItemNotFound : errSecSuccess,
                items: values
            )
        }
    }

    func delete(kind: ZwzKeychainItemKind, fingerprint: String) -> OSStatus {
        call {
            deleteCalls.append(kind)
            transactionWrites.append(.delete(kind))
            if let failure = deleteFailures[kind] { return failure }
            let removed = items.removeValue(forKey: ItemKey(kind: kind, fingerprint: fingerprint))
            return removed == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    private func call<T>(_ operation: () -> T) -> T {
        lock.lock()
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        lock.unlock()
        if operationDelay > 0 { Thread.sleep(forTimeInterval: operationDelay) }
        lock.lock()
        defer {
            activeCalls -= 1
            lock.unlock()
        }
        return operation()
    }
}
