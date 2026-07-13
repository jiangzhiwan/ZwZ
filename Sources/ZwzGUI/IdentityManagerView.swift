import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZwzCore

enum IdentityManagerKeyFileIO {
    static let maximumKeyFileBytes = 16 * 1_024 * 1_024

    static func readData(from url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw IdentityManagerFileError.invalidFileSize
        }
        try validateFileSize(fileSize)
        let data = try Data(contentsOf: url)
        try validateFileSize(data.count)
        return data
    }

    static func validateFileSize(_ fileSize: Int) throws {
        guard let checkedSize = UInt64(exactly: fileSize) else {
            throw IdentityManagerFileError.invalidFileSize
        }
        guard checkedSize <= UInt64(maximumKeyFileBytes) else {
            throw IdentityManagerFileError.fileTooLarge(maximumBytes: maximumKeyFileBytes)
        }
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

private enum IdentityManagerSubmissionKind: Equatable {
    case create
    case rename
    case backup
    case restore
    case publicImport
    case delete
}

private struct IdentityManagerPendingPublicImport {
    let fingerprint: String
    let data: Data
}

@MainActor
struct IdentityManagerView: View {
    @StateObject private var model: IdentityManagerViewModel

    @State private var showCreateSheet = false
    @State private var createName = ""
    @State private var showRenameSheet = false
    @State private var renameName = ""
    @State private var showBackupSheet = false
    @State private var backupPassword = ""
    @State private var backupConfirmation = ""
    @State private var showRestoreSheet = false
    @State private var restorePassword = ""
    @State private var restoreData: Data?
    @State private var pendingPublicImport: IdentityManagerPendingPublicImport?
    @State private var submission: IdentityManagerSubmissionKind?
    @State private var fileOperationID: UUID?

    init(onPrivateRestore: (@MainActor @Sendable () -> Void)? = nil) {
        _model = StateObject(wrappedValue: IdentityManagerViewModel(
            store: ZwzGUIIdentityStore.shared,
            onPrivateRestore: onPrivateRestore
        ))
    }

    init(model: IdentityManagerViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            status
            identityList
            selectedActions
        }
        .task {
            do {
                try await model.refresh()
            } catch {
                // The model publishes a localized error for the page.
            }
        }
        .onDisappear {
            clearSensitiveState()
            pendingPublicImport = nil
            fileOperationID = nil
            model.clearTransientState()
        }
        .sheet(isPresented: $showCreateSheet, onDismiss: { createName = "" }) {
            IdentityManagerNameSheet(
                title: SettingsStrings.text("创建身份", "Create Identity"),
                prompt: SettingsStrings.text("身份名称", "Identity Name"),
                confirmTitle: SettingsStrings.text("创建", "Create"),
                name: $createName,
                isBusy: model.isBusy || submission == .create,
                errorMessage: model.errorMessage,
                onCancel: cancelCreate,
                onConfirm: createIdentity
            )
        }
        .sheet(isPresented: $showRenameSheet, onDismiss: { renameName = "" }) {
            IdentityManagerNameSheet(
                title: SettingsStrings.text("重命名", "Rename"),
                prompt: SettingsStrings.text("新名称", "New Name"),
                confirmTitle: SettingsStrings.text("保存", "Save"),
                name: $renameName,
                isBusy: model.isBusy || submission == .rename,
                errorMessage: model.errorMessage,
                onCancel: cancelRename,
                onConfirm: renameSelection
            )
        }
        .sheet(isPresented: $showBackupSheet, onDismiss: clearBackupState) {
            IdentityManagerBackupSheet(
                password: $backupPassword,
                confirmation: $backupConfirmation,
                isBusy: model.isBusy || submission == .backup,
                errorMessage: model.errorMessage,
                onCancel: cancelBackup,
                onConfirm: exportPrivateBackup
            )
        }
        .sheet(isPresented: $showRestoreSheet, onDismiss: handleRestoreDismiss) {
            IdentityManagerRestoreSheet(
                model: model,
                password: $restorePassword,
                isBusy: model.isBusy || submission == .restore,
                errorMessage: model.errorMessage,
                onCancel: cancelRestore,
                onConfirm: { restorePrivateBackup(conflict: .requireConfirmation) },
                onCancelConflict: cancelRestore,
                onReplaceConflict: { restorePrivateBackup(conflict: .replaceExisting) }
            )
        }
        .alert(
            SettingsStrings.text("公钥已存在", "Public Key Already Exists"),
            isPresented: Binding(
                get: {
                    guard let pendingPublicImport else { return false }
                    return model.pendingConflict?.kind == .publicImport
                        && model.pendingConflict?.fingerprint == pendingPublicImport.fingerprint
                },
                set: { _ in }
            )
        ) {
            Button(SettingsStrings.text("取消", "Cancel"), role: .cancel) {
                cancelPublicImportConflict()
            }
            .disabled(submission == .publicImport)
            Button(SettingsStrings.text("替换", "Replace"), role: .destructive) {
                retryPublicImport()
            }
            .disabled(submission == .publicImport)
        } message: {
            Text(conflictMessage)
        }
    }

    private var isFileOperationPending: Bool { fileOperationID != nil }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SettingsStrings.text("公私钥", "Public & Private Keys"))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(SettingsStrings.text(
                    "私钥由 macOS 钥匙串保护",
                    "Private keys are protected by macOS Keychain"
                ))
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            commandButton(
                icon: "plus",
                label: SettingsStrings.text("创建身份", "Create Identity")
            ) {
                model.clearTransientState()
                createName = ""
                showCreateSheet = true
            }
            commandButton(
                icon: "person.crop.circle.badge.plus",
                label: SettingsStrings.text("导入公钥", "Import Public Key")
            ) {
                model.clearTransientState()
                choosePublicKey()
            }
            commandButton(
                icon: "key.horizontal",
                label: SettingsStrings.text("恢复私钥备份", "Restore Private Backup")
            ) {
                model.clearTransientState()
                choosePrivateBackup()
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if isFileOperationPending && !model.isBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(SettingsStrings.text("正在处理密钥文件…", "Working with key file…"))
            }
            .font(.system(size: 11, design: .rounded))
            .foregroundColor(.secondary)
        } else if model.isBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(SettingsStrings.text("正在处理密钥…", "Working with keys…"))
            }
            .font(.system(size: 11, design: .rounded))
            .foregroundColor(.secondary)
        } else if let errorMessage = model.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let successMessage = model.successMessage {
            Label(successMessage, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.green)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var identityList: some View {
        Group {
            if model.isLoading && model.identities.isEmpty && model.contacts.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(SettingsStrings.text("正在载入密钥…", "Loading keys…"))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.identities.isEmpty && model.contacts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "key.horizontal")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(.secondary)
                    Text(SettingsStrings.text("尚无身份或联系人", "No Identities or Contacts"))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    if !model.identities.isEmpty {
                        Section(SettingsStrings.text("本机身份", "Local Identities")) {
                            ForEach(model.identities, id: \.fingerprint) { identity in
                                IdentityManagerRow(
                                    name: identity.name,
                                    fingerprint: identity.fingerprint,
                                    icon: "person.badge.key.fill"
                                )
                                .tag(IdentityManagerSelection.localIdentity(identity.fingerprint))
                            }
                        }
                    }

                    if !model.contacts.isEmpty {
                        Section(SettingsStrings.text("联系人", "Contacts")) {
                            ForEach(model.contacts, id: \.fingerprint) { contact in
                                IdentityManagerRow(
                                    name: contact.name,
                                    fingerprint: contact.fingerprint,
                                    icon: "person.crop.circle"
                                )
                                .tag(IdentityManagerSelection.contact(contact.fingerprint))
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
        .alert(
            deleteTitle,
            isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { _ in }
            )
        ) {
            Button(SettingsStrings.text("取消", "Cancel"), role: .cancel) {
                cancelDelete()
            }
            .disabled(submission == .delete)
            Button(SettingsStrings.text("删除", "Delete"), role: .destructive) {
                confirmDelete()
            }
            .disabled(submission == .delete)
        } message: {
            Text(deleteMessage)
        }
    }

    private var selectedActions: some View {
        HStack(spacing: 8) {
            actionButton(
                icon: "pencil",
                label: SettingsStrings.text("重命名", "Rename")
            ) {
                model.clearTransientState()
                renameName = model.selectedName ?? ""
                showRenameSheet = true
            }
            actionButton(
                icon: "doc.on.doc",
                label: SettingsStrings.text("复制指纹", "Copy Fingerprint")
            ) {
                copyFingerprint()
            }
            actionButton(
                icon: "square.and.arrow.up",
                label: SettingsStrings.text("导出公钥", "Export Public Key")
            ) {
                exportPublicKey()
            }

            if model.selectedIsLocalIdentity {
                actionButton(
                    icon: "lock.doc",
                    label: SettingsStrings.text("备份私钥", "Back Up Private Key")
                ) {
                    model.clearTransientState()
                    backupPassword = ""
                    backupConfirmation = ""
                    showBackupSheet = true
                }
            }

            Spacer()

            actionButton(
                icon: "trash",
                label: SettingsStrings.text("删除", "Delete"),
                role: .destructive
            ) {
                model.requestDeleteSelection()
            }
        }
        .disabled(
            model.selection == nil || model.isBusy || model.isLoading
                || isFileOperationPending || submission != nil
        )
    }

    private func commandButton(
        icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .contentShape(Rectangle())
        .help(label)
        .accessibilityLabel(label)
        .disabled(
            model.isBusy || model.isLoading || isFileOperationPending || submission != nil
        )
    }

    private func actionButton(
        icon: String,
        label: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.borderless)
        .contentShape(Rectangle())
        .help(label)
        .accessibilityLabel(label)
    }

    private var conflictMessage: String {
        let fingerprint = pendingPublicImport?.fingerprint ?? ""
        return SettingsStrings.text(
            "已存在相同指纹的密钥记录。确认来源可信后才能替换。\n\(groupedFingerprint(fingerprint))",
            "A key record with this fingerprint already exists. Replace it only after confirming the source.\n\(groupedFingerprint(fingerprint))"
        )
    }

    private var deleteTitle: String {
        SettingsStrings.text("确认删除？", "Delete This Key Record?")
    }

    private var deleteMessage: String {
        guard let deletion = model.pendingDeletion else { return "" }
        if deletion.requiresPermanentLossWarning {
            return SettingsStrings.text(
                "删除“\(deletion.name)”会移除本机私钥。如果这是最后一份私钥，使用它加密的压缩包可能永久无法恢复。",
                "Deleting “\(deletion.name)” removes its private keys from this Mac. If this is the last copy, archives encrypted for it may become permanently unrecoverable."
            )
        }
        return SettingsStrings.text(
            "将从联系人中删除“\(deletion.name)”。",
            "“\(deletion.name)” will be removed from contacts."
        )
    }

    private func createIdentity() {
        guard beginSubmission(.create) else { return }
        Task {
            defer { endSubmission(.create) }
            do {
                _ = try await model.createIdentity(named: createName)
                showCreateSheet = false
            } catch {
                // Validation and store errors remain visible in the sheet's parent page.
            }
        }
    }

    private func cancelCreate() {
        guard submission == nil else { return }
        model.clearTransientState()
        showCreateSheet = false
    }

    private func renameSelection() {
        guard let fingerprint = model.selectedFingerprint,
              beginSubmission(.rename) else { return }
        Task {
            defer { endSubmission(.rename) }
            do {
                try await model.rename(fingerprint: fingerprint, to: renameName)
                showRenameSheet = false
            } catch {
                // The model publishes the exact failure.
            }
        }
    }

    private func cancelRename() {
        guard submission == nil else { return }
        model.clearTransientState()
        showRenameSheet = false
    }

    private func cancelBackup() {
        guard submission == nil else { return }
        model.clearTransientState()
        clearBackupState()
        showBackupSheet = false
    }

    private func confirmDelete() {
        guard beginSubmission(.delete) else { return }
        Task {
            defer { endSubmission(.delete) }
            do {
                try await model.confirmDelete()
            } catch {
                // The model keeps the confirmation available and publishes the error.
            }
        }
    }

    private func cancelDelete() {
        guard submission == nil else { return }
        model.cancelDelete()
    }

    private func choosePublicKey() {
        guard !isFileOperationPending else { return }
        let panel = NSOpenPanel()
        panel.title = SettingsStrings.text("导入 ZWZ 公钥", "Import ZWZ Public Key")
        panel.allowedContentTypes = keyTypes(extension: "zwzpub")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let operationID = beginFileOperation()

        Task {
            let data: Data
            do {
                data = try await readData(from: url)
            } catch {
                guard fileOperationID == operationID else { return }
                finishFileOperation(operationID)
                model.reportExternalError(error)
                return
            }
            guard fileOperationID == operationID else { return }

            do {
                _ = try await model.importPublicIdentity(data)
                guard fileOperationID == operationID else { return }
                pendingPublicImport = nil
                finishFileOperation(operationID)
            } catch let error as ZwzV3Error {
                guard fileOperationID == operationID else { return }
                if case .identityConflict(let fingerprint) = error {
                    do {
                        let identity = try ZwzKeyFileCodec.decodePublic(data)
                        guard identity.fingerprint == fingerprint else {
                            throw ZwzV3Error.invalidKeyFile
                        }
                        pendingPublicImport = IdentityManagerPendingPublicImport(
                            fingerprint: fingerprint,
                            data: data
                        )
                    } catch {
                        model.cancelConflict()
                        finishFileOperation(operationID)
                        model.reportExternalError(error)
                    }
                    return
                }
                pendingPublicImport = nil
                finishFileOperation(operationID)
            } catch {
                guard fileOperationID == operationID else { return }
                pendingPublicImport = nil
                finishFileOperation(operationID)
                model.reportExternalError(error)
            }
        }
    }

    private func retryPublicImport() {
        guard let pendingPublicImport,
              model.pendingConflict?.kind == .publicImport,
              model.pendingConflict?.fingerprint == pendingPublicImport.fingerprint,
              isFileOperationPending else {
            cancelPublicImportConflict()
            model.reportExternalError(ZwzV3Error.invalidKeyFile)
            return
        }
        guard beginSubmission(.publicImport) else { return }
        Task {
            defer { endSubmission(.publicImport) }
            do {
                let decoded = try ZwzKeyFileCodec.decodePublic(pendingPublicImport.data)
                guard decoded.fingerprint == pendingPublicImport.fingerprint else {
                    throw ZwzV3Error.invalidKeyFile
                }
                _ = try await model.importPublicIdentity(
                    pendingPublicImport.data,
                    conflict: .replaceExisting
                )
                self.pendingPublicImport = nil
                finishFileOperation()
            } catch {
                if case .identityConflict(let fingerprint) = error as? ZwzV3Error,
                   fingerprint == pendingPublicImport.fingerprint {
                    return
                }
                self.pendingPublicImport = nil
                finishFileOperation()
                model.reportExternalError(error)
            }
        }
    }

    private func cancelPublicImportConflict() {
        guard submission == nil else { return }
        pendingPublicImport = nil
        model.cancelConflict()
        finishFileOperation()
    }

    private func exportPublicKey() {
        guard let fingerprint = model.selectedFingerprint else { return }
        let suggestedName = safeFileName(model.selectedName ?? "identity") + ".zwzpub"
        Task {
            do {
                let data = try await model.exportPublicIdentity(fingerprint: fingerprint)
                guard let url = saveURL(
                    title: SettingsStrings.text("导出 ZWZ 公钥", "Export ZWZ Public Key"),
                    suggestedName: suggestedName,
                    extension: "zwzpub"
                ) else { return }
                try await writeAtomically(data, to: url)
                model.reportSuccess(SettingsStrings.text("公钥已导出。", "Public key exported."))
            } catch {
                model.reportExternalError(error)
            }
        }
    }

    private func exportPrivateBackup() {
        guard let fingerprint = model.selectedFingerprint,
              beginSubmission(.backup) else { return }
        let suggestedName = safeFileName(model.selectedName ?? "identity") + ".zwzkey"
        guard let url = saveURL(
            title: SettingsStrings.text("保存加密私钥备份", "Save Encrypted Private Backup"),
            suggestedName: suggestedName,
            extension: "zwzkey"
        ) else {
            clearBackupState()
            showBackupSheet = false
            endSubmission(.backup)
            return
        }
        Task {
            defer { endSubmission(.backup) }
            do {
                let data = try await model.exportPrivateBackup(
                    fingerprint: fingerprint,
                    password: backupPassword,
                    confirmation: backupConfirmation
                )
                try await writeAtomically(data, to: url)
                clearBackupState()
                showBackupSheet = false
                model.reportSuccess(SettingsStrings.text(
                    "加密私钥备份已保存。",
                    "Encrypted private backup saved."
                ))
            } catch {
                clearBackupState()
                showBackupSheet = false
                model.reportExternalError(error)
            }
        }
    }

    private func choosePrivateBackup() {
        guard !isFileOperationPending else { return }
        let panel = NSOpenPanel()
        panel.title = SettingsStrings.text("恢复 ZWZ 私钥备份", "Restore ZWZ Private Backup")
        panel.allowedContentTypes = keyTypes(extension: "zwzkey")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let operationID = beginFileOperation()

        Task {
            do {
                let data = try await readData(from: url)
                guard fileOperationID == operationID else { return }
                restoreData = data
                restorePassword = ""
                showRestoreSheet = true
            } catch {
                guard fileOperationID == operationID else { return }
                finishFileOperation(operationID)
                model.reportExternalError(error)
            }
        }
    }

    private func restorePrivateBackup(conflict: ZwzIdentityConflictPolicy) {
        guard let restoreData, beginSubmission(.restore) else { return }
        Task {
            defer { endSubmission(.restore) }
            do {
                _ = try await model.restorePrivateBackup(
                    restoreData,
                    password: restorePassword,
                    conflict: conflict
                )
                clearRestoreState()
                showRestoreSheet = false
                finishFileOperation()
            } catch let error as ZwzV3Error {
                if case .identityConflict = error { return }
                clearRestoreState()
                showRestoreSheet = false
                finishFileOperation()
            } catch {
                clearRestoreState()
                showRestoreSheet = false
                finishFileOperation()
            }
        }
    }

    private func cancelRestore() {
        guard submission == nil else { return }
        model.clearTransientState()
        clearRestoreState()
        showRestoreSheet = false
        finishFileOperation()
    }

    private func copyFingerprint() {
        guard let fingerprint = model.selectedFingerprint else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fingerprint, forType: .string)
        model.reportSuccess(SettingsStrings.text("指纹已复制。", "Fingerprint copied."))
    }

    private func beginSubmission(_ kind: IdentityManagerSubmissionKind) -> Bool {
        guard submission == nil else { return false }
        submission = kind
        return true
    }

    private func endSubmission(_ kind: IdentityManagerSubmissionKind) {
        guard submission == kind else { return }
        submission = nil
    }

    private func beginFileOperation() -> UUID {
        let operationID = UUID()
        fileOperationID = operationID
        return operationID
    }

    private func finishFileOperation(_ operationID: UUID? = nil) {
        if let operationID, fileOperationID != operationID { return }
        fileOperationID = nil
    }

    private func handleRestoreDismiss() {
        guard submission != .restore else { return }
        if model.pendingConflict?.kind == .privateRestore {
            model.cancelConflict()
        }
        clearRestoreState()
        finishFileOperation()
    }

    private func clearSensitiveState() {
        clearBackupState()
        clearRestoreState()
    }

    private func clearBackupState() {
        backupPassword = ""
        backupConfirmation = ""
    }

    private func clearRestoreState() {
        restorePassword = ""
        restoreData = nil
    }

    private func keyTypes(extension fileExtension: String) -> [UTType] {
        if let type = UTType(filenameExtension: fileExtension) { return [type] }
        return [.data]
    }

    private func saveURL(
        title: String,
        suggestedName: String,
        extension fileExtension: String
    ) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.allowedContentTypes = keyTypes(extension: fileExtension)
        panel.nameFieldStringValue = suggestedName
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func readData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try IdentityManagerKeyFileIO.readData(from: url)
        }.value
    }

    private func writeAtomically(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try IdentityManagerKeyFileIO.writeAtomically(data, to: url)
        }.value
    }

    private func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let components = name.components(separatedBy: invalid)
        let result = components.joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "identity" : result
    }
}

@MainActor
private struct IdentityManagerRow: View {
    let name: String
    let fingerprint: String
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(.accentColor)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(2)
                Text(groupedFingerprint(fingerprint))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

@MainActor
private struct IdentityManagerNameSheet: View {
    let title: String
    let prompt: String
    let confirmTitle: String
    @Binding var name: String
    let isBusy: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            TextField(prompt, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if isValid && !isBusy { onConfirm() } }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(SettingsStrings.text("取消", "Cancel"), role: .cancel, action: onCancel)
                    .disabled(isBusy)
                Button(confirmTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isBusy)
            }
        }
        .padding(22)
        .frame(width: 360)
        .interactiveDismissDisabled(isBusy)
    }
}

@MainActor
private struct IdentityManagerBackupSheet: View {
    @Binding var password: String
    @Binding var confirmation: String
    let isBusy: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var isValid: Bool { !password.isEmpty && password == confirmation }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(SettingsStrings.text("加密私钥备份", "Encrypted Private Backup"))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(SettingsStrings.text(
                "备份密码无法找回。请将备份和密码分别保管。",
                "This password cannot be recovered. Store the backup and password separately."
            ))
            .font(.system(size: 11, design: .rounded))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            SecureField(SettingsStrings.text("备份密码", "Backup Password"), text: $password)
                .textFieldStyle(.roundedBorder)
            SecureField(SettingsStrings.text("确认密码", "Confirm Password"), text: $confirmation)
                .textFieldStyle(.roundedBorder)
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(SettingsStrings.text("取消", "Cancel"), role: .cancel, action: onCancel)
                    .disabled(isBusy)
                Button(SettingsStrings.text("继续", "Continue"), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isBusy)
            }
        }
        .padding(22)
        .frame(width: 390)
        .interactiveDismissDisabled(isBusy)
    }
}

@MainActor
private struct IdentityManagerRestoreSheet: View {
    @ObservedObject var model: IdentityManagerViewModel
    @Binding var password: String
    let isBusy: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onCancelConflict: () -> Void
    let onReplaceConflict: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(SettingsStrings.text("恢复私钥备份", "Restore Private Backup"))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            SecureField(SettingsStrings.text("备份密码", "Backup Password"), text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !password.isEmpty && !isBusy { onConfirm() } }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(SettingsStrings.text("取消", "Cancel"), role: .cancel, action: onCancel)
                    .disabled(isBusy)
                Button(SettingsStrings.text("恢复", "Restore"), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || isBusy)
            }
        }
        .padding(22)
        .frame(width: 390)
        .interactiveDismissDisabled(isBusy || model.pendingConflict?.kind == .privateRestore)
        .alert(
            SettingsStrings.text("身份已存在", "Identity Already Exists"),
            isPresented: Binding(
                get: { model.pendingConflict?.kind == .privateRestore },
                set: { _ in }
            )
        ) {
            Button(SettingsStrings.text("取消", "Cancel"), role: .cancel, action: onCancelConflict)
                .disabled(isBusy)
            Button(SettingsStrings.text("替换", "Replace"), role: .destructive, action: onReplaceConflict)
                .disabled(isBusy)
        } message: {
            let fingerprint = model.pendingConflict?.fingerprint ?? ""
            Text(SettingsStrings.text(
                "将替换相同指纹的身份记录。\n\(groupedFingerprint(fingerprint))",
                "The identity record with this fingerprint will be replaced.\n\(groupedFingerprint(fingerprint))"
            ))
        }
    }
}

private func groupedFingerprint(_ fingerprint: String) -> String {
    var groups: [String] = []
    var start = fingerprint.startIndex
    while start < fingerprint.endIndex {
        let end = fingerprint.index(start, offsetBy: 4, limitedBy: fingerprint.endIndex)
            ?? fingerprint.endIndex
        groups.append(String(fingerprint[start..<end]))
        start = end
    }
    return groups.joined(separator: " ")
}
