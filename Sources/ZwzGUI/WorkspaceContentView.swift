import SwiftUI

struct WorkspaceContentView: View {
    @ObservedObject var workspace: WorkspaceViewModel

    var body: some View {
        let selected = workspace.selectedTab
        VStack(spacing: 0) {
            ZWZToolbar(viewModel: selected.viewModel, showHistorySidebar: .constant(false))
            WorkspaceTabBar(workspace: workspace)
            Divider()
            if selected.kind == .missingFile {
                MissingFileTabView(workspace: workspace, tab: selected)
                    .id(selected.id)
            } else {
                ContentView(
                    viewModel: selected.viewModel,
                    showsToolbar: false,
                    onOpenDroppedURL: { url in
                        workspace.requestOpen(url: url, intent: .automatic)
                    }
                )
                    .id(selected.id)
            }
        }
        .confirmationDialog(
            L.string("open_archive_choice"),
            isPresented: Binding(
                get: { workspace.pendingOpenRequest != nil },
                set: { if !$0 { workspace.resolvePendingOpen(.cancel) } }
            )
        ) {
            Button(L.string("open_in_new_tab")) {
                workspace.resolvePendingOpen(.newTab)
            }
            Button(L.string("replace_current_tab")) {
                workspace.resolvePendingOpen(.replaceCurrent)
            }
            Button(L.string("cancel"), role: .cancel) {
                workspace.resolvePendingOpen(.cancel)
            }
        }
        .confirmationDialog(
            L.string("close_running_title"),
            isPresented: Binding(
                get: { workspace.pendingRunningCloseTabID != nil },
                set: { if !$0 { workspace.cancelCloseRunningTab() } }
            )
        ) {
            Button(L.string("cancel_and_close"), role: .destructive) { workspace.confirmCloseRunningTab() }
            Button(L.string("cancel"), role: .cancel) { workspace.cancelCloseRunningTab() }
        }
        .confirmationDialog(
            "保存压缩包内编辑？",
            isPresented: Binding(
                get: { workspace.hasPendingUnsavedChanges },
                set: { if !$0 { workspace.cancelUnsavedChanges() } }
            )
        ) {
            Button("保存") { workspace.resolveUnsavedChanges(save: true) }
            Button("放弃更改", role: .destructive) { workspace.resolveUnsavedChanges(save: false) }
            Button(L.string("cancel"), role: .cancel) { workspace.cancelUnsavedChanges() }
        } message: {
            Text("当前压缩包有未保存的编辑。")
        }
    }
}
