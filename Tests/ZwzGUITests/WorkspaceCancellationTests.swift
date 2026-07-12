import XCTest
@testable import ZwzGUI

@MainActor
final class WorkspaceCancellationTests: XCTestCase {
    func testRunningTabRequiresConfirmationBeforeClose() {
        let workspace = WorkspaceViewModel()
        let id = workspace.selectedTabID
        workspace.selectedTab.viewModel.isProcessing = true

        workspace.requestClose(id: id)
        XCTAssertEqual(workspace.pendingRunningCloseTabID, id)
        XCTAssertEqual(workspace.tabs.count, 1)

        workspace.confirmCloseRunningTab()
        XCTAssertNil(workspace.pendingRunningCloseTabID)
        XCTAssertNotEqual(workspace.selectedTabID, id)
    }
}
