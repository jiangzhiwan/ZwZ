import AppKit
import Foundation
import ZwzCore

struct VirtualDiskSession: Codable, Equatable {
    var archivePath: String
    var imagePath: String
    var mountPath: String
    var capacityMB: Int
    var baselineFingerprint: String
    var splitVolumeBytes: Int64?
    var isMounted: Bool
    var ownerTabID: UUID? = nil
    var protection: ArchiveProtectionDescriptor? = nil

    private enum CodingKeys: String, CodingKey {
        case archivePath
        case imagePath
        case mountPath
        case password
        case capacityMB
        case baselineFingerprint
        case splitVolumeBytes
        case isMounted
        case ownerTabID
        case protection
    }

    init(
        archivePath: String,
        imagePath: String,
        mountPath: String,
        capacityMB: Int,
        baselineFingerprint: String,
        splitVolumeBytes: Int64?,
        isMounted: Bool,
        ownerTabID: UUID? = nil,
        protection: ArchiveProtectionDescriptor? = nil
    ) {
        self.archivePath = archivePath
        self.imagePath = imagePath
        self.mountPath = mountPath
        self.capacityMB = capacityMB
        self.baselineFingerprint = baselineFingerprint
        self.splitVolumeBytes = splitVolumeBytes
        self.isMounted = isMounted
        self.ownerTabID = ownerTabID
        self.protection = protection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        archivePath = try container.decode(String.self, forKey: .archivePath)
        imagePath = try container.decode(String.self, forKey: .imagePath)
        mountPath = try container.decode(String.self, forKey: .mountPath)
        capacityMB = try container.decode(Int.self, forKey: .capacityMB)
        baselineFingerprint = try container.decode(String.self, forKey: .baselineFingerprint)
        splitVolumeBytes = try container.decodeIfPresent(Int64.self, forKey: .splitVolumeBytes)
        isMounted = try container.decode(Bool.self, forKey: .isMounted)
        ownerTabID = try container.decodeIfPresent(UUID.self, forKey: .ownerTabID)
        protection = try container.decodeIfPresent(ArchiveProtectionDescriptor.self, forKey: .protection)

        let legacyPassword = try container.decodeIfPresent(String.self, forKey: .password)
        if protection == nil, legacyPassword?.isEmpty == false {
            protection = ArchiveProtectionDescriptor(securityInfo: ZwzArchiveSecurityInfo(
                encryption: .password
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(archivePath, forKey: .archivePath)
        try container.encode(imagePath, forKey: .imagePath)
        try container.encode(mountPath, forKey: .mountPath)
        try container.encode(capacityMB, forKey: .capacityMB)
        try container.encode(baselineFingerprint, forKey: .baselineFingerprint)
        try container.encodeIfPresent(splitVolumeBytes, forKey: .splitVolumeBytes)
        try container.encode(isMounted, forKey: .isMounted)
        try container.encodeIfPresent(ownerTabID, forKey: .ownerTabID)
        try container.encodeIfPresent(protection, forKey: .protection)
    }
}

enum VirtualDiskError: LocalizedError {
    case sessionAlreadyActive
    case noActiveSession
    case unsupportedArchive
    case commandFailed(String)
    case mountPointMissing

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive: return "A ZWZ virtual disk is already active."
        case .noActiveSession: return "No ZWZ virtual disk is active."
        case .unsupportedArchive: return "Only ZWZ archives can be mounted."
        case .commandFailed(let message): return message
        case .mountPointMissing: return "The virtual disk mount point was not created."
        }
    }
}

@MainActor
final class VirtualDiskManager: ObservableObject {
    static let shared = VirtualDiskManager()
    static let volumeName = "ZwZ Virtual Disk"

    @Published private(set) var session: VirtualDiskSession?
    @Published private(set) var isBusy = false

    private let fileManager = FileManager.default
    private var unmountObserver: NSObjectProtocol?
    private var activePassword: String?

    private var rootURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ZwZ/VirtualDisk", isDirectory: true)
    }

    private var sessionURL: URL { rootURL.appendingPathComponent("session.json") }

    private init() {
        restoreSession()
        observeUnmounts()
    }


    nonisolated static func recommendedCapacityMB(uncompressedBytes: UInt64) -> Int {
        let mb = Int((uncompressedBytes + 1_048_575) / 1_048_576)
        return max(256, ((mb + 256 + 255) / 256) * 256)
    }

    func mount(archivePath: String, password: String?, capacityMB: Int, ownerTabID: UUID? = nil) async throws {
        try await mount(
            archivePath: archivePath,
            password: password,
            capacityMB: capacityMB,
            ownerTabID: ownerTabID,
            securityInfo: nil,
            identityStore: ZwzGUIIdentityStore.shared
        )
    }

    func mount(
        archivePath: String,
        password: String?,
        capacityMB: Int,
        ownerTabID: UUID? = nil,
        securityInfo: ZwzArchiveSecurityInfo?,
        identityStore: any ZwzIdentityStore
    ) async throws {
        guard session == nil else { throw VirtualDiskError.sessionAlreadyActive }
        guard URL(fileURLWithPath: archivePath).pathExtension.lowercased() == "zwz" else {
            throw VirtualDiskError.unsupportedArchive
        }
        guard securityInfo?.signature != .invalid else {
            throw ZwzV3Error.invalidSignature
        }
        isBusy = true
        defer { isBusy = false }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let imageURL = rootURL.appendingPathComponent("workspace.sparsebundle")
        let mountURL = rootURL.appendingPathComponent("Mount", isDirectory: true)
        try? fileManager.removeItem(at: imageURL)
        try? fileManager.removeItem(at: mountURL)
        try fileManager.createDirectory(at: mountURL, withIntermediateDirectories: true)

        try runHdiutil(["create", "-size", "\(capacityMB)m", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-volname", Self.volumeName, imageURL.path])
        try runHdiutil(["attach", imageURL.path, "-mountpoint", mountURL.path])
        guard fileManager.fileExists(atPath: mountURL.path) else { throw VirtualDiskError.mountPointMissing }

        let extraction: ZwzExtractionResult
        do {
            extraction = try ZwzAPI().extract(
                archivePath: archivePath,
                destinationPath: mountURL.path,
                password: password,
                keyProvider: identityStore
            )
        } catch {
            _ = try? runHdiutil(["detach", mountURL.path])
            try? fileManager.removeItem(at: imageURL)
            try? fileManager.removeItem(at: mountURL)
            throw error
        }

        let fingerprint = try fingerprint(of: mountURL)
        let resolvedSecurityInfo = extraction.securityInfo ?? securityInfo
        session = VirtualDiskSession(
            archivePath: archivePath,
            imagePath: imageURL.path,
            mountPath: mountURL.path,
            capacityMB: capacityMB,
            baselineFingerprint: fingerprint,
            splitVolumeBytes: inferSplitVolumeBytes(archivePath: archivePath),
            isMounted: true,
            ownerTabID: ownerTabID,
            protection: resolvedSecurityInfo.map(ArchiveProtectionDescriptor.init)
        )
        activePassword = password
        try persistSession()
    }

    func hasChanges() throws -> Bool {
        guard let session else { throw VirtualDiskError.noActiveSession }
        guard session.isMounted else { return true }
        return try fingerprint(of: URL(fileURLWithPath: session.mountPath)) != session.baselineFingerprint
    }

    func ensureMounted() throws {
        guard var current = session else { throw VirtualDiskError.noActiveSession }
        guard !current.isMounted else { return }
        try fileManager.createDirectory(atPath: current.mountPath, withIntermediateDirectories: true)
        try runHdiutil(["attach", current.imagePath, "-mountpoint", current.mountPath])
        current.isMounted = true
        session = current
        try persistSession()
    }

    func save(to destinationPath: String) throws {
        try save(to: destinationPath, identityStore: ZwzGUIIdentityStore.shared)
    }

    func save(
        to destinationPath: String,
        identityStore: any ZwzIdentityStore
    ) throws {
        guard let current = session else { throw VirtualDiskError.noActiveSession }
        let securityInfo: ZwzArchiveSecurityInfo?
        if let persisted = current.protection?.securityInfo {
            securityInfo = persisted
        } else {
            securityInfo = try? ZwzAPI().inspect(
                archivePath: current.archivePath,
                keyProvider: identityStore
            ).securityInfo
        }
        if securityInfo?.encryption == .password, activePassword == nil {
            let candidate = try requestPasswordForSave()
            _ = try ZwzAPI().list(
                archivePath: current.archivePath,
                password: candidate,
                keyProvider: identityStore
            )
            activePassword = candidate
        }
        let encryption = try ArchiveEncryptionResolver.resolve(
            securityInfo: securityInfo,
            password: activePassword,
            identityStore: identityStore
        )
        try save(
            to: destinationPath,
            encryption: encryption,
            identityStore: identityStore
        )
    }

    func save(
        to destinationPath: String,
        encryption: ZwzEncryptionMode,
        identityStore: any ZwzIdentityStore
    ) throws {
        guard let current = session else { throw VirtualDiskError.noActiveSession }
        try ensureMounted()
        let destination = URL(fileURLWithPath: destinationPath)
        let temporary = rootURL.appendingPathComponent("rebuilt-\(UUID().uuidString).zwz")
        let split = current.splitVolumeBytes.flatMap { bytes -> SplitVolume? in
            guard bytes > 0 else { return nil }
            return .kiloBytes(max(1, Int(bytes / 1024)))
        }
        let staging = rootURL.appendingPathComponent("Rebuild", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try copyArchiveContent(from: URL(fileURLWithPath: current.mountPath), to: staging)
        defer { try? fileManager.removeItem(at: staging) }
        let options = CompressionOptions(
            level: .normal,
            encryption: encryption,
            splitVolume: split,
            format: .zwz
        )
        _ = try ZwzAPI().compress(
            sourcePath: staging.path,
            destinationPath: temporary.path,
            options: options,
            keyProvider: identityStore
        )
        try detach()
        try installArchiveVolumes(from: temporary, to: destination)
        try finishSession()
    }

    func detach() throws {
        guard var current = session else { throw VirtualDiskError.noActiveSession }
        if current.isMounted {
            try runHdiutil(["detach", current.mountPath])
            current.isMounted = false
            session = current
            try persistSession()
        }
    }

    func discard() throws {
        guard let current = session else { throw VirtualDiskError.noActiveSession }
        if current.isMounted { try runHdiutil(["detach", current.mountPath]) }
        try? fileManager.removeItem(atPath: current.imagePath)
        try? fileManager.removeItem(at: sessionURL)
        session = nil
        activePassword = nil
    }

    func requestUnmount() {
        guard let current = session else { return }
        do {
            if !current.isMounted {
                try ensureMounted()
            }
            let changed = try hasChanges()
            if changed {
                let alert = NSAlert()
                alert.messageText = SettingsStrings.text("虚拟磁盘包含修改", "Virtual Disk Has Changes")
                alert.informativeText = SettingsStrings.text("保存修改后卸载、放弃修改，或取消并继续使用虚拟磁盘。", "Save changes before unmounting, discard them, or cancel and keep using the disk.")
                alert.addButton(withTitle: SettingsStrings.text("保存修改", "Save Changes"))
                alert.addButton(withTitle: SettingsStrings.text("放弃修改", "Discard Changes"))
                alert.addButton(withTitle: SettingsStrings.text("取消", "Cancel"))
                switch alert.runModal() {
                case .alertFirstButtonReturn: chooseSaveDestination(originalPath: current.archivePath)
                case .alertSecondButtonReturn: try discard()
                default: try ensureMounted()
                }
            } else {
                try discard()
            }
        } catch {
            showError(error)
        }
    }

    private func chooseSaveDestination(originalPath: String) {
        let alert = NSAlert()
        alert.messageText = SettingsStrings.text("保存 ZWZ", "Save ZWZ")
        alert.informativeText = SettingsStrings.text("覆盖原压缩包，或另存为新文件。", "Replace the original archive or save a new copy.")
        alert.addButton(withTitle: SettingsStrings.text("覆盖原文件", "Replace Original"))
        alert.addButton(withTitle: SettingsStrings.text("另存为…", "Save As…"))
        alert.addButton(withTitle: SettingsStrings.text("取消", "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do { try save(to: originalPath) } catch { showError(error) }
        case .alertSecondButtonReturn:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.data]
            panel.nameFieldStringValue = URL(fileURLWithPath: originalPath).lastPathComponent
            if panel.runModal() == .OK, let url = panel.url {
                do { try save(to: url.path) } catch { showError(error) }
            }
        default:
            try? ensureMounted()
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = SettingsStrings.text("虚拟磁盘操作失败", "Virtual Disk Operation Failed")
        alert.runModal()
    }

    private func requestPasswordForSave() throws -> String {
        let alert = NSAlert()
        alert.messageText = SettingsStrings.text("输入原压缩密码", "Enter Original Archive Password")
        alert.informativeText = SettingsStrings.text(
            "需要原密码才能保留虚拟磁盘的加密并保存修改。密码不会写入会话文件。",
            "The original password is required to preserve encryption when saving. It will not be stored in the session file."
        )
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = SettingsStrings.text("压缩密码", "Archive password")
        alert.accessoryView = field
        alert.addButton(withTitle: SettingsStrings.text("继续保存", "Continue Saving"))
        alert.addButton(withTitle: SettingsStrings.text("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            throw CancellationError()
        }
        guard !field.stringValue.isEmpty else {
            throw ArchiveEncryptionResolutionError.passwordRequired
        }
        return field.stringValue
    }

    private func finishSession() throws {
        guard let current = session else { return }
        try? fileManager.removeItem(atPath: current.imagePath)
        try? fileManager.removeItem(at: sessionURL)
        session = nil
        activePassword = nil
    }

    private func restoreSession() {
        guard let data = try? Data(contentsOf: sessionURL), var restored = try? JSONDecoder().decode(VirtualDiskSession.self, from: data) else { return }
        let mountedPaths = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])?.map { $0.path } ?? []
        restored.isMounted = mountedPaths.contains(restored.mountPath)
        session = restored
        activePassword = nil
    }

    private func persistSession() throws {
        guard let session else { return }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: sessionURL, options: .atomic)
    }

    private func observeUnmounts() {
        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor [weak self] in
                guard let self, var current = self.session, url.path == current.mountPath else { return }
                current.isMounted = false
                self.session = current
                try? self.persistSession()
                self.requestUnmount()
            }
        }
    }

    @discardableResult
    private func runHdiutil(_ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw VirtualDiskError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return output
    }

    private func fingerprint(of root: URL) throws -> String {
        guard fileManager.fileExists(atPath: root.path) else { return "unmounted" }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys)
        var rows: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if isVolumeMetadata(relativePath: relative) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator?.skipDescendants()
                }
                continue
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            rows.append("\(relative)|\(values.isDirectory == true ? "d" : "f")|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        return rows.sorted().joined(separator: "\n")
    }

    private func copyArchiveContent(from source: URL, to destination: URL) throws {
        for url in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            guard !isVolumeMetadata(relativePath: url.lastPathComponent) else { continue }
            try fileManager.copyItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
        }
    }

    private func installArchiveVolumes(from temporary: URL, to destination: URL) throws {
        let temporaryBase = temporary.deletingPathExtension().lastPathComponent
        let destinationBase = destination.deletingPathExtension().lastPathComponent
        let directory = temporary.deletingLastPathComponent()
        let generated = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter {
                $0.lastPathComponent == temporary.lastPathComponent ||
                ($0.deletingPathExtension().lastPathComponent == temporaryBase && $0.pathExtension.lowercased().hasPrefix("z"))
            }
        guard generated.contains(temporary) else {
            throw VirtualDiskError.commandFailed("The rebuilt ZWZ archive was not created.")
        }

        let destinationDirectory = destination.deletingLastPathComponent()
        let existing = (try? fileManager.contentsOfDirectory(at: destinationDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in existing where url.lastPathComponent == destination.lastPathComponent ||
            (url.deletingPathExtension().lastPathComponent == destinationBase && url.pathExtension.lowercased().hasPrefix("z")) {
            try fileManager.removeItem(at: url)
        }
        for source in generated {
            let target = source == temporary
                ? destination
                : destination.deletingPathExtension().appendingPathExtension(source.pathExtension)
            try fileManager.moveItem(at: source, to: target)
        }
    }

    private func isVolumeMetadata(relativePath: String) -> Bool {
        guard let first = relativePath.split(separator: "/").first.map(String.init) else { return false }
        return [".fseventsd", ".Spotlight-V100", ".Trashes", ".DocumentRevisions-V100", ".TemporaryItems"].contains(first)
    }

    private func inferSplitVolumeBytes(archivePath: String) -> Int64? {
        let url = URL(fileURLWithPath: archivePath)
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        let parts = files.filter { $0.deletingPathExtension().lastPathComponent == base && $0.pathExtension.lowercased().hasPrefix("z") }
        guard !parts.isEmpty else { return nil }
        return parts.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init).max()
    }
}

@MainActor
final class DefaultArchiveMountWorkflowClient: ArchiveMountWorkflowClient {
    private let manager: VirtualDiskManager

    init(manager: VirtualDiskManager = .shared) {
        self.manager = manager
    }

    func mount(
        archivePath: String,
        password: String?,
        capacityMB: Int,
        securityInfo: ZwzArchiveSecurityInfo?,
        identityStore: any ZwzIdentityStore
    ) async throws {
        try await manager.mount(
            archivePath: archivePath,
            password: password,
            capacityMB: capacityMB,
            securityInfo: securityInfo,
            identityStore: identityStore
        )
    }

    func save(identityStore: any ZwzIdentityStore) async throws {
        guard let destinationPath = manager.session?.archivePath else {
            throw VirtualDiskError.noActiveSession
        }
        try manager.save(to: destinationPath, identityStore: identityStore)
    }
}
