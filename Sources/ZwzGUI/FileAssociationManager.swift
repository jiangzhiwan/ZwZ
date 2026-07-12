import AppKit
import Combine
import CoreServices
import Foundation
import UniformTypeIdentifiers

struct ArchiveFileAssociation: Identifiable, Hashable {
    enum Category: String, CaseIterable {
        case zwz
        case common
        case other
    }

    let id: String
    let displayName: String
    let filenameExtension: String
    let contentTypeIdentifier: String
    let category: Category

    static let all: [ArchiveFileAssociation] = [
        .init(id: "zwz", displayName: "ZWZ", filenameExtension: "zwz", contentTypeIdentifier: "com.zwz.archive", category: .zwz),
        .init(id: "zip", displayName: "ZIP", filenameExtension: "zip", contentTypeIdentifier: UTType.zip.identifier, category: .common),
        .init(id: "rar", displayName: "RAR", filenameExtension: "rar", contentTypeIdentifier: "com.zwz.rar-archive", category: .common),
        .init(id: "7z", displayName: "7Z", filenameExtension: "7z", contentTypeIdentifier: "com.zwz.7z-archive", category: .common),
        .init(id: "tar.gz", displayName: "TAR.GZ", filenameExtension: "tar.gz", contentTypeIdentifier: "com.zwz.tar-gz-archive", category: .other),
        .init(id: "tgz", displayName: "TGZ", filenameExtension: "tgz", contentTypeIdentifier: "com.zwz.tgz-archive", category: .other),
        .init(id: "gz", displayName: "GZ", filenameExtension: "gz", contentTypeIdentifier: "com.zwz.gzip-archive", category: .other),
    ]
}

enum FileAssociationError: LocalizedError {
    case applicationBundleRequired
    case launchServices(OSStatus)
    case noPreviousHandler

    var errorDescription: String? {
        switch self {
        case .applicationBundleRequired:
            return associationText(
                "文件关联需要从 ZwZ.app 启动。请先将 ZwZ.app 拖入“应用程序”文件夹。",
                "File associations require ZwZ.app. Move ZwZ.app to Applications first."
            )
        case let .launchServices(status):
            return associationText(
                "macOS 无法修改默认应用（错误码：\(status)）。",
                "macOS could not change the default application (error \(status))."
            )
        case .noPreviousHandler:
            return associationText("没有可恢复的原默认应用。", "There is no previous default application to restore.")
        }
    }
}

private func associationText(_ zh: String, _ en: String) -> String {
    (UserDefaults.standard.string(forKey: "zwz_language") ?? "zh") == "zh" ? zh : en
}

@MainActor
final class FileAssociationManager: ObservableObject {
    static let shared = FileAssociationManager()

    @Published private(set) var associatedIDs: Set<String> = []
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    private var statusTask: Task<Void, Never>?
    private let selectedIDsKey = "zwz_file_association_selected_ids"

    private init() {
        if defaults.object(forKey: selectedIDsKey) == nil {
            defaults.set(["zwz"], forKey: selectedIDsKey)
        }
        refresh()
    }

    var allAssociated: Bool {
        !ArchiveFileAssociation.all.isEmpty && ArchiveFileAssociation.all.allSatisfy { associatedIDs.contains($0.id) }
    }

    func refresh() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            associatedIDs = []
            return
        }
        let selectedIDs = Set(defaults.stringArray(forKey: selectedIDsKey) ?? ["zwz"])
        associatedIDs = Set(ArchiveFileAssociation.all.compactMap { association in
            selectedIDs.contains(association.id) && defaultHandler(for: association.contentTypeIdentifier) == bundleIdentifier
                ? association.id
                : nil
        })
    }

    func setAssociated(_ enabled: Bool, for association: ArchiveFileAssociation) {
        do {
            let bundleIdentifier = try currentBundleIdentifier()
            if enabled {
                let current = defaultHandler(for: association.contentTypeIdentifier)
                if current != bundleIdentifier, let current {
                    defaults.set(current, forKey: previousHandlerKey(for: association))
                }
                try setDefaultHandler(bundleIdentifier, for: association.contentTypeIdentifier)
                updateSelectedIDs(association.id, enabled: true)
                showStatus(SettingsStrings.text("\(association.displayName) 已关联", "\(association.displayName) associated"))
            } else {
                if let previous = defaults.string(forKey: previousHandlerKey(for: association)), !previous.isEmpty {
                    try setDefaultHandler(previous, for: association.contentTypeIdentifier)
                    defaults.removeObject(forKey: previousHandlerKey(for: association))
                    showStatus(SettingsStrings.text("\(association.displayName) 已恢复原默认应用", "\(association.displayName) restored"))
                } else {
                    showStatus(SettingsStrings.text("\(association.displayName) 已取消关联", "\(association.displayName) association removed"))
                }
                updateSelectedIDs(association.id, enabled: false)
            }
            refresh()
        } catch {
            refresh()
            errorMessage = error.localizedDescription
        }
    }

    func setAllAssociated(_ enabled: Bool) {
        for association in ArchiveFileAssociation.all where associatedIDs.contains(association.id) != enabled {
            setAssociated(enabled, for: association)
        }
    }

    private func currentBundleIdentifier() throws -> String {
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else {
            throw FileAssociationError.applicationBundleRequired
        }
        return identifier
    }

    private func defaultHandler(for contentType: String) -> String? {
        LSCopyDefaultRoleHandlerForContentType(contentType as CFString, .all)?.takeRetainedValue() as String?
    }

    private func setDefaultHandler(_ bundleIdentifier: String, for contentType: String) throws {
        let status = LSSetDefaultRoleHandlerForContentType(contentType as CFString, .all, bundleIdentifier as CFString)
        guard status == noErr else { throw FileAssociationError.launchServices(status) }
    }

    private func previousHandlerKey(for association: ArchiveFileAssociation) -> String {
        "zwz_file_association_previous_\(association.id)"
    }

    private func updateSelectedIDs(_ id: String, enabled: Bool) {
        var selectedIDs = Set(defaults.stringArray(forKey: selectedIDsKey) ?? ["zwz"])
        if enabled {
            selectedIDs.insert(id)
        } else {
            selectedIDs.remove(id)
        }
        defaults.set(Array(selectedIDs).sorted(), forKey: selectedIDsKey)
    }

    private func showStatus(_ message: String) {
        statusTask?.cancel()
        statusMessage = message
        statusTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
    }
}

@MainActor
final class OpenFileCoordinator: ObservableObject {
    static let shared = OpenFileCoordinator()

    @Published private(set) var pendingURL: URL?

    private init() {}

    func open(_ url: URL) {
        pendingURL = url
    }

    func consume() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }
}
