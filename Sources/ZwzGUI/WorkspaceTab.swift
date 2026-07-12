import Foundation

enum WorkspaceTabKind: String, Codable, Equatable {
    case empty
    case archive
    case compressionSource
    case extractionTask
    case missingFile
    case interrupted
}

enum WorkspaceTaskBadge: Equatable {
    case none
    case running(Double)
    case success
    case failure
}

@MainActor
final class WorkspaceTab: Identifiable, ObservableObject {
    let id: UUID
    let viewModel: ArchiveViewModel
    @Published var kind: WorkspaceTabKind

    init(
        id: UUID = UUID(),
        kind: WorkspaceTabKind = .empty,
        viewModel: ArchiveViewModel = ArchiveViewModel()
    ) {
        self.id = id
        self.kind = kind
        self.viewModel = viewModel
    }

    var title: String {
        if !viewModel.archiveName.isEmpty { return viewModel.archiveName }
        if let path = viewModel.sourcePath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return L.string("new_tab")
    }

    var taskBadge: WorkspaceTaskBadge {
        if viewModel.isProcessing { return .running(viewModel.progress) }
        if viewModel.errorMessage != nil { return .failure }
        if viewModel.currentStatus?.text == ZWZStatus.done.text { return .success }
        return .none
    }
}
