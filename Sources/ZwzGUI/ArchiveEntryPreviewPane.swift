import SwiftUI
import ZwzCore

struct ZWZArchiveEntryPreviewPane: View {
    @ObservedObject var model: ArchiveEntryPreviewModel
    let formattedSize: String
    let onClose: () -> Void

    @State private var imageCommand: ZWZImagePreviewCommand?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            previewContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let entry = model.currentEntry {
                Image(systemName: ArchiveEntryPresentation.iconName(
                    forFileNamed: entry.name,
                    isDirectory: false
                ))
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.zwzBlue)
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        Text(formattedSize)
                            .layoutPriority(1)
                        Text(entry.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }

            previewIconButton(
                systemName: "xmark",
                help: L.string("close_preview"),
                action: onClose
            )
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var previewContent: some View {
        switch model.state {
        case .idle:
            Color.clear
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text(L.string("preview_loading"))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let payload):
            readyContent(payload)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.zwzOrange)
                Text(L.string("preview_failed"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(message)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                Button {
                    model.retry()
                } label: {
                    Label(L.string("preview_retry"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func readyContent(_ payload: ArchiveEntryPreviewReadyPayload) -> some View {
        switch payload {
        case .image(let url):
            VStack(spacing: 0) {
                ZWZZoomableImagePreview(url: url, command: $imageCommand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                HStack(spacing: 6) {
                    Spacer()
                    imageControlButton(systemName: "plus.magnifyingglass", action: .zoomIn, help: L.string("zoom_in"))
                    imageControlButton(systemName: "minus.magnifyingglass", action: .zoomOut, help: L.string("zoom_out"))
                    imageControlButton(systemName: "arrow.down.right.and.arrow.up.left", action: .fitToWindow, help: L.string("fit_to_window"))
                    imageControlButton(systemName: "1.magnifyingglass", action: .actualSize, help: L.string("actual_size"))
                    Spacer()
                }
                .padding(.vertical, 7)
                .background(.ultraThinMaterial)
            }
        case .video(let url):
            ZWZVideoPreview(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let result):
            VStack(spacing: 0) {
                ZWZSelectableTextPreview(text: result.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                VStack(alignment: .leading, spacing: 3) {
                    Text(L.string("preview_text_encoding", result.encodingName))
                    if result.isTruncated {
                        Label(L.string("preview_text_truncated"), systemImage: "scissors")
                    }
                }
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial)
            }
        case .unsupported:
            VStack(spacing: 10) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.secondary)
                Text(L.string("preview_unsupported"))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func imageControlButton(
        systemName: String,
        action: ZWZImagePreviewAction,
        help: String
    ) -> some View {
        previewIconButton(systemName: systemName, help: help) {
            imageCommand = ZWZImagePreviewCommand(action)
        }
    }

    private func previewIconButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .help(help)
        .accessibilityLabel(help)
    }
}
