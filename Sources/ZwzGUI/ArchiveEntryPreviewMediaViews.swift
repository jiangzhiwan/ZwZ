import AppKit
import AVKit
import SwiftUI

enum ZWZImagePreviewAction: Sendable, Equatable {
    case zoomIn
    case zoomOut
    case fitToWindow
    case actualSize
}

/// A command carries a fresh identifier so the same action can be issued repeatedly.
struct ZWZImagePreviewCommand: Identifiable, Sendable, Equatable {
    let id: UUID
    let action: ZWZImagePreviewAction

    init(_ action: ZWZImagePreviewAction, id: UUID = UUID()) {
        self.id = id
        self.action = action
    }
}

struct ZWZZoomableImagePreview: NSViewRepresentable {
    let url: URL
    @Binding private var command: ZWZImagePreviewCommand?

    init(url: URL, command: Binding<ZWZImagePreviewCommand?>) {
        self.url = url
        _command = command
    }

    init(url: URL) {
        self.url = url
        _command = .constant(nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ZWZImagePreviewScrollView {
        let scrollView = ZWZImagePreviewScrollView()
        let imageView = ZWZPannableImageView(frame: .zero)
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.animates = true
        imageView.wantsLayer = true

        scrollView.documentView = imageView
        scrollView.imageView = imageView
        scrollView.onViewportLayout = { [weak coordinator = context.coordinator, weak scrollView] in
            guard let coordinator, let scrollView else { return }
            coordinator.viewportDidChange(in: scrollView)
        }

        context.coordinator.loadImage(at: url, into: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: ZWZImagePreviewScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.loadedURL != url {
            coordinator.loadImage(at: url, into: scrollView)
        }
        coordinator.perform(command: command, in: scrollView)
    }

    static func dismantleNSView(_ nsView: ZWZImagePreviewScrollView, coordinator: Coordinator) {
        nsView.onViewportLayout = nil
        nsView.imageView?.animates = false
    }

    @MainActor
    final class Coordinator {
        private(set) var loadedURL: URL?
        private var processedCommandID: UUID?
        private var shouldFitToViewport = true
        private var isApplyingFit = false
        private var lastViewportSize: NSSize = .zero
        private var needsInitialFit = false

        func loadImage(at url: URL, into scrollView: ZWZImagePreviewScrollView) {
            loadedURL = url
            processedCommandID = nil
            shouldFitToViewport = true
            lastViewportSize = .zero
            needsInitialFit = true

            guard let imageView = scrollView.imageView else { return }
            imageView.image = NSImage(contentsOf: url)
            imageView.animates = true

            guard let image = imageView.image else {
                imageView.frame = .zero
                return
            }

            imageView.frame = NSRect(origin: .zero, size: image.size)
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView, self.loadedURL == url else { return }
                self.fitToViewport(in: scrollView)
            }
        }

        func perform(command: ZWZImagePreviewCommand?, in scrollView: ZWZImagePreviewScrollView) {
            guard let command, command.id != processedCommandID else { return }
            processedCommandID = command.id

            switch command.action {
            case .zoomIn:
                shouldFitToViewport = false
                setMagnification(scrollView.magnification * 1.25, in: scrollView)
            case .zoomOut:
                shouldFitToViewport = false
                setMagnification(scrollView.magnification / 1.25, in: scrollView)
            case .fitToWindow:
                shouldFitToViewport = true
                fitToViewport(in: scrollView)
            case .actualSize:
                shouldFitToViewport = false
                setMagnification(1, in: scrollView)
            }
        }

        func viewportDidChange(in scrollView: ZWZImagePreviewScrollView) {
            let viewportSize = scrollView.contentView.bounds.size
            guard viewportSize.width > 0, viewportSize.height > 0 else { return }
            guard needsInitialFit || viewportSize != lastViewportSize else { return }
            lastViewportSize = viewportSize
            guard shouldFitToViewport, !isApplyingFit else { return }
            fitToViewport(in: scrollView)
        }

        private func fitToViewport(in scrollView: ZWZImagePreviewScrollView) {
            guard let imageSize = scrollView.imageView?.image?.size,
                  imageSize.width > 0,
                  imageSize.height > 0 else { return }

            let viewportSize = scrollView.contentView.bounds.size
            guard viewportSize.width > 0, viewportSize.height > 0 else { return }

            let padding: CGFloat = 16
            let availableWidth = max(1, viewportSize.width - padding * 2)
            let availableHeight = max(1, viewportSize.height - padding * 2)
            let magnification = min(availableWidth / imageSize.width, availableHeight / imageSize.height)

            isApplyingFit = true
            setMagnification(
                magnification,
                centeredAt: NSPoint(x: imageSize.width / 2, y: imageSize.height / 2),
                in: scrollView
            )
            centerImage(in: scrollView)
            isApplyingFit = false
            needsInitialFit = false
        }

        private func setMagnification(
            _ magnification: CGFloat,
            centeredAt: NSPoint? = nil,
            in scrollView: ZWZImagePreviewScrollView
        ) {
            let clamped = min(max(magnification, scrollView.minMagnification), scrollView.maxMagnification)
            let visibleRect = scrollView.contentView.bounds
            let center = centeredAt ?? NSPoint(x: visibleRect.midX, y: visibleRect.midY)
            scrollView.setMagnification(clamped, centeredAt: center)
        }

        private func centerImage(in scrollView: ZWZImagePreviewScrollView) {
            guard let imageSize = scrollView.imageView?.image?.size else { return }
            let visibleSize = scrollView.contentView.bounds.size
            let origin = NSPoint(
                x: imageSize.width / 2 - visibleSize.width / 2,
                y: imageSize.height / 2 - visibleSize.height / 2
            )
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

struct ZWZVideoPreview: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.videoGravity = .resizeAspect
        context.coordinator.setURL(url, on: playerView)
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        context.coordinator.setURL(url, on: playerView)
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        nsView.player = nil
    }

    @MainActor
    final class Coordinator {
        private var loadedURL: URL?

        func setURL(_ url: URL, on playerView: AVPlayerView) {
            guard loadedURL != url else { return }
            playerView.player?.pause()
            loadedURL = url
            playerView.player = AVPlayer(url: url)
        }
    }
}

struct ZWZSelectableTextPreview: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.sizeToFit()

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        textView.string = text
        textView.sizeToFit()
    }
}

final class ZWZImagePreviewScrollView: NSScrollView {
    weak var imageView: ZWZPannableImageView?
    var onViewportLayout: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.05
        maxMagnification = 20
        contentView = ZWZCenteringClipView(frame: .zero)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func layout() {
        super.layout()
        onViewportLayout?()
    }
}

private final class ZWZCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrainedBounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return constrainedBounds }

        let documentFrame = documentView.frame
        if documentFrame.width < constrainedBounds.width {
            constrainedBounds.origin.x = documentFrame.midX - constrainedBounds.width / 2
        }
        if documentFrame.height < constrainedBounds.height {
            constrainedBounds.origin.y = documentFrame.midY - constrainedBounds.height / 2
        }
        return constrainedBounds
    }
}

final class ZWZPannableImageView: NSImageView {
    private var dragStartLocation: NSPoint?
    private var dragStartOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) {
        guard let scrollView = enclosingScrollView else {
            super.mouseDown(with: event)
            return
        }
        dragStartLocation = event.locationInWindow
        dragStartOrigin = scrollView.contentView.bounds.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let scrollView = enclosingScrollView,
              let dragStartLocation,
              let dragStartOrigin else { return }

        let location = event.locationInWindow
        let newOrigin = NSPoint(
            x: dragStartOrigin.x - (location.x - dragStartLocation.x),
            y: dragStartOrigin.y - (location.y - dragStartLocation.y)
        )
        scrollView.contentView.scroll(to: newOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartLocation = nil
        dragStartOrigin = nil
    }
}
