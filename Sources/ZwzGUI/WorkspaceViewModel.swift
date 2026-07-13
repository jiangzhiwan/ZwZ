import Foundation
import SwiftUI

enum WorkspaceOpenIntent: Equatable {
    case automatic
    case preview
    case extract
    case compress
}

enum WorkspaceOpenResolution: Equatable {
    case newTab
    case replaceCurrent
    case cancel
}

struct WorkspaceOpenRequest: Equatable {
    let url: URL
    let intent: WorkspaceOpenIntent
}

private enum WorkspaceUnsavedAction {
    case close(UUID)
    case replace(WorkspaceOpenRequest)
}

@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published private(set) var tabs: [WorkspaceTab]
    @Published var selectedTabID: UUID
    @Published private(set) var pendingOpenRequest: WorkspaceOpenRequest?
    @Published private(set) var pendingRunningCloseTabID: UUID?
    @Published private(set) var hasPendingUnsavedChanges = false
    private var pendingUnsavedAction: WorkspaceUnsavedAction?
    private let persistence: WorkspacePersistence

    init(persistence: WorkspacePersistence = WorkspacePersistence(), restoreTabs: Bool = false) {
        self.persistence = persistence
        let tab = WorkspaceTab()
        tabs = [tab]
        selectedTabID = tab.id
        configurePersistence(for: tab)
        if restoreTabs { self.restoreTabs() }
    }

    var selectedTab: WorkspaceTab {
        tabs.first(where: { $0.id == selectedTabID }) ?? tabs[0]
    }

    @discardableResult
    func newTab() -> WorkspaceTab {
        let tab = WorkspaceTab()
        configurePersistence(for: tab)
        tabs.append(tab)
        selectedTabID = tab.id
        saveSnapshot()
        return tab
    }

    func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        saveSnapshot()
    }

    func requestClose(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if VirtualDiskManager.shared.session?.ownerTabID == id { return }
        if tab.viewModel.hasUnsavedArchiveEdits {
            pendingUnsavedAction = .close(id)
            hasPendingUnsavedChanges = true
            return
        }
        guard !tab.viewModel.isProcessing else {
            pendingRunningCloseTabID = id
            return
        }
        closeImmediately(id: id)
    }

    func confirmCloseRunningTab() {
        guard let id = pendingRunningCloseTabID,
              let tab = tabs.first(where: { $0.id == id }) else { return }
        pendingRunningCloseTabID = nil
        tab.viewModel.cancelOperation()
        closeImmediately(id: id)
    }

    func cancelCloseRunningTab() { pendingRunningCloseTabID = nil }

    func selectVirtualDiskOwner() {
        guard let ownerID = VirtualDiskManager.shared.session?.ownerTabID else { return }
        selectTab(id: ownerID)
    }

    func closeImmediately(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTabID == id
        tabs.remove(at: index)

        if tabs.isEmpty {
            let replacement = WorkspaceTab()
            configurePersistence(for: replacement)
            tabs = [replacement]
            selectedTabID = replacement.id
        } else if wasSelected {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
        saveSnapshot()
    }

    func moveTab(fromOffsets: IndexSet, toOffset: Int) {
        tabs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        saveSnapshot()
    }

    func moveTab(id: UUID, before targetID: UUID) {
        guard id != targetID,
              let sourceIndex = tabs.firstIndex(where: { $0.id == id }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        let tab = tabs.remove(at: sourceIndex)
        let adjustedTarget = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        tabs.insert(tab, at: adjustedTarget)
        saveSnapshot()
    }

    func selectNext() {
        guard pendingOpenRequest == nil else { return }
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(index + 1) % tabs.count].id
        saveSnapshot()
    }

    func selectPrevious() {
        guard pendingOpenRequest == nil else { return }
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(index - 1 + tabs.count) % tabs.count].id
        saveSnapshot()
    }

    func selectShortcutIndex(_ shortcutIndex: Int) {
        guard pendingOpenRequest == nil else { return }
        guard !tabs.isEmpty else { return }
        let targetIndex = shortcutIndex == 9
            ? tabs.count - 1
            : min(max(shortcutIndex - 1, 0), tabs.count - 1)
        selectedTabID = tabs[targetIndex].id
        saveSnapshot()
    }

    func requestOpen(url: URL, intent: WorkspaceOpenIntent) {
        let canonicalPath = Self.canonicalPath(for: url)
        if let existing = tabs.first(where: {
            guard let sourcePath = $0.viewModel.sourcePath else { return false }
            return Self.canonicalPath(for: URL(fileURLWithPath: sourcePath)) == canonicalPath
        }) {
            selectedTabID = existing.id
            pendingOpenRequest = nil
            saveSnapshot()
            return
        }

        if selectedTab.viewModel.sourcePath == nil && !selectedTab.viewModel.isProcessing {
            open(url: url, intent: intent, in: selectedTab)
        } else {
            pendingOpenRequest = WorkspaceOpenRequest(url: url, intent: intent)
        }
    }

    func resolvePendingOpen(_ resolution: WorkspaceOpenResolution) {
        guard let request = pendingOpenRequest else { return }
        pendingOpenRequest = nil

        switch resolution {
        case .newTab:
            open(url: request.url, intent: request.intent, in: newTab())
        case .replaceCurrent:
            let tab = selectedTab
            if tab.viewModel.hasUnsavedArchiveEdits {
                pendingUnsavedAction = .replace(request)
                hasPendingUnsavedChanges = true
                return
            }
            tab.viewModel.clearPreview()
            tab.kind = .empty
            open(url: request.url, intent: request.intent, in: tab)
        case .cancel:
            break
        }
    }

    func resolveUnsavedChanges(save: Bool) {
        guard let action = pendingUnsavedAction else { return }
        hasPendingUnsavedChanges = false
        if save {
            let tab: WorkspaceTab?
            switch action {
            case .close(let id): tab = tabs.first(where: { $0.id == id })
            case .replace: tab = selectedTab
            }
            guard let tab else { pendingUnsavedAction = nil; return }
            tab.viewModel.saveArchiveEdits { [weak self] in
                self?.completeUnsavedAction(action)
            }
        } else {
            switch action {
            case .close(let id): tabs.first(where: { $0.id == id })?.viewModel.discardArchiveEdits()
            case .replace: selectedTab.viewModel.discardArchiveEdits()
            }
            completeUnsavedAction(action)
        }
    }

    func cancelUnsavedChanges() {
        pendingUnsavedAction = nil
        hasPendingUnsavedChanges = false
    }

    private func completeUnsavedAction(_ action: WorkspaceUnsavedAction) {
        pendingUnsavedAction = nil
        hasPendingUnsavedChanges = false
        switch action {
        case .close(let id): closeImmediately(id: id)
        case .replace(let request):
            let tab = selectedTab
            tab.viewModel.clearPreview()
            tab.kind = .empty
            open(url: request.url, intent: request.intent, in: tab)
        }
    }

    private func open(url: URL, intent: WorkspaceOpenIntent, in tab: WorkspaceTab) {
        selectedTabID = tab.id
        let ext = url.pathExtension.lowercased()
        let isArchive = ["zip", "zwz", "rar", "7z", "gz", "tgz"].contains(ext)
            || url.path.lowercased().hasSuffix(".tar.gz")
        tab.kind = isArchive ? .archive : .compressionSource

        switch intent {
        case .automatic, .preview, .extract, .compress:
            tab.viewModel.handleAutoOpen(path: url.path, url: url)
        }
        saveSnapshot()
    }

    func saveSnapshot() {
        let snapshot = WorkspaceSnapshot(
            version: WorkspaceSnapshot.currentVersion,
            tabs: tabs.map {
                WorkspaceTabSnapshot(
                    id: $0.id,
                    kind: $0.kind,
                    sourcePath: $0.viewModel.sourcePath,
                    wasRunning: $0.viewModel.isProcessing
                )
            },
            selectedTabID: selectedTabID
        )
        try? persistence.save(snapshot)
    }

    func restoreTabs() {
        guard let snapshot = try? persistence.load(), !snapshot.tabs.isEmpty else { return }
        let fileManager = FileManager.default
        tabs = snapshot.tabs.map { saved in
            let viewModel = ArchiveViewModel()
            viewModel.password = ""
            viewModel.sourcePath = saved.sourcePath
            if let path = saved.sourcePath {
                viewModel.archiveName = URL(fileURLWithPath: path).lastPathComponent
            }
            let kind: WorkspaceTabKind
            if saved.wasRunning {
                kind = .interrupted
            } else if let path = saved.sourcePath, !fileManager.fileExists(atPath: path) {
                kind = .missingFile
            } else {
                kind = saved.kind
            }
            return WorkspaceTab(id: saved.id, kind: kind, viewModel: viewModel)
        }
        for tab in tabs {
            configurePersistence(for: tab)
        }
        selectedTabID = tabs.contains(where: { $0.id == snapshot.selectedTabID })
            ? snapshot.selectedTabID
            : tabs[0].id

        for tab in tabs where tab.kind == .archive {
            guard let path = tab.viewModel.sourcePath else { continue }
            tab.viewModel.handleAutoOpen(path: path, url: URL(fileURLWithPath: path))
        }
    }

    func relocateMissingTab(id: UUID, to url: URL) {
        guard let tab = tabs.first(where: { $0.id == id }), tab.kind == .missingFile else { return }
        let canonical = Self.canonicalPath(for: url)
        if let duplicate = tabs.first(where: {
            $0.id != id && $0.viewModel.sourcePath.map {
                Self.canonicalPath(for: URL(fileURLWithPath: $0)) == canonical
            } == true
        }) {
            closeImmediately(id: id)
            selectedTabID = duplicate.id
            saveSnapshot()
            return
        }
        open(url: url, intent: .automatic, in: tab)
    }

    private static func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func configurePersistence(for tab: WorkspaceTab) {
        tab.onPersistentStateChanged = { [weak self] in
            self?.saveSnapshot()
        }
    }
}
