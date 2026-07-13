import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ZwzCore

@MainActor
final class AppearanceManager {
    static let shared = AppearanceManager()

    func apply(_ mode: String = UserDefaults.standard.string(forKey: "zwz_appearance") ?? "system") {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

// MARK: - App Delegate (确保窗口弹出)

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private let mainWorkspace = WorkspaceViewModel(restoreTabs: WorkspaceSettings.restoreTabs())
    private var workspaceKeyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceManager.shared.apply()
        applyAppIcon()
        setupStatusItem()
        setupWorkspaceShortcuts()
        createMainWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { createMainWindow() }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        createMainWindow()
        mainWorkspace.requestOpen(url: url, intent: .automatic)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Main Window

    func createMainWindow() {
        if mainWindow != nil {
            mainWindow?.makeKeyAndOrderFront(nil)
            mainWindow?.orderFrontRegardless()
            return
        }

        let contentView = WorkspaceContentView(workspace: mainWorkspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ZwZ"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        let hostingController = NSHostingController(rootView: contentView)
        // This window owns its size; SwiftUI content updates must not resize it.
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 820, height: 420)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.isMovableByWindowBackground = true
        window.delegate = self
        mainWindow = window

        DispatchQueue.main.async { [weak window] in
            guard let window,
                  let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
                window?.alphaValue = 1
                return
            }
            let currentFrame = window.frame
            window.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - currentFrame.width / 2,
                y: visibleFrame.midY - currentFrame.height / 2
            ))
            window.alphaValue = 1
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow else {
            return true
        }
        sender.orderOut(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === mainWindow else {
            return
        }
        mainWindow?.delegate = nil
        mainWindow = nil
    }

    private func setupWorkspaceShortcuts() {
        workspaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard NSApp.keyWindow === self.mainWindow else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            if modifiers.contains(.command) {
                if key == "t" {
                    _ = self.mainWorkspace.newTab()
                    return nil
                }
                if key == "w" {
                    self.mainWorkspace.requestClose(id: self.mainWorkspace.selectedTabID)
                    return nil
                }
                if let number = Int(key), (1...9).contains(number) {
                    self.mainWorkspace.selectShortcutIndex(number)
                    return nil
                }
            }

            if event.keyCode == 48, modifiers.contains(.control) {
                if modifiers.contains(.shift) {
                    self.mainWorkspace.selectPrevious()
                } else {
                    self.mainWorkspace.selectNext()
                }
                return nil
            }
            return event
        }
    }

    // MARK: - Status Bar Item

    private func applyAppIcon() {
        if let icon = Self.zwzLogoImage() {
            NSApp.applicationIconImage = icon
        }
    }

    private static func zwzLogoImage() -> NSImage? {
        if let resourceURL = Bundle.module.url(forResource: "ZwZLogo", withExtension: "png"),
           let image = NSImage(contentsOf: resourceURL) {
            return image
        }
        if let resourceURL = Bundle.main.url(forResource: "ZwZLogo", withExtension: "png"),
           let image = NSImage(contentsOf: resourceURL) {
            return image
        }
        return nil
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            if let image = Self.zwzLogoImage() {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = false
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "doc.zippressor", accessibilityDescription: "zwz")
            }
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "zwz", action: nil, keyEquivalent: ""))

        menu.addItem(.separator())

        let compressMenu = NSMenu(title: "压缩")
        let compressFile = NSMenuItem(title: "选择文件压缩…", action: #selector(compressFileAction), keyEquivalent: "")
        let compressFolder = NSMenuItem(title: "选择文件夹压缩…", action: #selector(compressFolderAction), keyEquivalent: "")
        compressFile.target = self
        compressFolder.target = self
        compressMenu.addItem(compressFile)
        compressMenu.addItem(compressFolder)
        let compressItem = NSMenuItem(title: "压缩", action: nil, keyEquivalent: "")
        compressItem.submenu = compressMenu
        menu.addItem(compressItem)

        let extractItem = NSMenuItem(title: "选择压缩包解压…", action: #selector(extractAction), keyEquivalent: "")
        extractItem.target = self
        menu.addItem(extractItem)

        let previewItem = NSMenuItem(title: "预览压缩包内容…", action: #selector(previewAction), keyEquivalent: "")
        previewItem.target = self
        menu.addItem(previewItem)

        menu.addItem(.separator())

        let clipboardItem = NSMenuItem(title: "压缩剪贴板文件", action: #selector(clipboardAction), keyEquivalent: "")
        clipboardItem.target = self
        menu.addItem(clipboardItem)

        menu.addItem(.separator())

        let versionItem = NSMenuItem(title: "版本 1.0", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 zwz", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Menu Actions

    private let compressor = ZipCompressor()

    @objc func compressFileAction() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "压缩"
        if panel.runModal() == .OK, let url = panel.url { compressFile(at: url.path) }
    }

    @objc func compressFolderAction() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "压缩"
        if panel.runModal() == .OK, let url = panel.url { compressFile(at: url.path) }
    }

    @objc func extractAction() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "解压"
        if panel.runModal() == .OK, let url = panel.url { extractArchive(at: url.path) }
    }

    @objc func previewAction() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "预览"
        if panel.runModal() == .OK, let url = panel.url { previewArchive(at: url.path) }
    }

    @objc func clipboardAction() {
        guard let pbItems = NSPasteboard.general.pasteboardItems else { return }
        for item in pbItems {
            if let urlData = item.data(forType: .fileURL),
               let url = URL(dataRepresentation: urlData, relativeTo: nil) {
                compressFile(at: url.path)
                return
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard VirtualDiskManager.shared.session == nil else {
            let alert = NSAlert()
            alert.messageText = SettingsStrings.text("请先卸载虚拟磁盘", "Unmount the Virtual Disk First")
            alert.informativeText = SettingsStrings.text("为避免丢失修改，虚拟磁盘挂载期间不能退出 ZwZ。", "ZwZ cannot quit while the virtual disk is active because changes may not have been saved.")
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }

    @objc func quitAction() { NSApplication.shared.terminate(nil) }

    // MARK: - Core Logic

    func compressFile(at path: String) {
        let destPath = path.hasSuffix(".zip") ? path : path + ".zip"
        let compressor = self.compressor
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try compressor.compress(sourcePath: path, destinationPath: destPath, options: CompressionOptions())
                DispatchQueue.main.async {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: destPath)
                    Self.notify(title: "压缩完成", body: (destPath as NSString).lastPathComponent)
                }
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async { Self.notify(title: "压缩失败", body: msg) }
            }
        }
    }

    func extractArchive(at path: String) {
        openArchiveInWorkspace(at: path, intent: .extract)
    }

    func previewArchive(at path: String) {
        openArchiveInWorkspace(at: path, intent: .preview)
    }

    private func openArchiveInWorkspace(at path: String, intent: WorkspaceOpenIntent) {
        createMainWindow()
        mainWorkspace.requestOpen(url: URL(fileURLWithPath: path), intent: intent)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor static func notify(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = "NSUserNotificationDefaultSoundName"
        NSUserNotificationCenter.default.deliver(notification)
    }

}

// MARK: - App Entry

@main
struct ZwzApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            ZWZSettingsView()
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var viewModel: ArchiveViewModel
    @ObservedObject private var languageManager = LanguageManager.shared
    @State private var showHistorySidebar = false
    @State private var isDropTargeted = false
    private let showsToolbar: Bool
    private let onOpenDroppedURL: ((URL) -> Void)?

    init(
        viewModel: ArchiveViewModel = ArchiveViewModel(),
        showsToolbar: Bool = true,
        onOpenDroppedURL: ((URL) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.showsToolbar = showsToolbar
        self.onOpenDroppedURL = onOpenDroppedURL
    }

    var body: some View {
        ZStack {
            // 极浅蓝粉渐变背景
            LinearGradient.zwzBackground
                .ignoresSafeArea()

            ZStack(alignment: .leading) {
                // 主区域
                VStack(spacing: 0) {
                    if showsToolbar {
                        ZWZToolbar(viewModel: viewModel, showHistorySidebar: $showHistorySidebar)
                    }

                    if viewModel.isProcessing {
                        ZWZProcessingView(viewModel: viewModel)
                    } else if viewModel.signatureBadge == .invalid,
                              viewModel.sourcePath != nil {
                        ZWZArchiveContentView(viewModel: viewModel)
                    } else if let errorMessage = viewModel.errorMessage {
                        ZWZErrorView(message: errorMessage) { viewModel.errorMessage = nil }
                    } else if !viewModel.previewEntries.isEmpty || viewModel.archiveSecurityInfo != nil {
                        ZWZArchiveContentView(viewModel: viewModel)
                    } else {
                        ZWZDropZone(viewModel: viewModel, isDragging: $isDropTargeted)
                    }

                    ZWZStatusBar()
                }

                // 左侧历史抽屉（overlay 方式，避免 HStack 布局冲突）
                if showHistorySidebar {
                    ZWZHistorySidebar(viewModel: viewModel, isShowing: $showHistorySidebar)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .frame(width: 240)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(languageManager.currentLanguage)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .sheet(isPresented: $viewModel.showCompressOptions) {
            ZWZCompressOptionsView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showExtractOptions) {
            ZWZExtractOptionsView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showPreviewPasswordPrompt) {
            ZWZPreviewPasswordView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showVaultSetupPrompt) {
            ZWZMasterPasswordSetupView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showVaultUnlockPrompt) {
            ZWZMasterPasswordUnlockView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showMissingPrivateKeyPrompt) {
            ZWZMissingPrivateKeyRecoveryView(viewModel: viewModel)
        }
        .background {
            ArchiveEditorWindowPresenter(
                isPresented: $viewModel.showArchiveEditor,
                viewModel: viewModel
            )
            .frame(width: 0, height: 0)
        }
        .fileImporter(
            isPresented: $viewModel.showFilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { viewModel.handleFilePick(url: url) }
            case .failure: break
            }
        }
        .fileExporter(
            isPresented: $viewModel.showSavePanel,
            document: TextDocument(text: ""),
            contentType: .data,
            defaultFilename: "archive.zip"
        ) { result in
            switch result {
            case .success(let url): viewModel.handleSaveLocation(url: url)
            case .failure: break
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                if let onOpenDroppedURL {
                    onOpenDroppedURL(url)
                } else {
                    viewModel.handleAutoOpen(path: url.path, url: url)
                }
            }
        }
        return true
    }
}

// MARK: - Preview Password Sheet

struct ZWZPreviewPasswordView: View {
    @ObservedObject var viewModel: ArchiveViewModel
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.zwzPink.opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: "lock.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.zwzPink)
            }

            VStack(spacing: 6) {
                Text(L.string("preview_password_title"))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(viewModel.archiveName)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 8) {
                SecureField(L.string("enter_password"), text: $viewModel.password)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, design: .rounded))
                    .focused($isPasswordFocused)
                    .onSubmit {
                        if viewModel.canSubmitPreviewPassword {
                            viewModel.retryPreviewWithPassword()
                        }
                    }

                if let message = viewModel.previewPasswordError {
                    Text(message)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.red)
                }

                if UserDefaults.standard.bool(forKey: ArchivePasswordVault.rememberEnabledKey) {
                    Toggle("记住此密码", isOn: $viewModel.rememberPreviewPassword)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12, design: .rounded))
                }
            }

            HStack(spacing: 12) {
                Button(L.string("cancel")) {
                    viewModel.cancelPreviewPasswordPrompt()
                }
                .zwzSheetButtonStyle(.secondary)

                Button(L.string("preview_with_password")) {
                    viewModel.retryPreviewWithPassword()
                }
                .zwzSheetButtonStyle(.pink)
                .disabled(!viewModel.canSubmitPreviewPassword)
            }
        }
        .padding(28)
        .frame(width: 400)
        .background(LinearGradient.zwzBackground.opacity(0.5))
        .onAppear { isPasswordFocused = true }
    }
}

struct ZWZMasterPasswordSetupView: View {
    @ObservedObject var viewModel: ArchiveViewModel
    @State private var masterPassword = ""
    @State private var confirmation = ""
    @FocusState private var focusedField: Field?

    private enum Field { case password, confirmation }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置主密码")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text("主密码用于加密本地保存的解压密码，不会被保存。")
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(.secondary)
            SecureField("主密码", text: $masterPassword)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .password)
            SecureField("确认主密码", text: $confirmation)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .confirmation)
            if let error = viewModel.vaultPromptError {
                Text(error).font(.system(size: 11)).foregroundColor(.red)
            }
            HStack {
                Button(L.string("cancel")) { viewModel.showVaultSetupPrompt = false }
                    .zwzSheetButtonStyle(.secondary)
                Button("继续") { viewModel.configurePasswordVault(masterPassword: masterPassword, confirmation: confirmation) }
                    .zwzSheetButtonStyle(.pink)
                    .disabled(masterPassword.isEmpty || confirmation.isEmpty)
            }
        }
        .padding(28)
        .frame(width: 400)
        .onAppear { focusedField = .password }
    }
}

struct ZWZMasterPasswordUnlockView: View {
    @ObservedObject var viewModel: ArchiveViewModel
    @State private var masterPassword = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("解锁密码库")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text("输入主密码以读取已保存的解压密码。")
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(.secondary)
            SecureField("主密码", text: $masterPassword)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { viewModel.unlockPasswordVault(masterPassword: masterPassword) }
            if let error = viewModel.vaultPromptError {
                Text(error).font(.system(size: 11)).foregroundColor(.red)
            }
            HStack {
                Button(L.string("cancel")) { viewModel.showVaultUnlockPrompt = false }
                    .zwzSheetButtonStyle(.secondary)
                Button("解锁") { viewModel.unlockPasswordVault(masterPassword: masterPassword) }
                    .zwzSheetButtonStyle(.pink)
                    .disabled(masterPassword.isEmpty)
            }
        }
        .padding(28)
        .frame(width: 400)
        .onAppear { isFocused = true }
    }
}

struct ZWZArchiveEditorView: View {
    @ObservedObject var viewModel: ArchiveViewModel
    @State private var selectedPath: String?
    @State private var renameValue = ""
    @State private var showRenamePrompt = false
    @State private var showTextEditor = false
    @State private var textContent = ""
    @State private var textPath = ""
    @State private var showDiscardConfirmation = false
    @State private var editCurrentDir = ""

    private var visibleEditEntries: [ArchiveEntry] {
        ArchiveEntryHierarchy.immediateChildren(
            of: viewModel.editEntries,
            in: editCurrentDir,
            showHiddenFiles: viewModel.showHiddenFiles
        )
    }

    private var editBreadcrumbParts: [ArchiveEntryHierarchy.BreadcrumbPart] {
        ArchiveEntryHierarchy.breadcrumbParts(for: editCurrentDir)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("编辑压缩包")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(viewModel.archiveName)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

                Toggle(isOn: $viewModel.showHiddenFiles) {
                    Image(systemName: viewModel.showHiddenFiles ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .foregroundColor(viewModel.showHiddenFiles ? .zwzBlue : .secondary)
                .help(viewModel.showHiddenFiles ? "隐藏隐藏文件" : "显示隐藏文件")
                Button {
                    chooseFilesToAdd()
                } label: {
                    editorToolbarIcon("plus")
                }
                .buttonStyle(.plain)
                .help("添加文件或文件夹")
                Button {
                    guard let selectedPath else { return }
                    renameValue = (selectedPath as NSString).lastPathComponent
                    showRenamePrompt = true
                } label: {
                    editorToolbarIcon("pencil")
                }
                .buttonStyle(.plain)
                .disabled(selectedPath == nil)
                .help("重命名")
                Button {
                    guard let selectedPath else { return }
                    chooseReplacement(for: selectedPath)
                } label: {
                    editorToolbarIcon("arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .disabled(selectedPath == nil)
                .help("替换文件")
                Button(role: .destructive) {
                    guard let selectedPath else { return }
                    viewModel.deleteFromArchive(path: selectedPath)
                    self.selectedPath = nil
                } label: {
                    editorToolbarIcon("trash", color: .red)
                }
                .buttonStyle(.plain)
                .disabled(selectedPath == nil)
                .help("删除")
            }
            .padding(16)

            Divider()

            HStack(spacing: 4) {
                ForEach(Array(editBreadcrumbParts.enumerated()), id: \.element.id) { index, part in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.5))
                    }

                    Button {
                        editCurrentDir = part.path
                        selectedPath = nil
                    } label: {
                        Text(part.name)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(index == editBreadcrumbParts.count - 1 ? .primary : .zwzBlue)
                            .padding(.horizontal, 4)
                            .frame(minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            List(selection: $selectedPath) {
                ForEach(visibleEditEntries, id: \.path) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: ArchiveEntryPresentation.iconName(forFileNamed: entry.name, isDirectory: entry.isDirectory))
                            .foregroundColor(entry.isDirectory ? .zwzPink : .zwzBlue)
                            .font(.system(size: 16))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.system(size: 14, design: .rounded))
                            Text(entry.path)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        if entry.isDirectory {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11))
                                .foregroundColor(.zwzBlue)
                        }

                        Text(viewModel.formatBytes(
                            ArchiveEntryPresentation.displaySize(for: entry, in: viewModel.editEntries)
                        ))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.secondary)
                        .monospacedDigit()

                        if canEditText(entry) {
                            Button {
                                openTextEditor(entry)
                            } label: {
                                Image(systemName: "doc.text")
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("编辑文本")
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        openEditEntry(entry)
                    }
                    .tag(entry.path)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let error = viewModel.editErrorMessage {
                Text(error).font(.system(size: 11)).foregroundColor(.red).padding(.horizontal, 16).padding(.top, 8)
            }

            HStack {
                Button(viewModel.hasUnsavedArchiveEdits ? "放弃更改" : "关闭") {
                    if viewModel.hasUnsavedArchiveEdits {
                        showDiscardConfirmation = true
                    } else {
                        viewModel.discardArchiveEdits()
                    }
                }
                    .zwzSheetButtonStyle(.secondary)
                Spacer()
                Button("保存到压缩包") {
                    viewModel.saveArchiveEdits()
                }
                .zwzSheetButtonStyle(.pink)
                .disabled(viewModel.isSavingEdits || !viewModel.hasUnsavedArchiveEdits)
            }
            .padding(16)
        }
        .frame(width: 720, height: 540)
        .overlay {
            if viewModel.isSavingEdits {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView("正在保存到压缩包…")
                        .padding(20)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .alert("重命名", isPresented: $showRenamePrompt) {
            TextField("名称", text: $renameValue)
            Button("取消", role: .cancel) {}
            Button("确定") {
                if let selectedPath { viewModel.renameInArchive(path: selectedPath, to: renameValue); self.selectedPath = nil }
            }
        }
        .alert("放弃所有未保存更改？", isPresented: $showDiscardConfirmation) {
            Button("放弃", role: .destructive) { viewModel.discardArchiveEdits() }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showTextEditor) {
            ZWZArchiveTextEditor(path: textPath, text: $textContent) {
                if viewModel.saveTextInArchive(textContent, path: textPath) {
                    showTextEditor = false
                }
            }
        }
        .onAppear {
            editCurrentDir = viewModel.isSearching
                ? ""
                : ArchiveEntryHierarchy.normalizedDirectoryPath(viewModel.currentDir)
        }
    }

    private func canEditText(_ entry: ArchiveEntry) -> Bool {
        !entry.isDirectory && ["txt", "md", "json", "xml", "csv", "yaml", "yml", "log", "swift", "js", "ts", "html", "css", "py", "java", "c", "cc", "cpp", "cxx", "h", "hpp"].contains((entry.name as NSString).pathExtension.lowercased())
    }

    private func editorToolbarIcon(_ systemName: String, color: Color = .zwzBlue) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(color)
            .frame(width: 36, height: 36)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func openTextEditor(_ entry: ArchiveEntry) {
        guard let text = try? viewModel.textForArchiveEntry(path: entry.path) else { return }
        textPath = entry.path
        textContent = text
        showTextEditor = true
    }

    private func openEditEntry(_ entry: ArchiveEntry) {
        if entry.isDirectory {
            editCurrentDir = ArchiveEntryHierarchy.normalizedDirectoryPath(entry.path)
            selectedPath = nil
        } else if canEditText(entry) {
            openTextEditor(entry)
        }
    }

    private func chooseFilesToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            let directory = selectedDirectoryPath()
            viewModel.addToArchive(urls: panel.urls, directory: directory)
        }
    }

    private func chooseReplacement(for path: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "替换"
        if panel.runModal() == .OK, let url = panel.url { viewModel.replaceInArchive(path: path, with: url) }
    }

    private func selectedDirectoryPath() -> String {
        guard let selectedPath,
              let entry = visibleEditEntries.first(where: { $0.path == selectedPath }) else {
            return editCurrentDir
        }
        if entry.isDirectory { return entry.path }
        return (selectedPath as NSString).deletingLastPathComponent
    }
}

struct ZWZArchiveTextEditor: View {
    let path: String
    @Binding var text: String
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(path)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                Button("取消") { dismiss() }.zwzSheetButtonStyle(.secondary)
                Button("应用更改") { save() }.zwzSheetButtonStyle(.pink)
            }
            .padding(14)
            Divider()
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .padding(10)
        }
        .frame(width: 720, height: 520)
    }
}

@MainActor
struct ZWZMissingPrivateKeyRecoveryView: View {
    @ObservedObject private var viewModel: ArchiveViewModel
    @StateObject private var identityModel: IdentityManagerViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: ArchiveViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _identityModel = StateObject(wrappedValue: IdentityManagerViewModel(
            store: viewModel.identityStore,
            onPrivateRestore: { [weak viewModel] in
                viewModel?.resumePendingPrivateKeyOperationAfterRestore()
            }
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.zwzOrange)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(SettingsStrings.text("缺少匹配的私钥", "Matching Private Key Required"))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(SettingsStrings.text(
                        "恢复接收方的私钥备份后将自动重试一次。",
                        "Restore a recipient private-key backup to retry once."
                    ))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    cancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L.string("cancel"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label(
                    SettingsStrings.text("归档声明的接收方（未验证）", "Archive-declared recipients (unverified)"),
                    systemImage: "exclamationmark.shield"
                )
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.zwzOrange)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(viewModel.missingPrivateKeyRecipients.enumerated()), id: \.offset) { _, recipient in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(recipient.name.isEmpty
                                    ? SettingsStrings.text("未知接收方", "Unknown Recipient")
                                    : recipient.name)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                Text(recipient.fingerprint)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            IdentityManagerView(model: identityModel)
                .padding(20)

            Divider()

            HStack {
                Spacer()
                Button(L.string("cancel"), action: cancel)
                    .zwzSheetButtonStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 700, height: 640)
        .background(LinearGradient.zwzBackground.opacity(0.5))
        .interactiveDismissDisabled()
        .onDisappear {
            viewModel.dismissMissingPrivateKeyPrompt()
        }
    }

    private func cancel() {
        viewModel.dismissMissingPrivateKeyPrompt()
        dismiss()
    }
}

// MARK: - Toolbar

struct ZWZToolbar: View {
    @ObservedObject var viewModel: ArchiveViewModel
    @Binding var showHistorySidebar: Bool

    var body: some View {
        HStack(spacing: 16) {
            // 历史按钮（汉堡图标）
            ZWZIconButton(icon: "sidebar.left", action: {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showHistorySidebar.toggle()
                }
            })
            .opacity(showHistorySidebar ? 0.5 : 1.0)

            ZWZLogoView(size: 34)

            Spacer()

            // 压缩按钮（蓝色渐变）
            ZWZGradientButton(
                icon: "doc.badge.plus",
                title: L.string("compress"),
                gradient: .zwzBlueGradient
            ) {
                viewModel.startCompress()
            }

            // 解压按钮（粉色渐变）
            ZWZGradientButton(
                icon: "arrow.down.doc.fill",
                title: L.string("extract"),
                gradient: .zwzPinkGradient
            ) {
                viewModel.startExtract()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Pressable Button (微交互)

struct ZWZGradientButton: View {
    let icon: String
    let title: String
    let gradient: LinearGradient
    let action: () -> Void
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(width: 120, height: 36)      // 固定尺寸，保证按钮一致
            .background(gradient)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.93 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - Icon Button (历史抽屉等)

struct ZWZIconButton: View {
    let icon: String
    let action: () -> Void
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.90 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - Drop Zone

struct ZWZDropZone: View {
    @ObservedObject var viewModel: ArchiveViewModel
    @Binding var isDragging: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // 毛玻璃卡片拖拽区
            VStack(spacing: 16) {
                ZStack {
                    // 卡片背景
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.ultraThinMaterial)
                        .frame(width: 380, height: 240)
                        .zwzCardShadow(ZWZShadow(
                            color: isDragging ? Color.zwzBlue.opacity(0.25) : .black.opacity(0.08),
                            radius: isDragging ? 24 : 12,
                            x: 0, y: 6
                        ))

                    // 动态虚线边框
                    RoundedRectangle(cornerRadius: 28)
                        .strokeBorder(
                            LinearGradient(
                                colors: isDragging
                                    ? [Color.zwzBlue, Color.zwzPink]
                                    : [Color.zwzBlue.opacity(0.35), Color.zwzPink.opacity(0.35)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(
                                lineWidth: isDragging ? 3 : 2,
                                dash: [12, 8],
                                dashPhase: isDragging ? 20 : 0
                            )
                        )
                        .frame(width: 380, height: 240)

                    VStack(spacing: 14) {
                        // 动画图标
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: isDragging
                                            ? [Color.zwzBlue.opacity(0.2), Color.zwzPink.opacity(0.2)]
                                            : [Color.zwzBlue.opacity(0.1), Color.zwzPink.opacity(0.1)],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                                .frame(width: 72, height: 72)

                            Image(systemName: isDragging ? "arrow.down.doc.fill" : "doc.on.doc")
                                .font(.system(size: 32))
                                .foregroundStyle(LinearGradient.zwzBluePink)
                                .scaleEffect(isDragging ? 1.15 : 1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isDragging)
                        }

                        Text(L.string("drop_hint"))
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundColor(.primary)

                        Text(L.string("supported_formats"))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .scaleEffect(isDragging ? 1.02 : 1.0)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isDragging)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - History Sidebar (左侧抽屉)

struct ZWZHistorySidebar: View {
    @ObservedObject var viewModel: ArchiveViewModel
    @Binding var isShowing: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("历史记录")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        isShowing = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.gray.opacity(0.12))
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)

            Divider()

            if viewModel.history.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("暂无历史记录")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.history.reversed(), id: \.id) { item in
                            ZWZHistoryRow(item: item)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(.ultraThinMaterial)
    }
}

struct ZWZHistoryRow: View {
    let item: ZWZHistoryItem

    var body: some View {
        HStack(spacing: 10) {
            // 图标
            ZStack {
                Circle()
                    .fill(item.type == .compress ? Color.zwzBlue.opacity(0.15) : Color.zwzPink.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: item.type == .compress ? "doc.badge.plus" : "arrow.down.doc.fill")
                    .font(.system(size: 14))
                    .foregroundColor(item.type == .compress ? .zwzBlue : .zwzPink)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(1)
                Text(item.statusText)
                    .font(.system(size: 11))
                    .foregroundColor(item.isSuccess ? .zwzGreen : .red)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.zwzCardBg.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Processing View

struct ZWZProcessingView: View {
    @ObservedObject var viewModel: ArchiveViewModel
    @State private var animatePulse = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 20) {
                // 精致加载动画：脉冲圆环 + 旋转弧线
                ZStack {
                    // 外圈脉冲
                    Circle()
                        .stroke(
                            LinearGradient.zwzBluePink,
                            style: StrokeStyle(lineWidth: 3, dash: [8, 6])
                        )
                        .frame(width: 80, height: 80)
                        .rotationEffect(.degrees(viewModel.rotationAngle))
                        .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: viewModel.isProcessing)

                    // 内圈缩放
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.zwzBlue.opacity(0.15), Color.zwzPink.opacity(0.15)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(width: 56, height: 56)
                        .scaleEffect(animatePulse ? 1.1 : 0.9)
                        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: animatePulse)

                    // 中心图标
                    Image(systemName: "gear")
                        .font(.system(size: 22))
                        .foregroundStyle(LinearGradient.zwzBluePink)
                        .rotationEffect(.degrees(viewModel.rotationAngle))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: viewModel.isProcessing)
                }

                Text(viewModel.processingTitle)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundColor(.primary)

                // 渐变进度条
                if viewModel.progress > 0 {
                    VStack(spacing: 10) {
                        ZWZGradientProgressBar(value: viewModel.progress)
                            .frame(width: 320)

                        Text("\(Int(viewModel.progress * 100))%")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            viewModel.startRotation()
            animatePulse = true
        }
        .onDisappear {
            viewModel.stopRotation()
            animatePulse = false
        }
    }
}

// MARK: - Gradient Progress Bar

struct ZWZGradientProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // 背景
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.12))
                    .frame(height: 8)

                // 渐变填充
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient.zwzBluePink)
                    .frame(width: geo.size.width * value, height: 8)
                    .animation(.easeOut(duration: 0.3), value: value)
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Error View

struct ZWZErrorView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // 错误卡片
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.zwzOrange.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.zwzOrange)
                }

                Text(message)
                    .font(.system(size: 15, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 40)

                ZWZGradientButton(
                    icon: "checkmark",
                    title: L.string("ok"),
                    gradient: .zwzBlueGradient
                ) {
                    onDismiss()
                }
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .zwzCardShadow()

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Archive Content View (内联文件列表)

struct ZWZArchiveContentView: View {
    @ObservedObject var viewModel: ArchiveViewModel
    @ObservedObject private var virtualDisk = VirtualDiskManager.shared
    @StateObject private var entryPreviewModel: ArchiveEntryPreviewModel
    @State private var showMountOptions = false
    @State private var presentRecoveryAfterMountDismiss = false
    @State private var capacityMB = 256
    @State private var isPreviewSidebarPresented = false
    @State private var closedPreviewEntryID: UUID?
    @State private var windowFrameBeforePreview: NSRect?
    @State private var previewWindowNumber: Int?
    @State private var previewWindowRestorationGate = ArchivePreviewWindowRestorationGate()
    @AppStorage(ArchiveEntryPreviewSettings.sidebarEnabledKey) private var previewSidebarEnabled = true
    @AppStorage(ArchiveEntryPreviewSettings.triggerKey) private var previewTrigger = "single"
    @AppStorage(ArchiveEntryPreviewSettings.sidebarWidthKey) private var previewSidebarWidth = ArchiveEntryPreviewSettings.defaultSidebarWidth

    init(viewModel: ArchiveViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _entryPreviewModel = StateObject(wrappedValue: ArchiveEntryPreviewModel(
            identityStore: viewModel.identityStore,
            onProtectionFailure: { [weak viewModel] event in
                viewModel?.handleEntryPreviewProtectionFailure(
                    event.failure.error,
                    allowsPrivateKeyRecovery: event.allowsPrivateKeyRecovery,
                    retryAfterRestore: event.retryAfterPrivateKeyRestore
                )
            }
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 头部
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.zwzPink.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "doc.zippressor")
                        .font(.system(size: 16))
                        .foregroundColor(.zwzPink)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.archiveName)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 7) {
                        if let format = viewModel.detectedFormat {
                            Text(format.displayName)
                                .font(.system(size: 11))
                                .foregroundColor(.zwzPink)
                        }
                        if let signature = viewModel.signatureBadge {
                            ZWZArchiveSignatureBadge(signature: signature)
                        }
                    }
                }

                Spacer()

                Toggle(isOn: $viewModel.showHiddenFiles) {
                    Image(systemName: viewModel.showHiddenFiles ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .foregroundColor(viewModel.showHiddenFiles ? .zwzBlue : .secondary)
                .help(viewModel.showHiddenFiles ? "隐藏隐藏文件" : "显示隐藏文件")

                if viewModel.detectedFormat == .zwz {
                    Button {
                        if virtualDisk.session != nil {
                            virtualDisk.requestUnmount()
                        } else {
                            let bytes = viewModel.previewEntries.reduce(UInt64(0)) { $0 + UInt64(max(0, viewModel.displaySize(for: $1))) }
                            capacityMB = VirtualDiskManager.recommendedCapacityMB(uncompressedBytes: bytes)
                            showMountOptions = true
                        }
                    } label: {
                        Image(systemName: virtualDisk.session == nil ? "externaldrive.badge.plus" : "eject.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.zwzBlue)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(virtualDisk.session == nil && !viewModel.canOpenArchiveContent)
                    .help(virtualDisk.session == nil
                        ? SettingsStrings.text("挂载为虚拟磁盘", "Mount as Virtual Disk")
                        : SettingsStrings.text("卸载虚拟磁盘", "Unmount Virtual Disk"))
                }

                if viewModel.isEditableArchive {
                    Button {
                        viewModel.beginArchiveEditing()
                    } label: {
                        Image(systemName: "pencil.and.list.clipboard")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.zwzBlue)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canOpenArchiveContent)
                    .help("编辑压缩包")
                }

                ZWZGradientButton(
                    icon: "wand.and.stars",
                    title: L.string("smart_extract"),
                    gradient: .zwzBlueGradient
                ) {
                    viewModel.performSmartExtract()
                }
                .disabled(viewModel.isProcessing || !viewModel.canOpenArchiveContent)

                // 解压按钮（粉色渐变）
                ZWZGradientButton(
                    icon: "arrow.down.doc.fill",
                    title: "解压",
                    gradient: .zwzPinkGradient
                ) {
                    viewModel.password = ""
                    viewModel.showExtractOptions = true
                }
                .disabled(!viewModel.canOpenArchiveContent)

                // 关闭
                ZWZIconButton(icon: "xmark") {
                    viewModel.clearPreview()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)

            Divider()

            // 面包屑
            HStack(spacing: 4) {
                ForEach(Array(viewModel.breadcrumbParts.enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    Button {
                        if part.path.isEmpty {
                            viewModel.goToRoot()
                        } else {
                            viewModel.currentDir = part.path
                            viewModel.selectedEntryId = nil
                            viewModel.updateFilteredEntries()
                        }
                    } label: {
                        Text(part.name)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(index == viewModel.breadcrumbParts.count - 1 ? .primary : .zwzBlue)
                            .padding(.horizontal, 4)
                            .frame(minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    TextField(L.string("search_archive_contents"), text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .rounded))

                    if !viewModel.searchQuery.isEmpty {
                        Button {
                            viewModel.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L.string("close"))
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(width: 220)
                .background(Color.secondary.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    archiveEntryList
                    archiveFooter
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isPreviewSidebarPresented {
                    ZWZArchiveEntryPreviewPane(
                        model: entryPreviewModel,
                        formattedSize: entryPreviewModel.currentEntry.map {
                            viewModel.formatBytes($0.size)
                        } ?? "",
                        onClose: closeEntryPreview
                    )
                    .frame(width: CGFloat(effectivePreviewSidebarWidth))
                    .frame(maxHeight: .infinity)
                }
            }
            .id(isPreviewSidebarPresented)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.selectedEntryId) { _, selectedEntryID in
            handlePreviewSelectionChange(selectedEntryID)
        }
        .onChange(of: previewSidebarEnabled) { _, enabled in
            if enabled {
                handlePreviewSelectionChange(viewModel.selectedEntryId)
            } else {
                closeEntryPreview()
            }
        }
        .onChange(of: previewTrigger) { _, _ in
            handlePreviewSelectionChange(viewModel.selectedEntryId)
        }
        .onChange(of: viewModel.canOpenArchiveContent) { _, canOpen in
            if !canOpen {
                hideEntryPreview()
            }
        }
        .onDisappear {
            hideEntryPreview()
        }
        .onAppear {
            normalizePreviewSidebarWidth()
        }
        .sheet(isPresented: $showMountOptions, onDismiss: {
            guard presentRecoveryAfterMountDismiss else { return }
            presentRecoveryAfterMountDismiss = false
            guard !viewModel.missingPrivateKeyRecipients.isEmpty else { return }
            DispatchQueue.main.async {
                viewModel.showMissingPrivateKeyPrompt = true
            }
        }) {
            VirtualDiskMountOptionsView(
                viewModel: viewModel,
                capacityMB: $capacityMB,
                minimumCapacityMB: VirtualDiskManager.recommendedCapacityMB(
                    uncompressedBytes: viewModel.previewEntries.reduce(UInt64(0)) { $0 + UInt64(max(0, viewModel.displaySize(for: $1))) }
                ),
                onPrivateKeyRecoveryRequired: {
                    presentRecoveryAfterMountDismiss = true
                    viewModel.showMissingPrivateKeyPrompt = false
                }
            )
        }
    }

    @ViewBuilder
    private var archiveEntryList: some View {
        if viewModel.isSearching && viewModel.previewEntries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.secondary)
                Text(L.string("no_search_results"))
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(viewModel.previewEntries, selection: $viewModel.selectedEntryId) { entry in
                HStack(spacing: 12) {
                    if entry.isDirectory {
                        Button {
                            viewModel.openEntry(entry: entry)
                        } label: {
                            Image(systemName: ArchiveEntryPresentation.iconName(forFileNamed: entry.name, isDirectory: true))
                                .foregroundColor(.zwzPink)
                                .font(.system(size: 16))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!viewModel.canOpenArchiveContent)
                    } else {
                        Image(systemName: ArchiveEntryPresentation.iconName(forFileNamed: entry.name, isDirectory: false))
                            .foregroundColor(.zwzBlue)
                            .font(.system(size: 16))
                    }

                    if entry.isDirectory {
                        Button {
                            viewModel.openEntry(entry: entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(.system(size: 14, design: .rounded))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(entry.path)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!viewModel.canOpenArchiveContent)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.system(size: 14, design: .rounded))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(entry.path)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer()

                    if viewModel.selectedEntryId == entry.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.zwzBlue)
                            .font(.system(size: 12))
                    }

                    if entry.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundColor(.zwzBlue)
                    }

                    Text(viewModel.formatBytes(viewModel.displaySize(for: entry)))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.secondary)
                        .monospacedDigit()

                    if let date = entry.modifiedDate {
                        Text(viewModel.formatDate(date))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard viewModel.canOpenArchiveContent else { return }
                    closedPreviewEntryID = nil
                    viewModel.selectedEntryId = entry.id
                }
                .onTapGesture(count: 2) {
                    guard viewModel.canOpenArchiveContent else { return }
                    closedPreviewEntryID = nil
                    viewModel.selectedEntryId = entry.id
                    if entry.isDirectory || previewTrigger == "single" {
                        viewModel.openEntry(entry: entry)
                    } else {
                        updateEntryPreview(selectedEntryID: entry.id)
                    }
                }
                .onDrag {
                    guard viewModel.canOpenArchiveContent else {
                        return NSItemProvider()
                    }
                    let tempURL = viewModel.extractEntryForDrag(entry: entry)
                    return NSItemProvider(contentsOf: tempURL) ?? NSItemProvider()
                }
            }
        }
    }

    private var archiveFooter: some View {
        HStack(spacing: 16) {
            Text(L.string("total_items", viewModel.previewEntries.count))
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(.secondary)

            Spacer()

            Text(L.string("total_size", viewModel.formatBytes(viewModel.previewEntries.reduce(0) { $0 + viewModel.displaySize(for: $1) })))
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func updateEntryPreview(selectedEntryID: UUID?) {
        guard viewModel.canOpenArchiveContent,
              let selectedEntryID,
              previewSidebarEnabled,
              selectedEntryID != closedPreviewEntryID,
              let entry = viewModel.previewEntries.first(where: { $0.id == selectedEntryID }),
              !entry.isDirectory,
              let archivePath = viewModel.sourcePath else {
            hideEntryPreview()
            return
        }

        captureWindowFrameBeforePreviewIfNeeded()
        isPreviewSidebarPresented = true
        entryPreviewModel.preview(
            archivePath: archivePath,
            entry: entry,
            password: viewModel.password
        )
    }

    private func handlePreviewSelectionChange(_ selectedEntryID: UUID?) {
        if let selectedEntryID, selectedEntryID != closedPreviewEntryID {
            closedPreviewEntryID = nil
        }

        guard previewSidebarEnabled, previewTrigger == "single" else {
            if entryPreviewModel.currentEntry?.id != selectedEntryID {
                hideEntryPreview()
            }
            return
        }
        updateEntryPreview(selectedEntryID: selectedEntryID)
    }

    private func closeEntryPreview() {
        closedPreviewEntryID = entryPreviewModel.currentEntry?.id
        hideEntryPreview()
        viewModel.selectedEntryId = nil
    }

    private func hideEntryPreview() {
        let frameToRestore = windowFrameBeforePreview
        let windowNumber = previewWindowNumber

        isPreviewSidebarPresented = false
        entryPreviewModel.clear()

        guard let frameToRestore, let windowNumber else { return }
        let restorationToken = previewWindowRestorationGate.beginRestoration()
        DispatchQueue.main.async {
            // Let the HSplitView finish removing the preview column first.
            DispatchQueue.main.async {
                guard previewWindowRestorationGate.accepts(restorationToken) else {
                    return
                }
                guard let window = NSApp.windows.first(where: { $0.windowNumber == windowNumber }) else {
                    windowFrameBeforePreview = nil
                    previewWindowNumber = nil
                    return
                }
                let contentSize = window.contentRect(forFrameRect: frameToRestore).size
                window.setFrame(frameToRestore, display: true, animate: true)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    guard previewWindowRestorationGate.accepts(restorationToken) else { return }
                    window.setContentSize(contentSize)
                    window.setFrameOrigin(frameToRestore.origin)
                    window.contentView?.setFrameSize(contentSize)
                    window.contentView?.invalidateIntrinsicContentSize()
                    window.contentView?.needsLayout = true
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.contentView?.displayIfNeeded()
                    windowFrameBeforePreview = nil
                    previewWindowNumber = nil
                }
            }
        }
    }

    private func captureWindowFrameBeforePreviewIfNeeded() {
        previewWindowRestorationGate.invalidateForPreviewOpen()
        if isPreviewSidebarPresented { return }
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow,
              window.title == "ZwZ" else {
            return
        }
        let baselineFrame: NSRect
        if let existingFrame = windowFrameBeforePreview,
           previewWindowNumber == window.windowNumber {
            baselineFrame = existingFrame
        } else {
            baselineFrame = window.frame
            windowFrameBeforePreview = baselineFrame
            previewWindowNumber = window.windowNumber
        }

        let sidebarWidth = CGFloat(effectivePreviewSidebarWidth)
        var expandedFrame = baselineFrame
        expandedFrame.size.width += sidebarWidth

        if let visibleFrame = window.screen?.visibleFrame {
            expandedFrame.size.width = min(expandedFrame.width, visibleFrame.width)
            expandedFrame.origin.x = min(
                max(expandedFrame.origin.x, visibleFrame.minX),
                visibleFrame.maxX - expandedFrame.width
            )
        }
        window.setFrame(expandedFrame, display: true, animate: true)
    }


    private var effectivePreviewSidebarWidth: Double {
        guard previewSidebarWidth <= ArchiveEntryPreviewSettings.maximumSidebarWidth else {
            return ArchiveEntryPreviewSettings.defaultSidebarWidth
        }
        return max(previewSidebarWidth, ArchiveEntryPreviewSettings.minimumSidebarWidth)
    }

    private func normalizePreviewSidebarWidth() {
        if previewSidebarWidth > ArchiveEntryPreviewSettings.maximumSidebarWidth {
            previewSidebarWidth = ArchiveEntryPreviewSettings.defaultSidebarWidth
        } else if previewSidebarWidth < ArchiveEntryPreviewSettings.minimumSidebarWidth {
            previewSidebarWidth = ArchiveEntryPreviewSettings.minimumSidebarWidth
        }
    }
}

private struct ZWZArchiveSignatureBadge: View {
    let signature: ZwzSignatureVerification

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 170, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .help(helpText)
    }

    private var title: String {
        switch signature {
        case .unsigned:
            return SettingsStrings.text("未签名", "Unsigned")
        case .validKnownSigner(let name, _):
            return name.isEmpty
                ? SettingsStrings.text("签名有效", "Valid Signature")
                : SettingsStrings.text("签名有效 · \(name)", "Valid · \(name)")
        case .validUnknownSigner:
            return SettingsStrings.text("签名有效 · 未知签名者", "Valid · Unknown Signer")
        case .invalid:
            return SettingsStrings.text("签名无效", "Invalid Signature")
        }
    }

    private var icon: String {
        switch signature {
        case .unsigned: return "pencil.slash"
        case .validKnownSigner: return "checkmark.seal.fill"
        case .validUnknownSigner: return "questionmark.diamond.fill"
        case .invalid: return "xmark.seal.fill"
        }
    }

    private var color: Color {
        switch signature {
        case .unsigned: return .secondary
        case .validKnownSigner: return .green
        case .validUnknownSigner: return .zwzOrange
        case .invalid: return .red
        }
    }

    private var helpText: String {
        switch signature {
        case .unsigned:
            return SettingsStrings.text("此归档没有签名。", "This archive is not signed.")
        case .validKnownSigner(let name, let fingerprint):
            return "\(name)\n\(fingerprint)"
        case .validUnknownSigner(let name, let fingerprint):
            return "\(SettingsStrings.text("未知签名者", "Unknown signer")): \(name)\n\(fingerprint)"
        case .invalid:
            return SettingsStrings.text("签名验证失败，内容操作已禁用。", "Signature verification failed; content actions are disabled.")
        }
    }
}

struct VirtualDiskMountOptionsView: View {
    @ObservedObject var viewModel: ArchiveViewModel
    @Binding var capacityMB: Int
    let minimumCapacityMB: Int
    let onPrivateKeyRecoveryRequired: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("zwz_mount_open_finder") private var openFinder = true
    @State private var errorMessage: String?
    @State private var isMounting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(SettingsStrings.text("挂载虚拟磁盘", "Mount Virtual Disk"))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(SettingsStrings.text("磁盘容量", "Disk Capacity"))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
            Stepper("\(capacityMB) MB", value: $capacityMB, in: minimumCapacityMB...1_048_576, step: 256)
                .monospacedDigit()
            Text(SettingsStrings.text("最小容量：\(minimumCapacityMB) MB", "Minimum: \(minimumCapacityMB) MB"))
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.secondary)
            if let errorMessage {
                Text(errorMessage).foregroundColor(.red).font(.system(size: 12))
            }
            Spacer()
            HStack {
                Button(L.string("cancel")) { dismiss() }
                    .zwzSheetButtonStyle(.secondary)
                Spacer()
                Button(SettingsStrings.text("挂载", "Mount")) {
                    isMounting = true
                    Task {
                        await viewModel.mountArchive(capacityMB: capacityMB)
                        if viewModel.showMissingPrivateKeyPrompt {
                            onPrivateKeyRecoveryRequired()
                            dismiss()
                            return
                        }
                        if let message = viewModel.errorMessage {
                            errorMessage = message
                            viewModel.errorMessage = nil
                            isMounting = false
                            return
                        }
                        guard let session = VirtualDiskManager.shared.session else {
                            errorMessage = SettingsStrings.text("无法挂载虚拟磁盘。", "Unable to mount the virtual disk.")
                            isMounting = false
                            return
                        }
                        if openFinder {
                            NSWorkspace.shared.open(URL(fileURLWithPath: session.mountPath))
                        }
                        dismiss()
                    }
                }
                .zwzSheetButtonStyle(.primary)
                .disabled(isMounting || !viewModel.canOpenArchiveContent)
            }
        }
        .padding(24)
        .frame(width: 420, height: 280)
        .background(LinearGradient.zwzBackground.opacity(0.5))
    }
}

// MARK: - Compress Options Sheet

struct ZWZCompressOptionsView: View {
    @ObservedObject var viewModel: ArchiveViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // 标题行
            HStack {
                ZStack {
                    Circle()
                        .fill(Color.zwzBlue.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 16))
                        .foregroundColor(.zwzBlue)
                }
                Text(L.string("compress_settings"))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Spacer()
            }
            .padding(.top, 24)

            // 源文件
            ZWZSheetSection(title: L.string("source_file")) {
                Text(viewModel.sourcePath ?? "")
                    .font(.system(size: 13, design: .rounded))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.zwzCardBg.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // 输出格式
            ZWZSheetSection(title: "输出格式") {
                Picker("输出格式", selection: $viewModel.compressFormat) {
                    ForEach(CompressionFormat.allCases, id: \.self) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)
            }

            // 压缩等级
            ZWZSheetSection(title: L.string("compress_level")) {
                Picker("压缩等级", selection: $viewModel.compressLevel) {
                    ForEach(CompressionLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
            }

            ZWZSheetSection(title: SettingsStrings.text("加密方式", "Encryption")) {
                Picker(
                    SettingsStrings.text("加密方式", "Encryption"),
                    selection: encryptionModeBinding
                ) {
                    Text(SettingsStrings.text("不加密", "None"))
                        .tag(EncryptionModeSelection.none)
                    Text(SettingsStrings.text("密码", "Password"))
                        .tag(EncryptionModeSelection.password)
                    Text(SettingsStrings.text("公钥", "Public Key"))
                        .tag(EncryptionModeSelection.publicKey)
                        .disabled(viewModel.compressFormat != .zwz)
                }
                .pickerStyle(.segmented)
            }

            encryptionConfiguration

            // 分卷
            ZWZSheetSection(title: L.string("split_size_optional")) {
                HStack {
                    TextField("例如: 100", text: $viewModel.splitSize)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14, design: .rounded))
                    Picker("", selection: $viewModel.splitUnit) {
                        Text("KB").tag("KB")
                        Text("MB").tag("MB")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
            }

            Spacer()

            // 按钮
            HStack(spacing: 12) {
                Button(L.string("cancel")) { dismiss() }
                    .zwzSheetButtonStyle(.secondary)
                Button(L.string("start_compress")) {
                    dismiss()
                    viewModel.performCompress()
                }
                .zwzSheetButtonStyle(.primary)
                .disabled(!viewModel.canStartCompression)
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
        .frame(width: 520, height: 680)
        .background(LinearGradient.zwzBackground.opacity(0.5))
        .task {
            try? await viewModel.refreshIdentityChoices()
        }
    }

    @ViewBuilder
    private var encryptionConfiguration: some View {
        switch viewModel.encryptionModeSelection {
        case .none:
            EmptyView()
        case .password:
            ZWZSheetSection(title: SettingsStrings.text("密码", "Password")) {
                SecureField(L.string("enter_password"), text: $viewModel.password)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, design: .rounded))

                if !viewModel.password.isEmpty {
                    ZWZPasswordStrengthView(strength: PasswordStrength.evaluate(viewModel.password))
                }
            }
        case .publicKey:
            ZWZSheetSection(title: SettingsStrings.text("接收方", "Recipients")) {
                if viewModel.availableRecipients.isEmpty {
                    Text(SettingsStrings.text("尚无可用的本地身份或公开联系人。", "No local identities or public contacts are available."))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(viewModel.availableRecipients, id: \.fingerprint) { recipient in
                                Toggle(isOn: recipientBinding(recipient.fingerprint)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(recipient.name)
                                            .font(.system(size: 12, weight: .medium, design: .rounded))
                                            .lineLimit(1)
                                        Text(shortFingerprint(recipient.fingerprint))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .toggleStyle(.checkbox)
                                .padding(.vertical, 6)
                                .help(recipient.fingerprint)

                                if recipient.fingerprint != viewModel.availableRecipients.last?.fingerprint {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(height: 116)
                }

                if viewModel.selectedRecipientFingerprints.isEmpty {
                    Text(SettingsStrings.text("至少选择一个接收方。", "Select at least one recipient."))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.red)
                }
            }

            ZWZSheetSection(title: SettingsStrings.text("签名者（可选）", "Signer (Optional)")) {
                Picker(
                    SettingsStrings.text("签名者", "Signer"),
                    selection: signerBinding
                ) {
                    Text(SettingsStrings.text("不签名", "Unsigned"))
                        .tag(nil as String?)
                    ForEach(viewModel.availableSigningIdentities, id: \.fingerprint) { identity in
                        Text(identity.name)
                            .tag(identity.fingerprint as String?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var encryptionModeBinding: Binding<EncryptionModeSelection> {
        Binding(
            get: { viewModel.encryptionModeSelection },
            set: { viewModel.selectEncryptionMode($0) }
        )
    }

    private var signerBinding: Binding<String?> {
        Binding(
            get: { viewModel.selectedSignerFingerprint },
            set: { viewModel.selectedSignerFingerprint = $0 }
        )
    }

    private func recipientBinding(_ fingerprint: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedRecipientFingerprints.contains(fingerprint) },
            set: { isSelected in
                if isSelected {
                    viewModel.selectedRecipientFingerprints.insert(fingerprint)
                } else {
                    viewModel.selectedRecipientFingerprints.remove(fingerprint)
                }
            }
        )
    }

    private func shortFingerprint(_ fingerprint: String) -> String {
        guard fingerprint.count > 24 else { return fingerprint }
        return "\(fingerprint.prefix(16))...\(fingerprint.suffix(8))"
    }
}

// MARK: - Extract Options Sheet

struct ZWZExtractOptionsView: View {
    @ObservedObject var viewModel: ArchiveViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // 标题
            HStack {
                ZStack {
                    Circle()
                        .fill(Color.zwzPink.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.zwzPink)
                }
                Text(L.string("extract_settings"))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Spacer()
            }
            .padding(.top, 24)

            ZWZSheetSection(title: L.string("archive")) {
                Text(viewModel.sourcePath ?? "")
                    .font(.system(size: 13, design: .rounded))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.zwzCardBg.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let format = viewModel.detectedFormat {
                ZWZSheetSection(title: "检测到的格式") {
                    Text(format.displayName)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(.zwzPink)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.zwzPink.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            ZWZSheetSection(title: L.string("password_if_needed")) {
                SecureField(L.string("enter_password"), text: $viewModel.password)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, design: .rounded))
            }

            Spacer()

            HStack(spacing: 12) {
                Button(L.string("cancel")) { dismiss() }
                    .zwzSheetButtonStyle(.secondary)
                Button(L.string("start_extract")) {
                    dismiss()
                    viewModel.performExtract()
                }
                .zwzSheetButtonStyle(.pink)
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
        .frame(width: 500, height: 440)
        .background(LinearGradient.zwzBackground.opacity(0.5))
    }
}

// MARK: - Sheet Helper Views

struct ZWZSheetSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
            content
        }
    }
}

// MARK: - Sheet Button Style

struct ZWZSheetButtonStyle: ButtonStyle {
    enum Style { case primary, secondary, pink }
    let style: Style
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(backgroundColor)
            .foregroundColor(foregroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: shadowColor, radius: 4, x: 0, y: 2)
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var backgroundColor: AnyView {
        switch style {
        case .primary:
            return AnyView(LinearGradient.zwzBlueGradient)
        case .pink:
            return AnyView(LinearGradient.zwzPinkGradient)
        case .secondary:
            return AnyView(Color.gray.opacity(0.12))
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary, .pink: return .white
        case .secondary: return .primary
        }
    }

    private var shadowColor: Color {
        switch style {
        case .primary: return Color.zwzBlue.opacity(0.25)
        case .pink: return Color.zwzPink.opacity(0.25)
        case .secondary: return .black.opacity(0.06)
        }
    }
}

extension View {
    func zwzSheetButtonStyle(_ style: ZWZSheetButtonStyle.Style) -> some View {
        buttonStyle(ZWZSheetButtonStyle(style: style))
    }
}

// MARK: - Password Strength View

struct ZWZPasswordStrengthView: View {
    let strength: PasswordStrength

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < strength.score ? strengthColor : Color.gray.opacity(0.15))
                    .frame(height: 4)
            }
            Text(strength.displayName)
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(strengthColor)
        }
    }

    private var strengthColor: Color {
        switch strength {
        case .none: return .gray
        case .weak: return .red
        case .medium: return .zwzOrange
        case .strong: return .zwzBlue
        case .veryStrong: return .zwzGreen
        }
    }
}

// MARK: - Status Bar (只留版本号)

struct ZWZStatusBar: View {
    var body: some View {
        HStack {
            Spacer()
            Text("zwz v1.0")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.secondary.opacity(0.4))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }
}

// MARK: - Settings View

enum SettingsStrings {
    @MainActor static func text(_ zh: String, _ en: String) -> String {
        LanguageManager.shared.currentLanguage == "zh" ? zh : en
    }
}

struct ZWZSettingsView: View {
    @State private var selectedTab: SettingsTab = .compression
    @ObservedObject private var languageManager = LanguageManager.shared

    enum SettingsTab: String, CaseIterable {
        case workspace, compression, preview, keys, passwords, threading, history, fileAssociations, appearance
        var icon: String {
            switch self {
            case .workspace:   "rectangle.3.group"
            case .compression: "doc.badge.plus"
            case .preview:     "eye"
            case .keys:        "key.horizontal"
            case .passwords:   "key.fill"
            case .threading:   "cpu"
            case .history:     "clock.arrow.circlepath"
            case .fileAssociations: "doc.badge.gearshape"
            case .appearance:  "paintbrush"
            }
        }
        @MainActor var title: String {
            switch self {
            case .workspace:   SettingsStrings.text("工作区", "Workspace")
            case .compression: SettingsStrings.text("压缩默认", "Compression")
            case .preview:     SettingsStrings.text("预览", "Preview")
            case .keys:        SettingsStrings.text("公私钥", "Keys")
            case .passwords:   SettingsStrings.text("密码管理", "Passwords")
            case .threading:   SettingsStrings.text("多线程", "Threads")
            case .history:     SettingsStrings.text("历史记录", "History")
            case .fileAssociations: SettingsStrings.text("文件关联", "File Associations")
            case .appearance:  SettingsStrings.text("外观", "Appearance")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // 侧边栏
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        ZWZLogoView(size: 38)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("zwz")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(LinearGradient.zwzBluePink)
                            Text(SettingsStrings.text("设置", "Settings"))
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 14)

                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 15))
                                    .frame(width: 20)
                                Text(tab.title)
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                Spacer()
                            }
                            .foregroundColor(selectedTab == tab ? .zwzBlue : .secondary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                selectedTab == tab
                                    ? Color.zwzBlue.opacity(0.1)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .frame(width: 180)
                .padding(.top, 16)
                .padding(.horizontal, 12)
                .background(.ultraThinMaterial)

                Divider()

                // 内容区
                Group {
                    switch selectedTab {
                    case .workspace:   WorkspaceSettingsView()
                    case .compression: CompressionSettingsView()
                    case .preview:     PreviewSettingsView()
                    case .keys:        IdentityManagerView()
                    case .passwords:   PasswordManagerSettingsView()
                    case .threading:   ThreadingSettingsView()
                    case .history:     HistorySettingsView()
                    case .fileAssociations: FileAssociationSettingsView()
                    case .appearance:  AppearanceSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(28)
            }
        }
        .frame(width: 640, height: 480)
    }
}

struct PasswordManagerSettingsView: View {
    @AppStorage(ArchivePasswordVault.rememberEnabledKey) private var memoryEnabled = false
    @AppStorage(ArchivePasswordVault.useKeychainKey) private var useKeychain = false
    @AppStorage(ArchivePasswordVault.migrateOnChangeKey) private var migrateOnChange = false
    @ObservedObject private var vault = ArchivePasswordVault.shared
    @State private var selectedStorage: ArchivePasswordStorage = .local
    @State private var shownPasswords: Set<String> = []
    @State private var revealedPasswords: [String: String] = [:]
    @State private var masterPassword = ""
    @State private var newMasterPassword = ""
    @State private var confirmMasterPassword = ""
    @State private var errorMessage: String?
    @State private var showResetConfirmation = false
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(SettingsStrings.text("密码管理", "Password Manager"))
                .font(.system(size: 18, weight: .semibold, design: .rounded))

            Toggle(SettingsStrings.text("启用密码记忆", "Enable password memory"), isOn: $memoryEnabled)
                .toggleStyle(.switch)

            if memoryEnabled {
                SettingsRow(title: SettingsStrings.text("保存位置", "Storage")) {
                    Picker("", selection: $useKeychain) {
                        Text(SettingsStrings.text("本地加密密码库", "Local encrypted vault")).tag(false)
                        Text(SettingsStrings.text("macOS 钥匙串", "macOS Keychain")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: useKeychain) { oldValue, newValue in
                        guard migrateOnChange else { return }
                        migrate(from: oldValue ? .local : .keychain, to: newValue ? .keychain : .local)
                    }
                }

                Toggle(SettingsStrings.text("切换保存位置时迁移已有密码", "Migrate existing passwords when changing storage"), isOn: $migrateOnChange)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12, design: .rounded))

                if !useKeychain && !vault.isUnlocked {
                    localUnlockControls
                }

                Picker("", selection: $selectedStorage) {
                    Text(SettingsStrings.text("本地密码库", "Local Vault")).tag(ArchivePasswordStorage.local)
                    Text(SettingsStrings.text("钥匙串", "Keychain")).tag(ArchivePasswordStorage.keychain)
                }
                .pickerStyle(.segmented)

                passwordRecords

                HStack {
                    Button(SettingsStrings.text("清空当前列表", "Clear Current List"), role: .destructive) {
                        showClearConfirmation = true
                    }
                    .disabled(selectedStorage == .local && !vault.isUnlocked)
                    if selectedStorage == .local {
                        Button(SettingsStrings.text("重置本地密码库", "Reset Local Vault"), role: .destructive) {
                            showResetConfirmation = true
                        }
                    }
                    Spacer()
                    if vault.isUnlocked && selectedStorage == .local {
                        Button(SettingsStrings.text("锁定", "Lock")) { vault.lock() }
                    }
                }
                .font(.system(size: 12, design: .rounded))
            }

            Spacer()
        }
        .alert(SettingsStrings.text("确认清空密码记录？", "Clear saved password records?"), isPresented: $showClearConfirmation) {
            Button(SettingsStrings.text("清空", "Clear"), role: .destructive) { clearSelectedStorage() }
            Button(L.string("cancel"), role: .cancel) {}
        }
        .alert(SettingsStrings.text("重置本地密码库？", "Reset local password vault?"), isPresented: $showResetConfirmation) {
            Button(SettingsStrings.text("重置", "Reset"), role: .destructive) {
                try? vault.resetLocalVault()
                revealedPasswords = [:]
            }
            Button(L.string("cancel"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private var localUnlockControls: some View {
        if vault.isConfigured {
            SettingsRow(title: SettingsStrings.text("解锁本地密码库", "Unlock Local Vault")) {
                HStack {
                    SecureField(SettingsStrings.text("主密码", "Master Password"), text: $masterPassword)
                        .textFieldStyle(.roundedBorder)
                    Button(SettingsStrings.text("解锁", "Unlock")) {
                        do {
                            try vault.unlock(masterPassword: masterPassword)
                            errorMessage = nil
                            masterPassword = ""
                        } catch { errorMessage = SettingsStrings.text("主密码不正确。", "Incorrect master password.") }
                    }
                }
            }
        } else {
            SettingsRow(title: SettingsStrings.text("创建本地密码库", "Create Local Vault")) {
                SecureField(SettingsStrings.text("主密码", "Master Password"), text: $newMasterPassword)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    SecureField(SettingsStrings.text("确认主密码", "Confirm Master Password"), text: $confirmMasterPassword)
                        .textFieldStyle(.roundedBorder)
                    Button(SettingsStrings.text("创建", "Create")) {
                        do {
                            guard newMasterPassword == confirmMasterPassword else {
                                errorMessage = SettingsStrings.text("两次输入的主密码不一致。", "Master passwords do not match.")
                                return
                            }
                            try vault.configure(masterPassword: newMasterPassword)
                            newMasterPassword = ""
                            confirmMasterPassword = ""
                            errorMessage = nil
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(newMasterPassword.isEmpty || confirmMasterPassword.isEmpty)
                }
            }
        }
        if let errorMessage {
            Text(errorMessage).font(.system(size: 11)).foregroundColor(.red)
        }
    }

    private var passwordRecords: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                let records = vault.records(for: selectedStorage)
                if records.isEmpty {
                    Text(SettingsStrings.text("没有保存的密码", "No saved passwords"))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90)
                }
                ForEach(records) { record in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.zipper").foregroundColor(.zwzPink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.archiveName).font(.system(size: 12, weight: .medium, design: .rounded)).lineLimit(1)
                            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10, design: .rounded)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(shownPasswords.contains(record.id) ? (revealedPasswords[record.id] ?? "••••••••") : "••••••••")
                            .font(.system(size: 12, design: .monospaced))
                        Button {
                            togglePassword(record)
                        } label: {
                            Image(systemName: shownPasswords.contains(record.id) ? "eye.slash" : "eye")
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            copyPassword(record)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button(role: .destructive) { delete(record) } label: {
                            Image(systemName: "trash")
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
        }
        .frame(maxHeight: 165)
    }

    private func password(for record: SavedArchivePassword) -> String? {
        try? vault.password(for: record.fingerprint, storage: selectedStorage)
    }

    private func togglePassword(_ record: SavedArchivePassword) {
        if shownPasswords.contains(record.id) {
            shownPasswords.remove(record.id)
            revealedPasswords.removeValue(forKey: record.id)
        } else if let password = password(for: record) {
            revealedPasswords[record.id] = password
            shownPasswords.insert(record.id)
        }
    }

    private func copyPassword(_ record: SavedArchivePassword) {
        if let password = password(for: record) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(password, forType: .string) }
    }

    private func delete(_ record: SavedArchivePassword) {
        try? vault.remove(fingerprint: record.fingerprint, storage: selectedStorage)
        shownPasswords.remove(record.id)
        revealedPasswords.removeValue(forKey: record.id)
    }

    private func clearSelectedStorage() {
        try? vault.clear(storage: selectedStorage)
        shownPasswords = []
        revealedPasswords = [:]
    }

    private func migrate(from source: ArchivePasswordStorage, to destination: ArchivePasswordStorage) {
        do { try vault.migrate(from: source, to: destination) }
        catch { errorMessage = error.localizedDescription }
    }
}

struct WorkspaceSettingsView: View {
    @AppStorage(WorkspaceSettings.restoreTabsKey) private var restoreTabs = false
    @AppStorage(WorkspaceSettings.cancelledArtifactPolicyKey) private var policy = IncompleteArtifactPolicy.delete.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(SettingsStrings.text("工作区设置", "Workspace Settings"))
                .font(.title2.bold())
            Toggle(SettingsStrings.text("重新打开上次的标签页", "Restore tabs from the previous session"), isOn: $restoreTabs)
            SettingsRow(title: SettingsStrings.text("取消任务后的文件", "Cancelled task output")) {
                Picker("", selection: $policy) {
                    Text(SettingsStrings.text("删除", "Delete")).tag(IncompleteArtifactPolicy.delete.rawValue)
                    Text(SettingsStrings.text("保留为 .partial", "Preserve as .partial")).tag(IncompleteArtifactPolicy.preservePartial.rawValue)
                    Text(SettingsStrings.text("每次询问", "Ask every time")).tag(IncompleteArtifactPolicy.ask.rawValue)
                }
                .labelsHidden()
            }
            Spacer()
        }
    }
}

// MARK: - Compression Defaults

struct CompressionSettingsView: View {
    @AppStorage("zwz_default_format") private var format = "zip"
    @AppStorage("zwz_default_level") private var level = "normal"
    @AppStorage("zwz_default_password") private var password = ""
    @AppStorage("zwz_default_output_dir") private var outputDir = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(SettingsStrings.text("压缩默认设置", "Compression Defaults"))
                .font(.system(size: 18, weight: .semibold, design: .rounded))

            SettingsRow(title: SettingsStrings.text("默认格式", "Default Format")) {
                Picker("", selection: $format) {
                    Text("ZIP").tag("zip")
                    Text("ZWZ").tag("zwz")
                }.pickerStyle(.segmented).frame(width: 200)
            }

            SettingsRow(title: SettingsStrings.text("默认压缩等级", "Default Compression Level")) {
                Picker("", selection: $level) {
                    Text(SettingsStrings.text("最快", "Fastest")).tag("fastest")
                    Text(SettingsStrings.text("标准", "Normal")).tag("normal")
                    Text(SettingsStrings.text("最大", "Maximum")).tag("max")
                }.pickerStyle(.segmented).frame(width: 300)
            }

            SettingsRow(title: SettingsStrings.text("默认密码", "Default Password")) {
                SecureField(SettingsStrings.text("（留空则不设密码）", "Leave empty for no password"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .rounded))
                    .frame(width: 260)
            }

            SettingsRow(title: SettingsStrings.text("默认输出目录", "Default Output Folder")) {
                HStack(spacing: 8) {
                    Text(outputDir.isEmpty ? SettingsStrings.text("（与源文件相同）", "Same as source") : outputDir)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(outputDir.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .frame(width: 220, alignment: .leading)
                    Button(SettingsStrings.text("选择…", "Choose…")) { pickOutputDir() }
                        .font(.system(size: 12))
                }
            }

            Spacer()
        }
    }

    func pickOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择"
        if panel.runModal() == .OK {
            outputDir = panel.url?.path ?? ""
        }
    }
}

// MARK: - Preview

struct PreviewSettingsView: View {
    @AppStorage("zwz_preview_show_hidden") private var showHiddenFiles = false
    @AppStorage(ArchiveEntryPreviewSettings.sidebarEnabledKey) private var sidebarEnabled = true
    @AppStorage(ArchiveEntryPreviewSettings.triggerKey) private var previewTrigger = "single"
    @AppStorage(ArchiveEntryPreviewSettings.sidebarWidthKey) private var sidebarWidth = ArchiveEntryPreviewSettings.defaultSidebarWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(SettingsStrings.text("预览设置", "Preview Settings"))
                .font(.system(size: 18, weight: .semibold, design: .rounded))

            SettingsRow(title: SettingsStrings.text("侧栏预览", "Preview Sidebar")) {
                Toggle(
                    SettingsStrings.text("启用侧栏预览", "Enable preview sidebar"),
                    isOn: $sidebarEnabled
                )
                .toggleStyle(.switch)
                .font(.system(size: 13, design: .rounded))
            }

            SettingsRow(title: SettingsStrings.text("触发方式", "Preview Trigger")) {
                Picker("", selection: $previewTrigger) {
                    Text(SettingsStrings.text("单击", "Single Click")).tag("single")
                    Text(SettingsStrings.text("双击", "Double Click")).tag("double")
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .disabled(!sidebarEnabled)
            .opacity(sidebarEnabled ? 1 : 0.55)

            SettingsRow(
                title: SettingsStrings.text(
                    "侧栏宽度：\(Int(sidebarWidth)) px",
                    "Sidebar Width: \(Int(sidebarWidth)) px"
                )
            ) {
                Slider(
                    value: $sidebarWidth,
                    in: ArchiveEntryPreviewSettings.minimumSidebarWidth...ArchiveEntryPreviewSettings.maximumSidebarWidth,
                    step: 20
                )
                    .frame(width: 280)
            }
            .disabled(!sidebarEnabled)
            .opacity(sidebarEnabled ? 1 : 0.55)

            Text(SettingsStrings.text(
                "侧栏宽度会记住最近一次调整；双击模式下，单击只选中文件。",
                "The sidebar width is remembered. In double-click mode, a single click only selects the file."
            ))
            .font(.system(size: 11, design: .rounded))
            .foregroundColor(.secondary)

            SettingsRow(title: SettingsStrings.text("隐藏文件", "Hidden Files")) {
                Toggle(SettingsStrings.text("显示隐藏文件", "Show hidden files"), isOn: $showHiddenFiles)
                    .toggleStyle(.switch)
                    .font(.system(size: 13, design: .rounded))
                    .frame(width: 220, alignment: .leading)
            }

            Text(SettingsStrings.text("关闭时，预览列表会隐藏以 . 开头的文件和文件夹。", "When disabled, files and folders beginning with . are hidden from previews."))
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.secondary)

            Spacer()
        }
    }
}

// MARK: - Threading

struct ThreadingSettingsView: View {
    @AppStorage("zwz_thread_mode") private var mode = "auto"
    @AppStorage("zwz_thread_count") private var count = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(SettingsStrings.text("多线程设置", "Thread Settings"))
                .font(.system(size: 18, weight: .semibold, design: .rounded))

            SettingsRow(title: SettingsStrings.text("线程模式", "Thread Mode")) {
                Picker("", selection: $mode) {
                    Text(SettingsStrings.text("自动", "Automatic")).tag("auto")
                    Text(SettingsStrings.text("手动", "Manual")).tag("manual")
                }.pickerStyle(.segmented).frame(width: 200)
            }

            if mode == "manual" {
                SettingsRow(title: SettingsStrings.text("线程数: \(count)", "Threads: \(count)")) {
                    Stepper("", value: $count, in: 1...64)
                        .frame(width: 120)
                }
            }

            Text(SettingsStrings.text("当前设备 CPU 核心数: \(ProcessInfo.processInfo.activeProcessorCount)", "CPU cores: \(ProcessInfo.processInfo.activeProcessorCount)"))
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.secondary)

            Text(SettingsStrings.text("多线程仅支持 ZIP 和 ZWZ 格式", "Multithreading is available for ZIP and ZWZ."))
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.secondary.opacity(0.5))

            Spacer()
        }
    }
}

// MARK: - History

struct HistorySettingsView: View {
    @AppStorage("zwz_history_limit") private var limit = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(SettingsStrings.text("历史记录", "History"))
                .font(.system(size: 18, weight: .semibold, design: .rounded))

            SettingsRow(title: SettingsStrings.text("最多保留记录数", "Maximum Records")) {
                Stepper(SettingsStrings.text("\(limit) 条", "\(limit) records"), value: $limit, in: 5...200, step: 5)
                    .font(.system(size: 13, design: .rounded))
                    .frame(width: 200)
            }
            .frame(height: 36)

            Text(SettingsStrings.text("设置为较小值可以节省内存；设置为较大值保留更久的使用记录。", "Smaller values use less memory; larger values retain history longer."))
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.secondary)

            Spacer()
        }
    }
}

// MARK: - File Associations

struct FileAssociationSettingsView: View {
    @ObservedObject private var manager = FileAssociationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(SettingsStrings.text("文件关联", "File Associations"))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Spacer()
                Toggle(SettingsStrings.text("全选", "Select All"), isOn: Binding(
                    get: { manager.allAssociated },
                    set: { manager.setAllAssociated($0) }
                ))
                .toggleStyle(.switch)
                .font(.system(size: 12, design: .rounded))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    associationGroup(.zwz, title: SettingsStrings.text("ZwZ 格式", "ZwZ Format"))
                    associationGroup(.common, title: SettingsStrings.text("常用压缩格式", "Common Archives"))
                    associationGroup(.other, title: SettingsStrings.text("其他压缩格式", "Other Archives"))
                }
            }

            if let message = manager.statusMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.zwzGreen)
                    .transition(.opacity)
            }
        }
        .onAppear { manager.refresh() }
        .alert(SettingsStrings.text("无法修改文件关联", "Could Not Change File Association"), isPresented: Binding(
            get: { manager.errorMessage != nil },
            set: { if !$0 { manager.errorMessage = nil } }
        )) {
            Button(SettingsStrings.text("好", "OK"), role: .cancel) { manager.errorMessage = nil }
        } message: {
            Text((manager.errorMessage ?? "") + "\n" + SettingsStrings.text(
                "你可以在 Finder 中选择文件，打开“显示简介”，再从“打开方式”中选择 ZwZ。",
                "In Finder, select a file, open Get Info, then choose ZwZ under Open with."
            ))
        }
    }

    private func associationGroup(_ category: ArchiveFileAssociation.Category, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)

            ForEach(ArchiveFileAssociation.all.filter { $0.category == category }) { association in
                Toggle(isOn: Binding(
                    get: { manager.associatedIDs.contains(association.id) },
                    set: { manager.setAssociated($0, for: association) }
                )) {
                    HStack {
                        Image(systemName: "doc.zipper")
                            .foregroundColor(category == .zwz ? .zwzPink : .zwzBlue)
                            .frame(width: 20)
                        Text(association.displayName)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                        Spacer()
                        Text(".\(association.filenameExtension)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(Color.zwzCardBg.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @AppStorage("zwz_appearance") private var appearance = "system"
    @AppStorage("zwz_mount_open_finder") private var openFinderAfterMount = true
    @ObservedObject private var languageManager = LanguageManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(SettingsStrings.text("外观设置", "Appearance Settings"))
                .font(.system(size: 18, weight: .semibold, design: .rounded))

            SettingsRow(title: SettingsStrings.text("主题模式", "Theme")) {
                Picker("", selection: $appearance) {
                    Text(SettingsStrings.text("跟随系统", "System")).tag("system")
                    Text(SettingsStrings.text("浅色", "Light")).tag("light")
                    Text(SettingsStrings.text("深色", "Dark")).tag("dark")
                }.pickerStyle(.segmented).frame(width: 340)
            }

            SettingsRow(title: SettingsStrings.text("语言", "Language")) {
                Picker("", selection: Binding(
                    get: { languageManager.currentLanguage },
                    set: { newValue in
                        DispatchQueue.main.async {
                            languageManager.setLanguage(newValue)
                        }
                    }
                )) {
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }.pickerStyle(.segmented).frame(width: 340)
            }

            SettingsRow(title: SettingsStrings.text("虚拟磁盘", "Virtual Disk")) {
                Toggle(SettingsStrings.text("挂载后在 Finder 中打开", "Open in Finder after mounting"), isOn: $openFinderAfterMount)
                    .toggleStyle(.switch)
            }

            Text(SettingsStrings.text("主题和语言会立即应用；跟随系统时主题会随 macOS 自动切换。", "Theme and language changes apply immediately. System theme follows macOS."))
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.secondary)

            Spacer()
        }
        .onChange(of: appearance) { _, newValue in
            AppearanceManager.shared.apply(newValue)
        }
    }
}

// MARK: - SettingsRow Helper

struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
            content
        }
    }
}

// MARK: - TextDocument (for fileExporter)

struct TextDocument: FileDocument {
    var text: String

    static var readableContentTypes: [UTType] { [.data] }

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) { text = "" }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}
