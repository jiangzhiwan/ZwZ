import SwiftUI

struct WorkspaceTabBar: View {
    @ObservedObject var workspace: WorkspaceViewModel

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(workspace.tabs) { tab in
                            WorkspaceTabButton(
                                tab: tab,
                                isSelected: workspace.selectedTabID == tab.id,
                                onSelect: { workspace.selectTab(id: tab.id) },
                                onClose: { workspace.requestClose(id: tab.id) }
                            )
                            .id(tab.id)
                            .draggable(tab.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                guard let rawID = items.first,
                                      let sourceID = UUID(uuidString: rawID) else { return false }
                                workspace.moveTab(id: sourceID, before: tab.id)
                                return true
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }

                Button {
                    _ = workspace.newTab()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(L.string("new_tab"))
                .padding(.trailing, 10)
            }
            .frame(height: 40)
            .background(.ultraThinMaterial)
            .onChange(of: workspace.selectedTabID) { _, id in
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

private struct WorkspaceTabButton: View {
    @ObservedObject var tab: WorkspaceTab
    @ObservedObject private var viewModel: ArchiveViewModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    init(
        tab: WorkspaceTab,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.tab = tab
        _viewModel = ObservedObject(wrappedValue: tab.viewModel)
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 7) {
            badge

            Text(tab.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)

            if isSelected || isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 112, idealWidth: 168, maxWidth: 220, minHeight: 30)
        .background(isSelected ? Color.zwzBlue.opacity(0.13) : Color.secondary.opacity(isHovered ? 0.08 : 0.04))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var badge: some View {
        switch tab.taskBadge {
        case .running(let progress):
            ZStack {
                Circle().stroke(Color.zwzBlue.opacity(0.2), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.04, progress))
                    .stroke(Color.zwzBlue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failure:
            Circle().fill(Color.red).frame(width: 8, height: 8)
        case .none:
            Image(systemName: tab.kind == .empty ? "plus.square" : "doc.zipper")
                .foregroundColor(isSelected ? .zwzBlue : .secondary)
        }
    }
}
