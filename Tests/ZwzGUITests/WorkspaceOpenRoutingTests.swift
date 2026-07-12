import XCTest
@testable import ZwzGUI

@MainActor
final class WorkspaceOpenRoutingTests: XCTestCase {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/zwz-routing-tests/\(name)")
    }

    func testEmptySelectedTabIsReusedWithoutPrompt() {
        let workspace = WorkspaceViewModel()
        let originalID = workspace.selectedTabID

        workspace.requestOpen(url: url("first.txt"), intent: .automatic)

        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.selectedTabID, originalID)
        XCTAssertEqual(workspace.selectedTab.viewModel.sourcePath, url("first.txt").path)
        XCTAssertNil(workspace.pendingOpenRequest)
    }

    func testClearedArchiveTabIsReusedWithoutPrompt() {
        let workspace = WorkspaceViewModel()
        workspace.selectedTab.kind = .archive
        workspace.selectedTab.viewModel.clearPreview()

        workspace.requestOpen(url: url("replacement.zip"), intent: .automatic)

        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.selectedTab.viewModel.sourcePath, url("replacement.zip").path)
        XCTAssertNil(workspace.pendingOpenRequest)
    }

    func testOccupiedSelectedTabCreatesPendingDecision() {
        let workspace = WorkspaceViewModel()
        workspace.requestOpen(url: url("first.txt"), intent: .automatic)

        workspace.requestOpen(url: url("second.txt"), intent: .automatic)

        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.pendingOpenRequest?.url.path, url("second.txt").path)
    }

    func testDuplicateCanonicalPathSelectsExistingTab() {
        let workspace = WorkspaceViewModel()
        workspace.requestOpen(url: url("first.txt"), intent: .automatic)
        let firstID = workspace.selectedTabID
        _ = workspace.newTab()

        workspace.requestOpen(
            url: URL(fileURLWithPath: "/tmp/zwz-routing-tests/./first.txt"),
            intent: .automatic
        )

        XCTAssertEqual(workspace.selectedTabID, firstID)
        XCTAssertNil(workspace.pendingOpenRequest)
    }

    func testNewTabResolutionOpensPendingURL() {
        let workspace = WorkspaceViewModel()
        workspace.requestOpen(url: url("first.txt"), intent: .automatic)
        workspace.requestOpen(url: url("second.txt"), intent: .automatic)

        workspace.resolvePendingOpen(.newTab)

        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(workspace.selectedTab.viewModel.sourcePath, url("second.txt").path)
        XCTAssertNil(workspace.pendingOpenRequest)
    }

    func testReplaceResolutionReusesCurrentTab() {
        let workspace = WorkspaceViewModel()
        workspace.requestOpen(url: url("first.txt"), intent: .automatic)
        let tabID = workspace.selectedTabID
        workspace.requestOpen(url: url("second.txt"), intent: .automatic)

        workspace.resolvePendingOpen(.replaceCurrent)

        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.selectedTabID, tabID)
        XCTAssertEqual(workspace.selectedTab.viewModel.sourcePath, url("second.txt").path)
    }

    func testCancelResolutionLeavesCurrentTabUntouched() {
        let workspace = WorkspaceViewModel()
        workspace.requestOpen(url: url("first.txt"), intent: .automatic)
        workspace.requestOpen(url: url("second.txt"), intent: .automatic)

        workspace.resolvePendingOpen(.cancel)

        XCTAssertEqual(workspace.selectedTab.viewModel.sourcePath, url("first.txt").path)
        XCTAssertNil(workspace.pendingOpenRequest)
    }
}
