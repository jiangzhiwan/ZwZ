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
    @Published var compressFormat: CompressionFormat = .zip
    @Published var compressLevel: CompressionLevel = .normal
    @Published var password = ""
    @Published var splitSize = ""
    @Published var splitUnit = "MB"

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
    @Published var sourcePath: String?

    // 旋转动画
    @Published var rotationAngle: Double = 0

    // 历史
    @Published var history: [ZWZHistoryItem] = []

    // 待操作类型
    private var pendingAction: PendingAction = .none
    private var compressor = ZipCompressor()
    private var extractor = ArchiveExtractor()
    private var previewer = ArchivePreviewer()
    private var passwordWasAutoFilled = false
    private var editSession: ArchiveEditSession?

    var isEditableArchive: Bool {
        detectedFormat == .zip || detectedFormat == .zwz
    }

    private enum PendingAction {
        case none
        case compress
        case extract
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

    // MARK: - Actions

    func startCompress() {
        pendingAction = .compress
        password = ""
        rememberPreviewPassword = false
        splitSize = ""
        compressLevel = .normal
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
                detectedFormat = try extractor.detectFormat(archivePath: path)
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
                detectedFormat = try extractor.detectFormat(archivePath: path)
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
        errorMessage = nil
        currentStatus = .idle
        discardArchiveEdits()
    }

    // MARK: - Archive Editing

    func beginArchiveEditing() {
        guard let sourcePath, isEditableArchive else { return }
        isProcessing = true
        processingTitle = "正在准备编辑…"
        currentStatus = .reading
        let password = password.isEmpty ? nil : password
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let session = try ArchiveEditSession.create(archiveURL: URL(fileURLWithPath: sourcePath), password: password)
                let entries = try session.entries()
                DispatchQueue.main.async {
                    self.editSession = session
                    self.editEntries = entries
                    self.hasUnsavedArchiveEdits = false
                    self.isProcessing = false
                    self.currentStatus = .idle
                    self.editErrorMessage = nil
                    self.showArchiveEditor = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.currentStatus = .error
                    self.errorMessage = self.localizedMessage(for: error, context: .preview)
                }
            }
        }
    }

    func refreshEditEntries() {
        do { editEntries = try editSession?.entries() ?? [] }
        catch { editErrorMessage = error.localizedDescription }
    }

    func addToArchive(urls: [URL], directory: String) {
        guard let editSession else { return }
        do {
            try editSession.add(urls: urls, into: directory)
            refreshEditEntries()
        } catch { editErrorMessage = error.localizedDescription }
        hasUnsavedArchiveEdits = editSession.hasChanges
    }

    func deleteFromArchive(path: String) {
        guard let editSession else { return }
        do {
            try editSession.delete(path: path)
            refreshEditEntries()
        } catch { editErrorMessage = error.localizedDescription }
        hasUnsavedArchiveEdits = editSession.hasChanges
    }

    func renameInArchive(path: String, to name: String) {
        guard let editSession else { return }
        do {
            try editSession.rename(path: path, to: name)
            refreshEditEntries()
        } catch { editErrorMessage = error.localizedDescription }
        hasUnsavedArchiveEdits = editSession.hasChanges
    }

    func replaceInArchive(path: String, with url: URL) {
        guard let editSession else { return }
        do {
            try editSession.replace(path: path, with: url)
            refreshEditEntries()
        } catch { editErrorMessage = error.localizedDescription }
        hasUnsavedArchiveEdits = editSession.hasChanges
    }

    func textForArchiveEntry(path: String) throws -> String { try editSession?.text(for: path) ?? "" }

    @discardableResult
    func saveTextInArchive(_ text: String, path: String) -> Bool {
        guard let editSession else { return false }
        do {
            try editSession.writeText(text, to: path)
            refreshEditEntries()
            hasUnsavedArchiveEdits = editSession.hasChanges
            return true
        } catch {
            editErrorMessage = error.localizedDescription
            hasUnsavedArchiveEdits = editSession.hasChanges
            return false
        }
    }

    func saveArchiveEdits(onSuccess: (@MainActor @Sendable () -> Void)? = nil) {
        guard let session = editSession else {
            onSuccess?()
            return
        }
        let archivePath = session.archiveURL.path
        isSavingEdits = true
        editErrorMessage = nil
        let password = password.isEmpty ? nil : password
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try session.save(password: password)
                DispatchQueue.main.async {
                    self.isSavingEdits = false
                    self.editSession = nil
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
        editSession = nil
        editEntries = []
        editErrorMessage = nil
        hasUnsavedArchiveEdits = false
        showArchiveEditor = false
    }

    // MARK: - Compress

    func performCompress() {
        guard let srcPath = sourcePath else {
            errorMessage = "No source file selected"
            return
        }

        let ext = compressFormat.fileExtension
        let destPath = srcPath.hasSuffix(".\(ext)") ? srcPath : srcPath + ".\(ext)"

        var splitVolume: SplitVolume?
        if let size = Int(splitSize), size > 0 {
            splitVolume = splitUnit == "MB" ? .megaBytes(size) : .kiloBytes(size)
        }

        // 线程数
        let threadCount: Int
        if threadMode == .auto {
            threadCount = 0  // 0 = 自动检测
        } else {
            threadCount = manualThreadCount
        }

        let options = CompressionOptions(
            level: compressLevel,
            password: password.isEmpty ? nil : password,
            aes256: true,
            splitVolume: splitVolume,
            format: compressFormat,
            threadCount: threadCount
        )

        isProcessing = true
        progress = 0
        processingTitle = "正在压缩…"
        currentStatus = .compressing
        let generation = beginOperation()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let compressor = ZipCompressor()
                let zwzCompressor = ZwzCompressor()

                switch options.format {
                case .zip:
                    try compressor.compress(
                        sourcePath: srcPath,
                        destinationPath: destPath,
                        options: options,
                        progress: { prog in
                        DispatchQueue.main.async {
                            guard self.acceptsCallback(generation: generation) else { return }
                            self.progress = prog
                        }
                    }, cancellationToken: self.cancellationToken)
                case .zwz:
                    try zwzCompressor.compress(
                        sourcePath: srcPath,
                        destinationPath: destPath,
                        options: options,
                        progress: { prog in
                        DispatchQueue.main.async {
                            self.progress = prog
                        }
                    }, cancellationToken: self.cancellationToken)
                }

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
                    self.currentStatus = .error
                    self.errorMessage = self.localizedMessage(for: error, context: .general)
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

    func performSmartExtract() {
        guard let srcPath = sourcePath else {
            errorMessage = "No archive selected"
            return
        }

        let archiveURL = URL(fileURLWithPath: srcPath)
        let plan = SmartExtractionPlanner.makePlan(archiveURL: archiveURL, entries: allEntries)
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
                try self.extractor.extract(
                    archivePath: srcPath,
                    destinationPath: plan.extractionDirectory.path,
                    password: pwd,
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
                if plan.extractedTopLevelName != nil {
                    try? FileManager.default.removeItem(at: plan.extractionDirectory)
                }
                DispatchQueue.main.async {
                    guard self.acceptsCallback(generation: generation) else { return }
                    self.isProcessing = false
                    self.currentStatus = .error
                    self.errorMessage = self.localizedMessage(for: error, context: .extract)
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

    func performExtract() {
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
                try self.extractor.extract(
                    archivePath: srcPath,
                    destinationPath: destPath,
                    password: pwd,
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
                    self.currentStatus = .error
                    self.errorMessage = self.localizedMessage(for: error, context: .extract)
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

    // MARK: - Preview (inline, not a sheet)

    func performPreview(path: String, isPasswordRetry: Bool = false) {
        searchQuery = ""
        showHiddenFiles = UserDefaults.standard.bool(forKey: "zwz_preview_show_hidden")
        previewPasswordError = nil
        isProcessing = true
        processingTitle = "正在读取…"
        currentStatus = .reading
        let previewPassword = password.isEmpty ? nil : password
        let generation = beginOperation()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entries = try self.previewer.preview(archivePath: path, password: previewPassword)
                DispatchQueue.main.async {
                    guard self.acceptsCallback(generation: generation) else { return }
                    self.handlePreviewSuccess(entries)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.acceptsCallback(generation: generation) else { return }
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
        currentDir = ""
        setArchiveEntries(entries)
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
        guard let archivePath = sourcePath else {
            return URL(fileURLWithPath: "/tmp/zwz-error.txt")
        }

        do {
            let url = try extractor.extractEntryToTemp(
                archivePath: archivePath,
                entryPath: entry.path,
                password: password.isEmpty ? nil : password
            )
            return url
        } catch {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("zwz-error-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let errorFile = tempDir.appendingPathComponent("error.txt")
            try? error.localizedDescription.write(to: errorFile, atomically: true, encoding: .utf8)
            return errorFile
        }
    }

    /// 双击打开/预览文件
    func openEntry(entry: ArchiveEntry) {
        if entry.isDirectory {
            // 目录：在预览列表中进入子目录
            enterDirectory(entry)
        } else {
            // 文件：用系统默认应用打开
            let tempURL = extractEntryForDrag(entry: entry)
            NSWorkspace.shared.open(tempURL)
        }
    }

    // MARK: - Helpers

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
