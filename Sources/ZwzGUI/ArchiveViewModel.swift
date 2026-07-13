import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import ZwzCore

// MARK: - Status

struct ZWZStatus {
    let text: String
    let color: Color

    static let idle = ZWZStatus(text: "就绪", color: .gray)
    static let compressing = ZWZStatus(text: "正在压缩…", color: .blue)
    static let extracting = ZWZStatus(text: "正在解压…", color: .green)
    static let reading = ZWZStatus(text: "正在读取…", color: .blue)
    static let done = ZWZStatus(text: "完成", color: .green)
    static let error = ZWZStatus(text: "错误", color: .red)
}

// MARK: - History Item

struct ZWZHistoryItem: Identifiable {
    let id = UUID()
    let type: HistoryType
    let fileName: String
    let statusText: String
    let isSuccess: Bool

    enum HistoryType {
        case compress
        case extract
    }
}

// MARK: - Thread Mode

enum ThreadMode: String, CaseIterable {
    case auto
    case manual

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .manual: return "手动"
        }
    }
}

enum EncryptionModeSelection: String, CaseIterable, Sendable {
    case none
    case password
    case publicKey
}

private enum ArchiveViewModelSecurityError: LocalizedError {
    case invalidCompressionConfiguration
    case invalidArchiveSignature

    var errorDescription: String? {
        switch self {
        case .invalidCompressionConfiguration:
            return "The selected archive encryption settings are incomplete."
        case .invalidArchiveSignature:
            return "The archive signature is invalid. Content cannot be opened."
        }
    }
}

// MARK: - View Model

@MainActor
class ArchiveViewModel: ObservableObject {
    // 状态
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var processingTitle = ""
    @Published var errorMessage: String?
    @Published var currentStatus: ZWZStatus? = .idle
    @Published private(set) var operationGeneration: UUID?
    @Published private(set) var isCancelling = false
    private var cancellationToken: CancellationToken?

    // 压缩选项
    @Published var showCompressOptions = false
    @Published var compressFormat: CompressionFormat = .zip {
        didSet {
            if compressFormat == .zip, encryptionModeSelection == .publicKey {
                selectEncryptionMode(.none)
            }
        }
    }
    @Published var compressLevel: CompressionLevel = .normal
    @Published var password = ""
    @Published var splitSize = ""
    @Published var splitUnit = "MB"
    @Published var encryptionModeSelection: EncryptionModeSelection = .none
    @Published var selectedRecipientFingerprints: Set<String> = []
    @Published var selectedSignerFingerprint: String?
    @Published private(set) var availableRecipients: [ZwzPublicIdentity] = []
    @Published private(set) var availableSigningIdentities: [ZwzIdentityMetadata] = []

    // 多线程设置（全局，从 UserDefaults 读取）
    @Published var threadMode: ThreadMode = .auto
    @Published var manualThreadCount: Int = 4

    // 解压选项
    @Published var showExtractOptions = false
    @Published var detectedFormat: ExtractionFormat?
    @Published var showPreviewPasswordPrompt = false
    @Published var previewPasswordError: String?
    @Published var rememberPreviewPassword = false
    @Published var showVaultSetupPrompt = false
    @Published var showVaultUnlockPrompt = false
    @Published var vaultPromptError: String?
    @Published var showArchiveEditor = false
    @Published var editEntries: [ArchiveEntry] = []
    @Published var isSavingEdits = false
    @Published var editErrorMessage: String?
    @Published private(set) var hasUnsavedArchiveEdits = false
    @Published private(set) var archiveSecurityInfo: ZwzArchiveSecurityInfo?
    @Published var showMissingPrivateKeyPrompt = false
    @Published private(set) var missingPrivateKeyRecipients: [ZwzRecipientInfo] = []

    // 压缩包内容（内联显示）
    @Published var previewEntries: [ArchiveEntry] = []
    @Published var archiveName: String = ""
    @Published var selectedEntryId: UUID?
    @Published var currentDir: String = ""
    @Published var searchQuery: String = "" {
        didSet {
            selectedEntryId = nil
            updateFilteredEntries()
        }
    }
    @Published var showHiddenFiles: Bool = UserDefaults.standard.bool(forKey: "zwz_preview_show_hidden") {
        didSet {
            UserDefaults.standard.set(showHiddenFiles, forKey: "zwz_preview_show_hidden")
            updateFilteredEntries()
        }
    }

    // 全量条目（不过滤）
    private var allEntries: [ArchiveEntry] = []

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSubmitPreviewPassword: Bool {
        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // 文件选择
    @Published var showFilePicker = false
    @Published var showSavePanel = false
    @Published var sourcePath: String? {
        didSet {
            if sourcePath != oldValue {
                invalidateOperation()
                editClient.discard()
                clearPendingPrivateKeyRecovery()
                archiveSecurityInfo = nil
                inspectedRecipients = []
            }
        }
    }

    // 旋转动画
    @Published var rotationAngle: Double = 0

    // 历史
    @Published var history: [ZWZHistoryItem] = []

    // 待操作类型
    private var pendingAction: PendingAction = .none
    private var passwordWasAutoFilled = false
    private var inspectedRecipients: [ZwzRecipientInfo] = []

    let identityStore: any ZwzIdentityStore
    private let archiveClient: any ArchiveWorkflowClient
    private let editClient: any ArchiveEditWorkflowClient
    private let mountClient: any ArchiveMountWorkflowClient

    var isEditableArchive: Bool {
        detectedFormat == .zip || detectedFormat == .zwz
    }

    private enum PendingAction {
        case none
        case compress
        case extract
    }

    private enum PendingPrivateKeyOperation {
        case compress
        case preview(path: String, isPasswordRetry: Bool)
        case extract
        case smartExtract
        case entry(ArchiveEntry, openAfterExtraction: Bool)
        case edit
        case mount(capacityMB: Int)
        case customResume(@MainActor @Sendable () -> Void)
    }

    private var pendingPrivateKeyOperation: PendingPrivateKeyOperation?

    init(
        identityStore: any ZwzIdentityStore = ZwzGUIIdentityStore.shared,
        archiveClient: any ArchiveWorkflowClient = ZwzAPIArchiveWorkflowClient(),
        editClient: any ArchiveEditWorkflowClient = DefaultArchiveEditWorkflowClient(),
        mountClient: any ArchiveMountWorkflowClient = DefaultArchiveMountWorkflowClient()
    ) {
        self.identityStore = identityStore
        self.archiveClient = archiveClient
        self.editClient = editClient
        self.mountClient = mountClient
    }

    var canStartCompression: Bool {
        guard sourcePath != nil else { return false }
        switch encryptionModeSelection {
        case .none:
            return true
        case .password:
            return !password.isEmpty
        case .publicKey:
            guard compressFormat == .zwz, !selectedRecipientFingerprints.isEmpty else {
                return false
            }
            let knownRecipients = Set(availableRecipients.map(\.fingerprint))
            guard selectedRecipientFingerprints.isSubset(of: knownRecipients) else { return false }
            if let selectedSignerFingerprint {
                return availableSigningIdentities.contains {
                    $0.fingerprint == selectedSignerFingerprint
                }
            }
            return true
        }
    }

    var signatureBadge: ZwzSignatureVerification? {
        archiveSecurityInfo?.signature
    }

    var canOpenArchiveContent: Bool {
        archiveSecurityInfo?.signature != .invalid
    }

    @discardableResult
    func beginOperation() -> UUID {
        let generation = UUID()
        operationGeneration = generation
        cancellationToken = CancellationToken()
        isCancelling = false
        return generation
    }

    func cancelOperation() {
        clearPendingPrivateKeyRecovery()
        guard isProcessing else { return }
        isCancelling = true
        cancellationToken?.cancel()
    }

    func acceptsCallback(generation: UUID) -> Bool {
        operationGeneration == generation
    }

    func invalidateOperation() {
        operationGeneration = nil
    }

    func selectEncryptionMode(_ mode: EncryptionModeSelection) {
        encryptionModeSelection = mode
        if mode != .publicKey {
            selectedRecipientFingerprints.removeAll()
            selectedSignerFingerprint = nil
        }
        if mode != .password {
            password = ""
        }
    }

    func refreshIdentityChoices() async throws {
        let store = identityStore
        let values = try await Task.detached(priority: .userInitiated) {
            (try store.identities(), try store.contacts())
        }.value

        let identities = values.0.sorted(by: Self.identitySort)
        var recipientsByFingerprint: [String: ZwzPublicIdentity] = [:]
        for contact in values.1 {
            recipientsByFingerprint[contact.fingerprint] = contact
        }
        for identity in identities {
            recipientsByFingerprint[identity.fingerprint] = identity.publicIdentity
        }
        availableSigningIdentities = identities
        availableRecipients = recipientsByFingerprint.values.sorted(by: Self.publicIdentitySort)

        let recipientFingerprints = Set(availableRecipients.map(\.fingerprint))
        selectedRecipientFingerprints.formIntersection(recipientFingerprints)
        if let selectedSignerFingerprint,
           !identities.contains(where: { $0.fingerprint == selectedSignerFingerprint }) {
            self.selectedSignerFingerprint = nil
        }
    }

    // MARK: - Actions

    func startCompress() {
        pendingAction = .compress
        password = ""
        rememberPreviewPassword = false
        splitSize = ""
        compressLevel = .normal
        Task { try? await refreshIdentityChoices() }
        // 从 UserDefaults 读取多线程设置
        let modeRaw = UserDefaults.standard.string(forKey: "zwz_thread_mode") ?? "auto"
        threadMode = ThreadMode(rawValue: modeRaw) ?? .auto
        manualThreadCount = UserDefaults.standard.integer(forKey: "zwz_thread_count")
        if manualThreadCount == 0 { manualThreadCount = 4 }
        showFilePicker = true
    }

    func startExtract() {
        pendingAction = .extract
        password = ""
        sourcePath = nil
        previewEntries = []  // 清空之前的预览
        showFilePicker = true
    }

    func handleFilePick(url: URL) {
        let path = url.path
        sourcePath = path

        switch pendingAction {
        case .compress:
            showCompressOptions = true
        case .extract:
            // 先检测格式，然后自动预览内容
            do {
                password = ""
                rememberPreviewPassword = false
                previewPasswordError = nil
                detectedFormat = try archiveClient.detectFormat(archivePath: path)
                archiveName = url.lastPathComponent
                performPreview(path: path)
            } catch {
                errorMessage = localizedMessage(for: error, context: .preview)
            }
        case .none:
            // 直接打开文件，自动判断
            handleAutoOpen(path: path, url: url)
        }
    }

    func handleSaveLocation(url: URL) {
        sourcePath = url.path
        performCompress()
    }

    func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                DispatchQueue.main.async {
                    self.handleAutoOpen(path: url.path, url: url)
                }
            }
        }
    }

    /// 自动判断：是压缩包就预览内容，是普通文件/文件夹就压缩
    func handleAutoOpen(path: String, url: URL) {
        let ext = url.pathExtension.lowercased()
        let isArchive = ["zip", "zwz", "rar", "7z", "gz", "tgz"].contains(ext) || path.hasSuffix(".tar.gz")

        if isArchive {
            sourcePath = path
            do {
                password = ""
                rememberPreviewPassword = false
                previewPasswordError = nil
                detectedFormat = try archiveClient.detectFormat(archivePath: path)
                archiveName = url.lastPathComponent
                performPreview(path: path)
            } catch {
                errorMessage = localizedMessage(for: error, context: .preview)
            }
        } else {
            sourcePath = path
            showCompressOptions = true
        }
    }

    /// 清空预览内容，回到拖拽初始界面
    func clearPreview() {
        invalidateOperation()
        clearPendingPrivateKeyRecovery()
        showPreviewPasswordPrompt = false
        previewPasswordError = nil
        password = ""
        rememberPreviewPassword = false
        searchQuery = ""
        previewEntries = []
        allEntries = []
        archiveName = ""
        currentDir = ""
        selectedEntryId = nil
        sourcePath = nil
        detectedFormat = nil
        archiveSecurityInfo = nil
        inspectedRecipients = []
        errorMessage = nil
        currentStatus = .idle
        discardArchiveEdits()
    }

    // MARK: - Archive Editing

    func beginArchiveEditing(allowsPrivateKeyRecovery: Bool = true) {
        guard enforceValidSignature() else { return }
        guard let sourcePath, isEditableArchive else { return }
        isProcessing = true
        processingTitle = "正在准备编辑…"
        currentStatus = .reading
        let password = password.isEmpty ? nil : password
        let securityInfo = archiveSecurityInfo
        let editClient = editClient
        let identityStore = identityStore
        let generation = beginOperation()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entries = try editClient.open(
                    archivePath: sourcePath,
                    password: password,
                    securityInfo: securityInfo,
                    identityStore: identityStore
                )
                DispatchQueue.main.async {
                    guard self.acceptsCallback(generation: generation), self.sourcePath == sourcePath else {
                        editClient.discard()
                        return
                    }
                    self.editEntries = entries
                    self.hasUnsavedArchiveEdits = editClient.hasChanges
                    self.isProcessing = false
                    self.currentStatus = .idle
                    self.editErrorMessage = nil
                    self.showArchiveEditor = true
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.acceptsCallback(generation: generation), self.sourcePath == sourcePath else {
                        return
                    }
                    self.isProcessing = false
                    if self.handleProtectedOperationFailure(
                        error,
                        operation: .edit,
                        allowsRecovery: allowsPrivateKeyRecovery,
                        context: .preview
                    ) {
                        return
                    }
                }
            }
        }
    }

    func refreshEditEntries() {
        do { editEntries = try editClient.entries() }
        catch { editErrorMessage = error.localizedDescription }
    }

    func addToArchive(urls: [URL], directory: String) {
        do {
            try editClient.add(urls: urls, into: directory)
            refreshEditEntries()
        } catch { editErrorMessage = error.localizedDescription }
        hasUnsavedArchiveEdits = editClient.hasChanges
    }

    func deleteFromArchive(path: String) {
        do {
            try editClient.delete(path: path)
            refreshEditEntries()
        } catch { editErrorMessage = error.localizedDescription }
        hasUnsavedArchiveEdits = editClient.hasChanges
    }

    func renameInArchive(path: String, to name: String) {
        do {
            try editClient.rename(path: path, to: name)
            refreshEditEntries()
        } catch { editErrorMessage = error.localizedDescription }
        hasUnsavedArchiveEdits = editClient.hasChanges
    }

    func replaceInArchive(path: String, with url: URL) {
        do {
            try editClient.replace(path: path, with: url)
            refreshEditEntries()
        } catch { editErrorMessage = error.localizedDescription }
        hasUnsavedArchiveEdits = editClient.hasChanges
    }

    func textForArchiveEntry(path: String) throws -> String {
        try editClient.text(for: path)
    }

    @discardableResult
    func saveTextInArchive(_ text: String, path: String) -> Bool {
        do {
            try editClient.writeText(text, to: path)
            refreshEditEntries()
            hasUnsavedArchiveEdits = editClient.hasChanges
            return true
        } catch {
            editErrorMessage = error.localizedDescription
            hasUnsavedArchiveEdits = editClient.hasChanges
            return false
        }
    }

    func saveArchiveEdits(onSuccess: (@MainActor @Sendable () -> Void)? = nil) {
        guard let archivePath = editClient.archivePath ?? sourcePath else {
            onSuccess?()
            return
        }
        isSavingEdits = true
        editErrorMessage = nil
        let editClient = editClient
        let identityStore = identityStore
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try editClient.save(identityStore: identityStore)
                DispatchQueue.main.async {
                    self.isSavingEdits = false
                    editClient.discard()
                    self.hasUnsavedArchiveEdits = false
                    self.showArchiveEditor = false
                    self.performPreview(path: archivePath)
                    onSuccess?()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSavingEdits = false
                    self.editErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func discardArchiveEdits() {
        editClient.discard()
        editEntries = []
        editErrorMessage = nil
        hasUnsavedArchiveEdits = false
        showArchiveEditor = false
    }

    // MARK: - Compress

    func performCompress(allowsPrivateKeyRecovery: Bool = true) {
        guard let srcPath = sourcePath else {
            errorMessage = "No source file selected"
            return
        }

        let options: CompressionOptions
        do {
            options = try compressionOptions()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let ext = compressFormat.fileExtension
        let destPath = srcPath.hasSuffix(".\(ext)") ? srcPath : srcPath + ".\(ext)"

        isProcessing = true
        progress = 0
        processingTitle = "正在压缩…"
        currentStatus = .compressing
        let generation = beginOperation()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try self.archiveClient.compress(
                    sourcePath: srcPath,
                    destinationPath: destPath,
                    options: options,
                    identityStore: self.identityStore,
                    progress: { prog in
                        DispatchQueue.main.async {
                            guard self.acceptsCallback(generation: generation) else { return }
                            self.progress = prog
                        }
                    },
                    cancellationToken: self.cancellationToken
                )

                DispatchQueue.main.async {
                    guard self.acceptsCallback(generation: generation) else { return }
                    self.isProcessing = false
                    self.progress = 1
                    self.currentStatus = .done
                    self.history.append(ZWZHistoryItem(
                        type: .compress,
                        fileName: (srcPath as NSString).lastPathComponent,
                        statusText: "成功",
                        isSuccess: true
                    ))
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.acceptsCallback(generation: generation) else { return }
                    self.isProcessing = false
                    if self.handleProtectedOperationFailure(
                        error,
                        operation: .compress,
                        allowsRecovery: allowsPrivateKeyRecovery,
                        context: .general
                    ) {
                        return
                    }
                    self.history.append(ZWZHistoryItem(
                        type: .compress,
                        fileName: (srcPath as NSString).lastPathComponent,
                        statusText: "失败",
                        isSuccess: false
                    ))
                }
            }
        }
    }

    // MARK: - Extract

    func performSmartExtract(allowsPrivateKeyRecovery: Bool = true) {
        guard enforceValidSignature() else { return }
        guard let srcPath = sourcePath else {
            errorMessage = "No archive selected"
            return
        }

        let archiveURL = URL(fileURLWithPath: srcPath)
        let plan = SmartExtractionPlanner.makePlan(archiveURL: archiveURL, entries: allEntries)
        let extractionDirectoryExisted = FileManager.default.fileExists(
            atPath: plan.extractionDirectory.path
        )
        let pwd = password.isEmpty ? nil : password

        isProcessing = true
        progress = 0
        processingTitle = L.string("smart_extracting")
        currentStatus = .extracting
        let generation = beginOperation()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(
                    at: plan.extractionDirectory,
                    withIntermediateDirectories: true
                )
                let result = try self.archiveClient.extract(
                    archivePath: srcPath,
                    destinationPath: plan.extractionDirectory.path,
                    password: pwd,
                    identityStore: self.identityStore,
                    progress: { prog in
                        DispatchQueue.main.async {
                            guard self.acceptsCallback(generation: generation) else { return }
                            self.progress = prog
                        }
                    },
                    cancellationToken: self.cancellationToken
                )
                try SmartExtractionPlanner.finalize(plan)

                DispatchQueue.main.async {
                    guard self.acceptsCallback(generation: generation) else { return }
                    self.isProcessing = false
                    self.progress = 1
                    self.currentStatus = .done
                    if let securityInfo = result.securityInfo {
                        self.archiveSecurityInfo = securityInfo
                    }
                    self.history.append(ZWZHistoryItem(
                        type: .extract,
                        fileName: archiveURL.lastPathComponent,
                        statusText: "成功",
                        isSuccess: true
                    ))
                    NSWorkspace.shared.open(plan.resultDirectory)
                    self.clearPreview()
                    self.currentStatus = .done
                }
            } catch {
                if plan.extractedTopLevelName != nil || !extractionDirectoryExisted {
                    try? FileManager.default.removeItem(at: plan.extractionDirectory)
                }
                DispatchQueue.main.async {
                    guard self.acceptsCallback(generation: generation) else { return }
                    self.isProcessing = false
                    if self.handleProtectedOperationFailure(
                        error,
                        operation: .smartExtract,
                        allowsRecovery: allowsPrivateKeyRecovery,
                        context: .extract
                    ) {
                        return
                    }
                    self.history.append(ZWZHistoryItem(
                        type: .extract,
                        fileName: archiveURL.lastPathComponent,
                        statusText: "失败",
                        isSuccess: false
                    ))
                }
            }
        }
    }

    func performExtract(allowsPrivateKeyRecovery: Bool = true) {
        guard enforceValidSignature() else { return }
        guard let srcPath = sourcePath else {
            errorMessage = "No archive selected"
            return
        }

        let destPath = (srcPath as NSString).deletingPathExtension
        let pwd = password.isEmpty ? nil : password

        isProcessing = true
        progress = 0
        processingTitle = "正在解压…"
        currentStatus = .extracting
        let generation = beginOperation()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try self.archiveClient.extract(
                    archivePath: srcPath,
                    destinationPath: destPath,
                    password: pwd,
                    identityStore: self.identityStore,
                    progress: { prog in
                    DispatchQueue.main.async {
                        guard self.acceptsCallback(generation: generation) else { return }
                        self.progress = prog
                    }
                }, cancellationToken: self.cancellationToken)

                DispatchQueue.main.async {
                    guard self.acceptsCallback(generation: generation) else { return }
                    self.isProcessing = false
                    self.progress = 1
                    self.currentStatus = .done
                    if let securityInfo = result.securityInfo {
                        self.archiveSecurityInfo = securityInfo
                    }
                    self.history.append(ZWZHistoryItem(
                        type: .extract,
                        fileName: (srcPath as NSString).lastPathComponent,
                        statusText: "成功",
                        isSuccess: true
                    ))
                    // 解压完成后清空预览
                    self.previewEntries = []
                    self.archiveName = ""
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.acceptsCallback(generation: generation) else { return }
                    self.isProcessing = false
                    if self.handleProtectedOperationFailure(
                        error,
                        operation: .extract,
                        allowsRecovery: allowsPrivateKeyRecovery,
                        context: .extract
                    ) {
                        return
                    }
                    self.history.append(ZWZHistoryItem(
                        type: .extract,
                        fileName: (srcPath as NSString).lastPathComponent,
                        statusText: "失败",
                        isSuccess: false
                    ))
                }
            }
        }
    }

    func mountArchive(
        capacityMB: Int,
        allowsPrivateKeyRecovery: Bool = true
    ) async {
        guard enforceValidSignature() else { return }
        guard let sourcePath else {
            errorMessage = "No archive selected"
            return
        }
        do {
            try await mountClient.mount(
                archivePath: sourcePath,
                password: password.isEmpty ? nil : password,
                capacityMB: capacityMB,
                securityInfo: archiveSecurityInfo,
                identityStore: identityStore
            )
        } catch {
            _ = handleProtectedOperationFailure(
                error,
                operation: .mount(capacityMB: capacityMB),
                allowsRecovery: allowsPrivateKeyRecovery,
                context: .extract
            )
        }
    }

    func saveMountedArchive() async {
        guard enforceValidSignature() else { return }
        let identityStore = identityStore
        do {
            try await mountClient.save(identityStore: identityStore)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Preview (inline, not a sheet)

    func performPreview(
        path: String,
        isPasswordRetry: Bool = false,
        allowsPrivateKeyRecovery: Bool = true
    ) {
        guard enforceValidSignature() else { return }
        searchQuery = ""
        showHiddenFiles = UserDefaults.standard.bool(forKey: "zwz_preview_show_hidden")
        previewPasswordError = nil
        isProcessing = true
        processingTitle = "正在读取…"
        currentStatus = .reading
        let previewPassword = password.isEmpty ? nil : password
        let generation = beginOperation()
        let shouldInspect = detectedFormat == .zwz || Self.looksLikeZwzPath(path)

        DispatchQueue.global(qos: .userInitiated).async {
            var inspection: ZwzV3ArchiveInspection?
            do {
                if shouldInspect {
                    inspection = try? self.archiveClient.inspect(
                        archivePath: path,
                        identityStore: self.identityStore
                    )
                }
                if inspection?.securityInfo.signature == .invalid {
                    DispatchQueue.main.async {
                        guard self.acceptsCallback(generation: generation) else { return }
                        self.applyInspection(inspection)
                        self.publishInvalidSignature()
                    }
                    return
                }

                let listing = try self.archiveClient.list(
                    archivePath: path,
                    password: previewPassword,
                    identityStore: self.identityStore
                )
                DispatchQueue.main.async {
                    guard self.acceptsCallback(generation: generation) else { return }
                    self.handlePreviewSuccess(
                        listing.entries,
                        securityInfo: listing.securityInfo ?? inspection?.securityInfo,
                        recipients: inspection?.recipients ?? []
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.acceptsCallback(generation: generation) else { return }
                    self.applyInspection(inspection)
                    if self.handleProtectedOperationFailure(
                        error,
                        operation: .preview(path: path, isPasswordRetry: isPasswordRetry),
                        allowsRecovery: allowsPrivateKeyRecovery,
                        context: .preview
                    ) {
                        return
                    }
                    self.handlePreviewFailure(error, isPasswordRetry: isPasswordRetry)
                }
            }
        }
    }

    func retryPreviewWithPassword() {
        guard let path = sourcePath,
              canSubmitPreviewPassword else { return }
        if rememberPreviewPassword,
           !ensureLocalVaultIsReadyToSave() {
            return
        }
        previewPasswordError = nil
        showPreviewPasswordPrompt = false
        passwordWasAutoFilled = false
        performPreview(path: path, isPasswordRetry: true)
    }

    func configurePasswordVault(masterPassword: String, confirmation: String) {
        guard masterPassword == confirmation else {
            vaultPromptError = "两次输入的主密码不一致。"
            return
        }
        do {
            try ArchivePasswordVault.shared.configure(masterPassword: masterPassword)
            vaultPromptError = nil
            showVaultSetupPrompt = false
            retryPreviewWithPassword()
        } catch {
            vaultPromptError = error.localizedDescription
        }
    }

    func unlockPasswordVault(masterPassword: String) {
        do {
            try ArchivePasswordVault.shared.unlock(masterPassword: masterPassword)
            vaultPromptError = nil
            showVaultUnlockPrompt = false
            if rememberPreviewPassword { retryPreviewWithPassword() }
            else { attemptSavedPasswordOrPrompt() }
        } catch {
            vaultPromptError = "主密码不正确。"
        }
    }

    func cancelPreviewPasswordPrompt() {
        clearPreview()
    }

    func handlePreviewSuccess(_ entries: [ArchiveEntry]) {
        handlePreviewSuccess(entries, securityInfo: nil, recipients: [])
    }

    private func handlePreviewSuccess(
        _ entries: [ArchiveEntry],
        securityInfo: ZwzArchiveSecurityInfo?,
        recipients: [ZwzRecipientInfo]
    ) {
        currentDir = ""
        setArchiveEntries(entries)
        archiveSecurityInfo = securityInfo
        inspectedRecipients = recipients
        isProcessing = false
        currentStatus = .idle
        errorMessage = nil
        previewPasswordError = nil
        showPreviewPasswordPrompt = false
        if rememberPreviewPassword, !password.isEmpty {
            saveCurrentPassword()
        }
    }

    func handlePreviewFailure(_ error: Error, isPasswordRetry: Bool) {
        isProcessing = false
        if isPasswordPreviewError(error) {
            currentStatus = .idle
            errorMessage = nil
            if passwordWasAutoFilled {
                removeSavedPassword()
                passwordWasAutoFilled = false
                password = ""
                rememberPreviewPassword = false
                showPreviewPasswordPrompt = true
                previewPasswordError = L.string("archive_password_or_tampered")
            } else if isPasswordRetry {
                showPreviewPasswordPrompt = true
                password = ""
                previewPasswordError = L.string("archive_password_or_tampered")
            } else {
                attemptSavedPasswordOrPrompt()
            }
        } else {
            currentStatus = .error
            showPreviewPasswordPrompt = false
            previewPasswordError = nil
            errorMessage = localizedMessage(for: error, context: .preview)
        }
    }

    private func ensureLocalVaultIsReadyToSave() -> Bool {
        let vault = ArchivePasswordVault.shared
        guard vault.activeStorage == .local else { return true }
        if !vault.isConfigured {
            vaultPromptError = nil
            showVaultSetupPrompt = true
            return false
        }
        if !vault.isUnlocked {
            vaultPromptError = nil
            showVaultUnlockPrompt = true
            return false
        }
        return true
    }

    private func attemptSavedPasswordOrPrompt() {
        guard UserDefaults.standard.bool(forKey: ArchivePasswordVault.rememberEnabledKey),
              let path = sourcePath else {
            password = ""
            rememberPreviewPassword = false
            showPreviewPasswordPrompt = true
            previewPasswordError = nil
            return
        }
        let vault = ArchivePasswordVault.shared
        if vault.activeStorage == .local && !vault.isUnlocked {
            if vault.isConfigured {
                vaultPromptError = nil
                showVaultUnlockPrompt = true
                return
            }
            password = ""
            rememberPreviewPassword = false
            showPreviewPasswordPrompt = true
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let fingerprint = try? ArchiveFingerprint.make(for: URL(fileURLWithPath: path))
            DispatchQueue.main.async {
                guard self.sourcePath == path, let fingerprint else { return }
                if let saved = try? vault.password(for: fingerprint, storage: vault.activeStorage) {
                    self.password = saved
                    self.passwordWasAutoFilled = true
                    self.performPreview(path: path, isPasswordRetry: true)
                } else {
                    self.password = ""
                    self.rememberPreviewPassword = false
                    self.showPreviewPasswordPrompt = true
                    self.previewPasswordError = nil
                }
            }
        }
    }

    private func saveCurrentPassword() {
        guard let path = sourcePath else { return }
        let password = password
        let archiveName = archiveName
        let storage = ArchivePasswordVault.shared.activeStorage
        DispatchQueue.global(qos: .utility).async {
            let fingerprint = try? ArchiveFingerprint.make(for: URL(fileURLWithPath: path))
            DispatchQueue.main.async {
                guard self.sourcePath == path, let fingerprint else { return }
                try? ArchivePasswordVault.shared.save(
                    password: password,
                    fingerprint: fingerprint,
                    archiveName: archiveName,
                    storage: storage
                )
            }
        }
    }

    private func removeSavedPassword() {
        guard let path = sourcePath else { return }
        let storage = ArchivePasswordVault.shared.activeStorage
        DispatchQueue.global(qos: .utility).async {
            let fingerprint = try? ArchiveFingerprint.make(for: URL(fileURLWithPath: path))
            DispatchQueue.main.async {
                guard let fingerprint else { return }
                try? ArchivePasswordVault.shared.remove(fingerprint: fingerprint, storage: storage)
            }
        }
    }

    private func isPasswordPreviewError(_ error: Error) -> Bool {
        if let v2Error = error as? ZwzV2Error,
           case .wrongPasswordOrTamperedData = v2Error {
            return true
        }
        if let zwzError = error as? ZwzError {
            switch zwzError {
            case .passwordRequired, .wrongPassword:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// 根据 currentDir 过滤显示当前目录下的条目
    func updateFilteredEntries() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            previewEntries = allEntries.filter { entry in
                let path = entry.path.hasPrefix("./") ? String(entry.path.dropFirst(2)) : entry.path
                guard showHiddenFiles || !ArchiveEntryPresentation.isHidden(path: path) else { return false }
                return entry.name.range(of: query, options: .caseInsensitive) != nil
                    || path.range(of: query, options: .caseInsensitive) != nil
            }
            return
        }

        previewEntries = ArchiveEntryHierarchy.immediateChildren(
            of: allEntries,
            in: currentDir,
            showHiddenFiles: showHiddenFiles
        )
    }

    func setArchiveEntries(_ entries: [ArchiveEntry]) {
        allEntries = entries
        updateFilteredEntries()
    }

    /// 进入子目录
    func enterDirectory(_ entry: ArchiveEntry) {
        searchQuery = ""
        currentDir = ArchiveEntryHierarchy.normalizedDirectoryPath(entry.path)
        selectedEntryId = nil
        updateFilteredEntries()
    }

    /// 返回上级目录
    func goUp() {
        guard !currentDir.isEmpty else { return }
        // 去掉末尾的 "/"
        let trimmed = currentDir.hasSuffix("/") ? String(currentDir.dropLast()) : currentDir
        // 取上级路径
        if let lastSlash = trimmed.lastIndex(of: "/") {
            currentDir = String(trimmed[..<trimmed.index(after: lastSlash)])
        } else {
            currentDir = ""
        }
        selectedEntryId = nil
        updateFilteredEntries()
    }

    /// 返回根目录
    func goToRoot() {
        currentDir = ""
        selectedEntryId = nil
        updateFilteredEntries()
    }

    /// 面包屑路径组件
    var breadcrumbParts: [(name: String, path: String)] {
        ArchiveEntryHierarchy.breadcrumbParts(for: currentDir).map { ($0.name, $0.path) }
    }

    // MARK: - Rotation Animation

    func startRotation() {
        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
            rotationAngle = 360
        }
    }

    func stopRotation() {
        rotationAngle = 0
    }

    // MARK: - Drag Out (提取单个文件供拖拽)

    func extractEntryForDrag(entry: ArchiveEntry) -> URL {
        extractEntry(entry, openAfterExtraction: false, allowsPrivateKeyRecovery: true)
    }

    private func extractEntry(
        _ entry: ArchiveEntry,
        openAfterExtraction: Bool,
        allowsPrivateKeyRecovery: Bool
    ) -> URL {
        guard enforceValidSignature() else {
            return makeEntryErrorFile(ArchiveViewModelSecurityError.invalidArchiveSignature)
        }
        guard let archivePath = sourcePath else {
            return URL(fileURLWithPath: "/tmp/zwz-error.txt")
        }

        do {
            let url = try archiveClient.extractEntryToTemp(
                archivePath: archivePath,
                entryPath: entry.path,
                password: password.isEmpty ? nil : password,
                identityStore: identityStore
            )
            if openAfterExtraction {
                NSWorkspace.shared.open(url)
            }
            return url
        } catch {
            if handleProtectedOperationFailure(
                error,
                operation: .entry(entry, openAfterExtraction: openAfterExtraction),
                allowsRecovery: allowsPrivateKeyRecovery,
                context: .preview
            ) {
                return makeEntryErrorFile(error)
            }
            return makeEntryErrorFile(error)
        }
    }

    /// 双击打开/预览文件
    func openEntry(entry: ArchiveEntry) {
        if entry.isDirectory {
            // 目录：在预览列表中进入子目录
            enterDirectory(entry)
        } else {
            _ = extractEntry(entry, openAfterExtraction: true, allowsPrivateKeyRecovery: true)
        }
    }

    // MARK: - Helpers

    func resumePendingPrivateKeyOperationAfterRestore() {
        guard let operation = pendingPrivateKeyOperation else { return }
        clearPendingPrivateKeyRecovery()

        switch operation {
        case .compress:
            performCompress(allowsPrivateKeyRecovery: false)
        case .preview(let path, let isPasswordRetry):
            performPreview(
                path: path,
                isPasswordRetry: isPasswordRetry,
                allowsPrivateKeyRecovery: false
            )
        case .extract:
            performExtract(allowsPrivateKeyRecovery: false)
        case .smartExtract:
            performSmartExtract(allowsPrivateKeyRecovery: false)
        case .entry(let entry, let openAfterExtraction):
            _ = extractEntry(
                entry,
                openAfterExtraction: openAfterExtraction,
                allowsPrivateKeyRecovery: false
            )
        case .edit:
            beginArchiveEditing(allowsPrivateKeyRecovery: false)
        case .mount(let capacityMB):
            Task {
                await mountArchive(
                    capacityMB: capacityMB,
                    allowsPrivateKeyRecovery: false
                )
            }
        case .customResume(let resume):
            resume()
        }
    }

    func dismissMissingPrivateKeyPrompt() {
        clearPendingPrivateKeyRecovery()
    }

    func handleEntryPreviewProtectionFailure(
        _ error: Error,
        allowsPrivateKeyRecovery: Bool,
        retryAfterRestore: @escaping @MainActor @Sendable () -> Void
    ) {
        _ = handleProtectedOperationFailure(
            error,
            operation: .customResume(retryAfterRestore),
            allowsRecovery: allowsPrivateKeyRecovery,
            context: .preview
        )
    }

    private func compressionOptions() throws -> CompressionOptions {
        guard canStartCompression else {
            throw ArchiveViewModelSecurityError.invalidCompressionConfiguration
        }

        let encryption: ZwzEncryptionMode
        switch encryptionModeSelection {
        case .none:
            encryption = .none
        case .password:
            encryption = .password(password)
        case .publicKey:
            let recipientsByFingerprint = Dictionary(
                uniqueKeysWithValues: availableRecipients.map { ($0.fingerprint, $0) }
            )
            let recipients = try selectedRecipientFingerprints.sorted().map {
                fingerprint -> ZwzRecipient in
                guard let identity = recipientsByFingerprint[fingerprint] else {
                    throw ArchiveViewModelSecurityError.invalidCompressionConfiguration
                }
                return ZwzRecipient(
                    name: identity.name,
                    fingerprint: identity.fingerprint,
                    agreementPublicKey: identity.agreementPublicKey
                )
            }
            let signer: ZwzSigningIdentity?
            if let selectedSignerFingerprint {
                guard let identity = availableSigningIdentities.first(where: {
                    $0.fingerprint == selectedSignerFingerprint
                }) else {
                    throw ArchiveViewModelSecurityError.invalidCompressionConfiguration
                }
                signer = ZwzSigningIdentity(
                    name: identity.name,
                    fingerprint: identity.fingerprint,
                    agreementPublicKey: identity.agreementPublicKey,
                    signingPublicKey: identity.signingPublicKey
                )
            } else {
                signer = nil
            }
            encryption = .publicKey(recipients: recipients, signer: signer)
        }

        let splitVolume: SplitVolume?
        if let size = Int(splitSize), size > 0 {
            splitVolume = splitUnit == "MB" ? .megaBytes(size) : .kiloBytes(size)
        } else {
            splitVolume = nil
        }
        let threadCount = threadMode == .auto ? 0 : manualThreadCount
        return CompressionOptions(
            level: compressLevel,
            encryption: encryption,
            aes256: true,
            splitVolume: splitVolume,
            format: compressFormat,
            threadCount: threadCount
        )
    }

    @discardableResult
    private func handleProtectedOperationFailure(
        _ error: Error,
        operation: PendingPrivateKeyOperation,
        allowsRecovery: Bool,
        context: ErrorContext
    ) -> Bool {
        if let v3Error = error as? ZwzV3Error {
            switch v3Error {
            case .invalidSignature:
                let fingerprints = archiveSecurityInfo?.recipientFingerprints
                    ?? inspectedRecipients.map(\.fingerprint)
                archiveSecurityInfo = ZwzArchiveSecurityInfo(
                    encryption: .publicKey,
                    recipientFingerprints: fingerprints,
                    signature: .invalid
                )
                publishInvalidSignature()
                return true
            case .noMatchingPrivateKey(let fingerprints):
                isProcessing = false
                if allowsRecovery {
                    pendingPrivateKeyOperation = operation
                    if inspectedRecipients.isEmpty {
                        missingPrivateKeyRecipients = fingerprints.map {
                            ZwzRecipientInfo(name: "", fingerprint: $0)
                        }
                    } else {
                        missingPrivateKeyRecipients = inspectedRecipients
                    }
                    showMissingPrivateKeyPrompt = true
                    currentStatus = .idle
                    errorMessage = nil
                } else {
                    clearPendingPrivateKeyRecovery()
                    currentStatus = .error
                    errorMessage = v3Error.localizedDescription
                }
                return true
            default:
                break
            }
        }

        currentStatus = .error
        errorMessage = localizedMessage(for: error, context: context)
        return false
    }

    private func enforceValidSignature() -> Bool {
        guard archiveSecurityInfo?.signature == .invalid else { return true }
        publishInvalidSignature()
        return false
    }

    private func publishInvalidSignature() {
        clearPendingPrivateKeyRecovery()
        isProcessing = false
        currentStatus = .error
        errorMessage = ArchiveViewModelSecurityError.invalidArchiveSignature.localizedDescription
    }

    private func applyInspection(_ inspection: ZwzV3ArchiveInspection?) {
        guard let inspection else { return }
        archiveSecurityInfo = inspection.securityInfo
        inspectedRecipients = inspection.recipients
    }

    private func clearPendingPrivateKeyRecovery() {
        pendingPrivateKeyOperation = nil
        showMissingPrivateKeyPrompt = false
        missingPrivateKeyRecipients = []
    }

    private func makeEntryErrorFile(_ error: Error) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zwz-error-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        let errorFile = tempDir.appendingPathComponent("error.txt")
        try? error.localizedDescription.write(
            to: errorFile,
            atomically: true,
            encoding: .utf8
        )
        return errorFile
    }

    private static func looksLikeZwzPath(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "zwz"
    }

    private static func identitySort(
        _ lhs: ZwzIdentityMetadata,
        _ rhs: ZwzIdentityMetadata
    ) -> Bool {
        if lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedSame {
            return lhs.fingerprint < rhs.fingerprint
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func publicIdentitySort(
        _ lhs: ZwzPublicIdentity,
        _ rhs: ZwzPublicIdentity
    ) -> Bool {
        if lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedSame {
            return lhs.fingerprint < rhs.fingerprint
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private enum ErrorContext {
        case general
        case preview
        case extract
    }

    private func localizedMessage(for error: Error, context: ErrorContext) -> String {
        guard let v2Error = error as? ZwzV2Error else {
            return error.localizedDescription
        }

        switch v2Error {
        case .unsupportedVersion:
            return L.string("unsupported_zwz_version")
        case .wrongPasswordOrTamperedData:
            return context == .preview
                ? L.string("archive_password_required")
                : L.string("archive_password_or_tampered")
        case .missingVolume(let number):
            return L.string("missing_archive_volume", number)
        default:
            return v2Error.localizedDescription
        }
    }

    func formatBytes(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(Int64(b)) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", b / (1024 * 1024)) }
        return String(format: "%.2f GB", b / (1024 * 1024 * 1024))
    }

    func displaySize(for entry: ArchiveEntry) -> Int64 {
        ArchiveEntryPresentation.displaySize(for: entry, in: allEntries)
    }

    func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
