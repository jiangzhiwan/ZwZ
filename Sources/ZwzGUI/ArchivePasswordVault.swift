import CryptoKit
import Foundation
import Security

enum ArchivePasswordStorage: String, CaseIterable {
    case local
    case keychain
}

struct SavedArchivePassword: Codable, Identifiable, Equatable {
    let fingerprint: String
    var archiveName: String
    let createdAt: Date

    var id: String { fingerprint }
}

enum ArchivePasswordVaultError: LocalizedError, Equatable {
    case locked
    case invalidMasterPassword
    case masterPasswordRequired
    case keychain(OSStatus)
    case corruptVault

    var errorDescription: String? {
        switch self {
        case .locked: return "Password vault is locked."
        case .invalidMasterPassword: return "The master password is incorrect."
        case .masterPasswordRequired: return "Set a master password before saving local passwords."
        case .keychain(let status): return "Keychain error: \(status)."
        case .corruptVault: return "The local password vault could not be read."
        }
    }
}

enum ArchiveFingerprint {
    static func make(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class ArchivePasswordVault: ObservableObject {
    static let shared = ArchivePasswordVault()

    static let rememberEnabledKey = "zwz_password_memory_enabled"
    static let useKeychainKey = "zwz_password_memory_use_keychain"
    static let migrateOnChangeKey = "zwz_password_memory_migrate_on_change"

    @Published private(set) var isUnlocked = false
    @Published private(set) var localRecords: [SavedArchivePassword] = []
    @Published private(set) var keychainRecords: [SavedArchivePassword] = []

    private struct LocalEntry: Codable {
        let fingerprint: String
        let archiveName: String
        let createdAt: Date
        let encryptedPassword: Data
    }

    private struct LocalVault: Codable {
        let version: Int
        let salt: Data
        let verifier: Data
        var entries: [LocalEntry]
    }

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let baseURL: URL
    private var sessionKey: SymmetricKey?
    private var localVault: LocalVault?

    init(
        baseURL: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.baseURL = baseURL ?? Self.defaultBaseURL(fileManager: fileManager)
        loadIndexes()
    }

    var isConfigured: Bool { fileManager.fileExists(atPath: localVaultURL.path) }

    var activeStorage: ArchivePasswordStorage {
        defaults.bool(forKey: Self.useKeychainKey) ? .keychain : .local
    }

    func records(for storage: ArchivePasswordStorage) -> [SavedArchivePassword] {
        switch storage {
        case .local: return localRecords
        case .keychain: return keychainRecords
        }
    }

    func configure(masterPassword: String) throws {
        guard !masterPassword.isEmpty else { throw ArchivePasswordVaultError.masterPasswordRequired }
        guard !isConfigured else {
            try unlock(masterPassword: masterPassword)
            return
        }

        let salt = randomData(count: 16)
        let key = try deriveKey(password: masterPassword, salt: salt)
        let verifier = try encrypt(Data("zwz-password-vault-v1".utf8), with: key)
        localVault = LocalVault(version: 1, salt: salt, verifier: verifier, entries: [])
        sessionKey = key
        isUnlocked = true
        try persistLocalVault()
    }

    func unlock(masterPassword: String) throws {
        guard !masterPassword.isEmpty else { throw ArchivePasswordVaultError.invalidMasterPassword }
        let vault = try readLocalVault()
        let key = try deriveKey(password: masterPassword, salt: vault.salt)
        guard try decrypt(vault.verifier, with: key) == Data("zwz-password-vault-v1".utf8) else {
            throw ArchivePasswordVaultError.invalidMasterPassword
        }
        localVault = vault
        sessionKey = key
        isUnlocked = true
        refreshLocalRecords()
    }

    func lock() {
        sessionKey = nil
        localVault = nil
        isUnlocked = false
    }

    func password(for fingerprint: String, storage: ArchivePasswordStorage) throws -> String? {
        switch storage {
        case .local:
            guard let key = sessionKey else { throw ArchivePasswordVaultError.locked }
            let vault = try loadedLocalVault()
            guard let entry = vault.entries.first(where: { $0.fingerprint == fingerprint }) else { return nil }
            guard let password = String(data: try decrypt(entry.encryptedPassword, with: key), encoding: .utf8) else {
                throw ArchivePasswordVaultError.corruptVault
            }
            return password
        case .keychain:
            return try readKeychainPassword(fingerprint: fingerprint)
        }
    }

    func save(password: String, fingerprint: String, archiveName: String, storage: ArchivePasswordStorage) throws {
        let record = SavedArchivePassword(fingerprint: fingerprint, archiveName: archiveName, createdAt: Date())
        switch storage {
        case .local:
            guard let key = sessionKey else { throw ArchivePasswordVaultError.locked }
            var vault = try loadedLocalVault()
            let entry = LocalEntry(
                fingerprint: fingerprint,
                archiveName: archiveName,
                createdAt: record.createdAt,
                encryptedPassword: try encrypt(Data(password.utf8), with: key)
            )
            vault.entries.removeAll { $0.fingerprint == fingerprint }
            vault.entries.append(entry)
            localVault = vault
            try persistLocalVault()
        case .keychain:
            try writeKeychainPassword(password, fingerprint: fingerprint)
            upsert(record, in: &keychainRecords)
            try persistKeychainIndex()
        }
    }

    func remove(fingerprint: String, storage: ArchivePasswordStorage) throws {
        switch storage {
        case .local:
            var vault = try loadedLocalVault()
            vault.entries.removeAll { $0.fingerprint == fingerprint }
            localVault = vault
            try persistLocalVault()
        case .keychain:
            try deleteKeychainPassword(fingerprint: fingerprint)
            keychainRecords.removeAll { $0.fingerprint == fingerprint }
            try persistKeychainIndex()
        }
    }

    func clear(storage: ArchivePasswordStorage) throws {
        switch storage {
        case .local:
            var vault = try loadedLocalVault()
            vault.entries = []
            localVault = vault
            try persistLocalVault()
        case .keychain:
            for record in keychainRecords { try deleteKeychainPassword(fingerprint: record.fingerprint) }
            keychainRecords = []
            try persistKeychainIndex()
        }
    }

    func resetLocalVault() throws {
        try? fileManager.removeItem(at: localVaultURL)
        localRecords = []
        lock()
    }

    func migrate(from source: ArchivePasswordStorage, to destination: ArchivePasswordStorage) throws {
        guard source != destination else { return }
        for record in records(for: source) {
            if let password = try password(for: record.fingerprint, storage: source) {
                try save(password: password, fingerprint: record.fingerprint, archiveName: record.archiveName, storage: destination)
                try remove(fingerprint: record.fingerprint, storage: source)
            }
        }
    }

    private var localVaultURL: URL { baseURL.appendingPathComponent("archive-password-vault.json") }
    private var keychainIndexURL: URL { baseURL.appendingPathComponent("archive-password-keychain-index.json") }
    private static let keychainService = "com.jiangzhiwan.zwz.archive-passwords"

    private static func defaultBaseURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("ZwZ", isDirectory: true)
    }

    private func loadIndexes() {
        guard let data = try? Data(contentsOf: keychainIndexURL),
              let records = try? JSONDecoder().decode([SavedArchivePassword].self, from: data) else { return }
        keychainRecords = records
    }

    private func refreshLocalRecords() {
        localRecords = (localVault?.entries ?? []).map {
            SavedArchivePassword(fingerprint: $0.fingerprint, archiveName: $0.archiveName, createdAt: $0.createdAt)
        }
    }

    private func loadedLocalVault() throws -> LocalVault {
        guard sessionKey != nil else { throw ArchivePasswordVaultError.locked }
        if let localVault { return localVault }
        let vault = try readLocalVault()
        localVault = vault
        refreshLocalRecords()
        return vault
    }

    private func readLocalVault() throws -> LocalVault {
        guard let data = try? Data(contentsOf: localVaultURL),
              let vault = try? JSONDecoder().decode(LocalVault.self, from: data),
              vault.version == 1 else { throw ArchivePasswordVaultError.corruptVault }
        return vault
    }

    private func persistLocalVault() throws {
        guard let localVault else { return }
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(localVault)
        try data.write(to: localVaultURL, options: .atomic)
        refreshLocalRecords()
    }

    private func persistKeychainIndex() throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(keychainRecords)
        try data.write(to: keychainIndexURL, options: .atomic)
    }

    private func upsert(_ record: SavedArchivePassword, in records: inout [SavedArchivePassword]) {
        records.removeAll { $0.fingerprint == record.fingerprint }
        records.append(record)
        records.sort { $0.createdAt > $1.createdAt }
    }

    private func writeKeychainPassword(_ password: String, fingerprint: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: fingerprint
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = Data(password.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ArchivePasswordVaultError.keychain(status) }
    }

    private func readKeychainPassword(fingerprint: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: fingerprint,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ArchivePasswordVaultError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKeychainPassword(fingerprint: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: fingerprint
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ArchivePasswordVaultError.keychain(status)
        }
    }

    private func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        let passwordKey = SymmetricKey(data: Data(password.utf8))
        var input = salt
        input.append(contentsOf: [0, 0, 0, 1])
        var block = Data(HMAC<SHA256>.authenticationCode(for: input, using: passwordKey))
        var result = [UInt8](block)

        // PBKDF2-HMAC-SHA256, 150,000 rounds for a 256-bit vault key.
        for _ in 1..<150_000 {
            block = Data(HMAC<SHA256>.authenticationCode(for: block, using: passwordKey))
            let bytes = [UInt8](block)
            for index in result.indices { result[index] ^= bytes[index] }
        }
        return SymmetricKey(data: Data(result))
    }

    private func encrypt(_ data: Data, with key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw ArchivePasswordVaultError.corruptVault }
        return combined
    }

    private func decrypt(_ data: Data, with key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }

    private func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
