import Combine
import Foundation
import ZwzCore

enum IdentityManagerViewModelError: LocalizedError, Equatable, Sendable {
    case invalidName
    case emptyPassword
    case passwordConfirmationMismatch
    case operationInProgress
    case noPendingDeletion

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "The identity name must not be empty."
        case .emptyPassword:
            "The backup password must not be empty."
        case .passwordConfirmationMismatch:
            "The backup passwords do not match."
        case .operationInProgress:
            "Another key operation is already in progress."
        case .noPendingDeletion:
            "No key is waiting to be deleted."
        }
    }
}

enum IdentityManagerFileError: LocalizedError, Equatable, Sendable {
    case invalidFileSize
    case fileTooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidFileSize:
            "The selected key file size could not be verified."
        case .fileTooLarge(let maximumBytes):
            "The selected key file exceeds the \(maximumBytes)-byte limit."
        }
    }
}

enum IdentityManagerSelection: Hashable, Sendable {
    case localIdentity(String)
    case contact(String)

    var fingerprint: String {
        switch self {
        case .localIdentity(let fingerprint), .contact(let fingerprint): fingerprint
        }
    }

    var isLocalIdentity: Bool {
        if case .localIdentity = self { return true }
        return false
    }
}

enum IdentityManagerItemKind: Equatable, Sendable {
    case localIdentity
    case contact
}

struct IdentityManagerDeletion: Equatable, Sendable, Identifiable {
    let kind: IdentityManagerItemKind
    let name: String
    let fingerprint: String

    var id: String { fingerprint }
    var requiresPermanentLossWarning: Bool { kind == .localIdentity }
}

enum IdentityManagerConflictKind: Equatable, Sendable {
    case publicImport
    case privateRestore
}

struct IdentityManagerConflict: Equatable, Sendable, Identifiable {
    let kind: IdentityManagerConflictKind
    let fingerprint: String

    var id: String { "\(kind)-\(fingerprint)" }
}

@MainActor
final class IdentityManagerViewModel: ObservableObject {
    @Published private(set) var identities: [ZwzIdentityMetadata] = []
    @Published private(set) var contacts: [ZwzPublicIdentity] = []
    @Published var selection: IdentityManagerSelection?
    @Published private(set) var isLoading = false
    @Published private(set) var isBusy = false
    @Published private(set) var pendingDeletion: IdentityManagerDeletion?
    @Published private(set) var pendingConflict: IdentityManagerConflict?
    @Published private(set) var errorMessage: String?
    @Published private(set) var successMessage: String?

    let store: any ZwzIdentityStore

    private var onPrivateRestore: (@MainActor @Sendable () -> Void)?

    init(
        store: any ZwzIdentityStore,
        onPrivateRestore: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.store = store
        self.onPrivateRestore = onPrivateRestore
    }

    var selectedName: String? {
        switch selection {
        case .localIdentity(let fingerprint):
            identities.first { $0.fingerprint == fingerprint }?.name
        case .contact(let fingerprint):
            contacts.first { $0.fingerprint == fingerprint }?.name
        case nil:
            nil
        }
    }

    var selectedFingerprint: String? { selection?.fingerprint }
    var selectedIsLocalIdentity: Bool { selection?.isLocalIdentity == true }

    func refresh() async throws {
        guard !isLoading else { return }
        guard !isBusy else {
            let error = IdentityManagerViewModelError.operationInProgress
            present(error)
            throw error
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let snapshot = try await Self.loadSnapshot(from: store)
            try Task.checkCancellation()
            apply(snapshot)
        } catch {
            if error is CancellationError { throw error }
            present(error)
            throw error
        }
    }

    @discardableResult
    func createIdentity(named name: String) async throws -> ZwzIdentityMetadata {
        let name = try validatedName(name)
        let identity = try await performMutation(success: SettingsStrings.text(
            "已创建身份“\(name)”。",
            "Created identity “\(name)”."
        )) { store in
            try store.createIdentity(named: name)
        }
        upsert(identity)
        selection = .localIdentity(identity.fingerprint)
        return identity
    }

    func rename(fingerprint: String, to name: String) async throws {
        let name = try validatedName(name)
        let previousSelection = selection
        try await performMutation(success: SettingsStrings.text(
            "名称已更新。",
            "Name updated."
        )) { store in
            try store.rename(fingerprint: fingerprint, to: name)
        }
        renameLocalRecord(fingerprint: fingerprint, to: name)
        if previousSelection?.fingerprint == fingerprint {
            selection = previousSelection
        }
    }

    func requestDelete(_ identity: ZwzIdentityMetadata) {
        pendingDeletion = IdentityManagerDeletion(
            kind: .localIdentity,
            name: identity.name,
            fingerprint: identity.fingerprint
        )
        errorMessage = nil
        successMessage = nil
    }

    func requestDelete(_ contact: ZwzPublicIdentity) {
        pendingDeletion = IdentityManagerDeletion(
            kind: .contact,
            name: contact.name,
            fingerprint: contact.fingerprint
        )
        errorMessage = nil
        successMessage = nil
    }

    func requestDeleteSelection() {
        switch selection {
        case .localIdentity(let fingerprint):
            guard let identity = identities.first(where: { $0.fingerprint == fingerprint }) else {
                return
            }
            requestDelete(identity)
        case .contact(let fingerprint):
            guard let contact = contacts.first(where: { $0.fingerprint == fingerprint }) else {
                return
            }
            requestDelete(contact)
        case nil:
            return
        }
    }

    func cancelDelete() {
        pendingDeletion = nil
    }

    func confirmDelete() async throws {
        guard let pendingDeletion else {
            let error = IdentityManagerViewModelError.noPendingDeletion
            present(error)
            throw error
        }
        try await performMutation(success: SettingsStrings.text(
            "密钥记录已删除。",
            "Key record deleted."
        )) { store in
            try store.delete(fingerprint: pendingDeletion.fingerprint)
        }
        removeLocalRecord(fingerprint: pendingDeletion.fingerprint)
        self.pendingDeletion = nil
        if selection?.fingerprint == pendingDeletion.fingerprint {
            selection = nil
        }
    }

    @discardableResult
    func importPublicIdentity(
        _ data: Data,
        conflict: ZwzIdentityConflictPolicy = .requireConfirmation
    ) async throws -> ZwzPublicIdentity {
        let identity = try await performMutation(
            conflictKind: .publicImport,
            success: SettingsStrings.text("公钥已导入。", "Public key imported.")
        ) { store in
            try store.importPublicIdentity(data, conflict: conflict)
        }
        pendingConflict = nil
        upsert(identity)
        if identities.contains(where: { $0.fingerprint == identity.fingerprint }) {
            selection = .localIdentity(identity.fingerprint)
        } else {
            selection = .contact(identity.fingerprint)
        }
        return identity
    }

    func exportPublicIdentity(fingerprint: String) async throws -> Data {
        try await performRead { store in
            try store.exportPublicIdentity(fingerprint: fingerprint)
        }
    }

    func exportPrivateBackup(
        fingerprint: String,
        password: String,
        confirmation: String
    ) async throws -> Data {
        try validatePassword(password, confirmation: confirmation)
        return try await performRead { store in
            try store.exportPrivateBackup(fingerprint: fingerprint, password: password)
        }
    }

    @discardableResult
    func restorePrivateBackup(
        _ data: Data,
        password: String,
        conflict: ZwzIdentityConflictPolicy = .requireConfirmation
    ) async throws -> ZwzIdentityMetadata {
        guard !password.isEmpty else {
            let error = IdentityManagerViewModelError.emptyPassword
            present(error)
            throw error
        }
        let identity = try await performMutation(
            conflictKind: .privateRestore,
            success: SettingsStrings.text("私钥备份已恢复。", "Private key backup restored.")
        ) { store in
            try store.importPrivateBackup(data, password: password, conflict: conflict)
        }
        pendingConflict = nil
        upsert(identity)
        selection = .localIdentity(identity.fingerprint)
        if let callback = onPrivateRestore {
            onPrivateRestore = nil
            callback()
        }
        return identity
    }

    func cancelConflict() {
        pendingConflict = nil
    }

    func clearTransientState() {
        errorMessage = nil
        successMessage = nil
        pendingConflict = nil
    }

    func reportExternalError(_ error: Error) {
        present(error)
    }

    func reportSuccess(_ message: String) {
        errorMessage = nil
        successMessage = message
    }

    private func validatedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            let error = IdentityManagerViewModelError.invalidName
            present(error)
            throw error
        }
        return name
    }

    private func validatePassword(_ password: String, confirmation: String) throws {
        guard !password.isEmpty else {
            let error = IdentityManagerViewModelError.emptyPassword
            present(error)
            throw error
        }
        guard password == confirmation else {
            let error = IdentityManagerViewModelError.passwordConfirmationMismatch
            present(error)
            throw error
        }
    }

    private func performRead<Value: Sendable>(
        _ operation: @escaping @Sendable (any ZwzIdentityStore) throws -> Value
    ) async throws -> Value {
        guard !isBusy, !isLoading else {
            let error = IdentityManagerViewModelError.operationInProgress
            present(error)
            throw error
        }
        isBusy = true
        errorMessage = nil
        successMessage = nil
        defer { isBusy = false }

        let store = store
        do {
            return try await Task.detached(priority: .userInitiated) {
                try operation(store)
            }.value
        } catch {
            present(error)
            throw error
        }
    }

    private func performMutation<Value: Sendable>(
        conflictKind: IdentityManagerConflictKind? = nil,
        success: String,
        _ operation: @escaping @Sendable (any ZwzIdentityStore) throws -> Value
    ) async throws -> Value {
        guard !isBusy, !isLoading else {
            let error = IdentityManagerViewModelError.operationInProgress
            present(error)
            throw error
        }
        isBusy = true
        errorMessage = nil
        successMessage = nil
        defer { isBusy = false }

        let store = store
        let value: Value
        do {
            value = try await Task.detached(priority: .userInitiated) {
                try operation(store)
            }.value
        } catch {
            if let conflictKind,
               case .identityConflict(let fingerprint) = error as? ZwzV3Error {
                pendingConflict = IdentityManagerConflict(
                    kind: conflictKind,
                    fingerprint: fingerprint
                )
                errorMessage = nil
            } else {
                present(error)
            }
            throw error
        }

        do {
            apply(try await Self.loadSnapshot(from: store))
            errorMessage = nil
        } catch {
            let detail = localizedMessage(for: error)
            errorMessage = SettingsStrings.text(
                "操作已完成，但无法刷新密钥列表：\(detail)",
                "The operation completed, but the key list could not be refreshed: \(detail)"
            )
        }
        successMessage = success
        return value
    }

    private static func loadSnapshot(
        from store: any ZwzIdentityStore
    ) async throws -> IdentityManagerStoreSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try IdentityManagerStoreSnapshot(
                identities: store.identities(),
                contacts: store.contacts()
            )
        }.value
    }

    private func apply(_ snapshot: IdentityManagerStoreSnapshot) {
        identities = snapshot.identities
        contacts = snapshot.contacts
        guard let selection else { return }
        switch selection {
        case .localIdentity(let fingerprint):
            if !identities.contains(where: { $0.fingerprint == fingerprint }) {
                self.selection = nil
            }
        case .contact(let fingerprint):
            if !contacts.contains(where: { $0.fingerprint == fingerprint }) {
                self.selection = nil
            }
        }
    }

    private func upsert(_ identity: ZwzIdentityMetadata) {
        contacts.removeAll { $0.fingerprint == identity.fingerprint }
        if let index = identities.firstIndex(where: {
            $0.fingerprint == identity.fingerprint
        }) {
            identities[index] = identity
        } else {
            identities.append(identity)
        }
        identities.sort { $0.creationDate < $1.creationDate }
    }

    private func upsert(_ identity: ZwzPublicIdentity) {
        if let index = identities.firstIndex(where: {
            $0.fingerprint == identity.fingerprint
        }) {
            let existing = identities[index]
            identities[index] = ZwzIdentityMetadata(
                name: identity.name,
                fingerprint: existing.fingerprint,
                agreementPublicKey: existing.agreementPublicKey,
                signingPublicKey: existing.signingPublicKey,
                creationDate: existing.creationDate
            )
            contacts.removeAll { $0.fingerprint == identity.fingerprint }
            return
        }
        if let index = contacts.firstIndex(where: {
            $0.fingerprint == identity.fingerprint
        }) {
            contacts[index] = identity
        } else {
            contacts.append(identity)
        }
        contacts.sort { $0.name < $1.name }
    }

    private func renameLocalRecord(fingerprint: String, to name: String) {
        if let index = identities.firstIndex(where: { $0.fingerprint == fingerprint }) {
            identities[index].name = name
        }
        if let index = contacts.firstIndex(where: { $0.fingerprint == fingerprint }) {
            contacts[index].name = name
            contacts.sort { $0.name < $1.name }
        }
    }

    private func removeLocalRecord(fingerprint: String) {
        identities.removeAll { $0.fingerprint == fingerprint }
        contacts.removeAll { $0.fingerprint == fingerprint }
    }

    private func present(_ error: Error) {
        successMessage = nil
        errorMessage = localizedMessage(for: error)
    }

    private func localizedMessage(for error: Error) -> String {
        if let fileError = error as? IdentityManagerFileError {
            switch fileError {
            case .invalidFileSize:
                return SettingsStrings.text(
                    "无法验证所选密钥文件的大小。",
                    "The selected key file size could not be verified."
                )
            case .fileTooLarge:
                return SettingsStrings.text(
                    "所选密钥文件超过 16 MiB 大小限制。",
                    "The selected key file exceeds the 16 MiB size limit."
                )
            }
        }
        if let modelError = error as? IdentityManagerViewModelError {
            return message(for: modelError)
        }
        guard let v3Error = error as? ZwzV3Error else {
            return error.localizedDescription
        }
        switch v3Error {
        case .userAuthenticationCancelled:
            return SettingsStrings.text(
                "已取消系统身份验证。",
                "System authentication was cancelled."
            )
        case .keychainFailure(let status):
            return SettingsStrings.text(
                "钥匙串操作失败（状态码 \(status)）。",
                "Keychain operation failed (status \(status))."
            )
        case .invalidBackup:
            return SettingsStrings.text(
                "私钥备份无效或密码不正确。",
                "The private key backup is invalid or the password is incorrect."
            )
        case .invalidKeyFile:
            return SettingsStrings.text(
                "公钥文件无效。",
                "The public key file is invalid."
            )
        case .identityConflict:
            return SettingsStrings.text("检测到身份冲突。", "An identity conflict was detected.")
        case .invalidIdentityName:
            return SettingsStrings.text("身份名称不能为空。", "Identity name cannot be empty.")
        case .noMatchingPrivateKey:
            return SettingsStrings.text("找不到匹配的私钥。", "No matching private key is available.")
        default:
            return v3Error.localizedDescription
        }
    }

    private func message(for error: IdentityManagerViewModelError) -> String {
        switch error {
        case .invalidName:
            SettingsStrings.text("名称不能为空。", "Name cannot be empty.")
        case .emptyPassword:
            SettingsStrings.text("备份密码不能为空。", "Backup password cannot be empty.")
        case .passwordConfirmationMismatch:
            SettingsStrings.text("两次输入的备份密码不一致。", "Backup passwords do not match.")
        case .operationInProgress:
            SettingsStrings.text("另一项密钥操作正在进行。", "Another key operation is in progress.")
        case .noPendingDeletion:
            SettingsStrings.text("没有等待删除的密钥。", "No key is waiting to be deleted.")
        }
    }
}

private struct IdentityManagerStoreSnapshot: Sendable {
    let identities: [ZwzIdentityMetadata]
    let contacts: [ZwzPublicIdentity]
}
