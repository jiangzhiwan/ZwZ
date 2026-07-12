import AppKit
import SwiftUI
import XCTest
@testable import ZwzGUI

@MainActor
final class ArchiveEditorWindowPresenterTests: XCTestCase {
    func testPresenterCreatesMovableTitledWindowAndDismissesIt() throws {
        var isPresented = true
        let binding = Binding(
            get: { isPresented },
            set: { isPresented = $0 }
        )
        let viewModel = ArchiveViewModel()
        viewModel.archiveName = "example.zip"
        let coordinator = ArchiveEditorWindowPresenter.Coordinator(
            isPresented: binding,
            viewModel: viewModel
        )

        coordinator.present(relativeTo: nil)

        let window = try XCTUnwrap(coordinator.presentedWindow)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.isMovable)
        XCTAssertEqual(window.title, "编辑压缩包 - example.zip")

        coordinator.dismiss()

        XCTAssertNil(coordinator.presentedWindow)
    }

    func testCenteredOriginUsesVisibleFrameIncludingNegativeScreenCoordinates() {
        let visibleFrame = NSRect(x: -1_600, y: 23, width: 1_600, height: 900)

        let origin = ArchiveEditorWindowPresenter.Coordinator.centeredOrigin(
            windowSize: NSSize(width: 720, height: 540),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(origin.x, -1_160, accuracy: 0.001)
        XCTAssertEqual(origin.y, 203, accuracy: 0.001)
    }

    func testCenteredOriginPinsOversizedWindowToVisibleFrameOrigin() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 600, height: 400)

        let origin = ArchiveEditorWindowPresenter.Coordinator.centeredOrigin(
            windowSize: NSSize(width: 720, height: 540),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(origin, visibleFrame.origin)
    }
}
