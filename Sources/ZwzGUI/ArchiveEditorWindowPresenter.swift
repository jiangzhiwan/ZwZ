import AppKit
import SwiftUI

struct ArchiveEditorWindowPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let viewModel: ArchiveViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(isPresented: $isPresented, viewModel: viewModel)
        if isPresented {
            context.coordinator.present(relativeTo: nsView.window ?? NSApp.keyWindow ?? NSApp.mainWindow)
        } else {
            context.coordinator.dismiss()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private var isPresented: Binding<Bool>
        private var viewModel: ArchiveViewModel
        private var editorWindow: NSWindow?
        private var hostingController: NSHostingController<ZWZArchiveEditorView>?
        private var isRunningModal = false
        private var isClosingProgrammatically = false
        private var isConfirmingClose = false

        var presentedWindow: NSWindow? { editorWindow }

        init(isPresented: Binding<Bool>, viewModel: ArchiveViewModel) {
            self.isPresented = isPresented
            self.viewModel = viewModel
        }

        func update(isPresented: Binding<Bool>, viewModel: ArchiveViewModel) {
            self.isPresented = isPresented
            self.viewModel = viewModel
            editorWindow?.standardWindowButton(.closeButton)?.isEnabled = !viewModel.isSavingEdits
        }

        func present(relativeTo ownerWindow: NSWindow?) {
            guard editorWindow == nil else { return }

            let content = ZWZArchiveEditorView(viewModel: viewModel)
            let hostingController = NSHostingController(rootView: content)
            hostingController.sizingOptions = []

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "编辑压缩包 - \(viewModel.archiveName)"
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.isMovable = true
            window.delegate = self
            window.setContentSize(NSSize(width: 720, height: 540))
            window.contentView?.layoutSubtreeIfNeeded()
            position(window, relativeTo: ownerWindow)
            window.alphaValue = 0

            self.hostingController = hostingController
            editorWindow = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            DispatchQueue.main.async { [weak self, weak window, weak ownerWindow] in
                guard let self, let window, self.editorWindow === window, window.isVisible else { return }
                window.setContentSize(NSSize(width: 720, height: 540))
                window.contentView?.layoutSubtreeIfNeeded()
                self.position(window, relativeTo: ownerWindow)
                window.alphaValue = 1
                self.isRunningModal = true
                _ = NSApp.runModal(for: window)
                self.isRunningModal = false
            }
        }

        func dismiss() {
            guard let window = editorWindow else { return }
            dismiss(window: window)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if isClosingProgrammatically { return true }
            guard !viewModel.isSavingEdits else { return false }
            guard !isConfirmingClose else { return false }

            guard viewModel.hasUnsavedArchiveEdits else {
                isPresented.wrappedValue = false
                viewModel.discardArchiveEdits()
                return true
            }

            isConfirmingClose = true
            let alert = NSAlert()
            alert.messageText = "放弃所有未保存更改？"
            alert.informativeText = "当前压缩包中的编辑将不会保存。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "放弃")
            alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: sender) { [weak self] response in
                guard let self else { return }
                self.isConfirmingClose = false
                if response == .alertFirstButtonReturn {
                    self.viewModel.discardArchiveEdits()
                    self.dismiss(window: sender)
                }
            }
            return false
        }

        func windowWillClose(_ notification: Notification) {
            guard let closingWindow = notification.object as? NSWindow,
                  closingWindow === editorWindow else { return }
            if isRunningModal {
                NSApp.stopModal()
            }
            if !isClosingProgrammatically, isPresented.wrappedValue {
                isPresented.wrappedValue = false
            }
            editorWindow = nil
            hostingController = nil
        }

        private func dismiss(window: NSWindow) {
            guard editorWindow === window else { return }
            isClosingProgrammatically = true
            if isRunningModal {
                NSApp.stopModal()
            }
            window.close()
            // NSWindow normally delivers windowWillClose synchronously. Keep the
            // coordinator from retaining a window if AppKit defers that callback.
            if editorWindow === window {
                editorWindow = nil
                hostingController = nil
            }
            isClosingProgrammatically = false
        }

        private func position(_ window: NSWindow, relativeTo ownerWindow: NSWindow?) {
            guard let visibleFrame = ownerWindow?.screen?.visibleFrame
                ?? NSApp.keyWindow?.screen?.visibleFrame
                ?? NSApp.mainWindow?.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame else {
                window.center()
                return
            }
            window.setFrameOrigin(Self.centeredOrigin(
                windowSize: window.frame.size,
                visibleFrame: visibleFrame
            ))
        }

        static func centeredOrigin(windowSize: NSSize, visibleFrame: NSRect) -> NSPoint {
            NSPoint(
                x: windowSize.width >= visibleFrame.width
                    ? visibleFrame.minX
                    : visibleFrame.midX - windowSize.width / 2,
                y: windowSize.height >= visibleFrame.height
                    ? visibleFrame.minY
                    : visibleFrame.midY - windowSize.height / 2
            )
        }
    }
}
