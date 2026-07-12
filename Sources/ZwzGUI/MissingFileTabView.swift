import SwiftUI
import UniformTypeIdentifiers

struct MissingFileTabView: View {
    @ObservedObject var workspace: WorkspaceViewModel
    let tab: WorkspaceTab
    @State private var choosingReplacement = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.badge.ellipsis")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(L.string("file_missing"))
                .font(.title2)
            Text(tab.viewModel.sourcePath ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Button(L.string("relocate")) { choosingReplacement = true }
                Button(L.string("close_tab")) { workspace.requestClose(id: tab.id) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $choosingReplacement, allowedContentTypes: [.data]) { result in
            if case let .success(url) = result {
                workspace.relocateMissingTab(id: tab.id, to: url)
            }
        }
    }
}
