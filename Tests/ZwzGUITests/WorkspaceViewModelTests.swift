import XCTest
@testable import ZwzGUI

@MainActor
final class WorkspaceViewModelTests: XCTestCase {
    func testWorkspaceStartsWithOneSelectedEmptyTab() {
        let workspace = WorkspaceViewModel()

        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.selectedTabID, workspace.tabs[0].id)
        XCTAssertEqual(workspace.tabs[0].kind, .empty)
    }

    func testSuccessfulCompressionRestoresSameTabAndAcceptsNextItemWithoutPrompt() throws {
        let workspace = WorkspaceViewModel()
        let tab = workspace.selectedTab
        let originalID = tab.id
        tab.kind = .compressionSource
        tab.viewModel.sourcePath = "/tmp/first-source"
        tab.viewModel.history.append(ZWZHistoryItem(
            type: .compress,
            fileName: "first-source",
            statusText: "成功",
            isSuccess: true
        ))

        let completion = try XCTUnwrap(tab.viewModel.onCompressionSucceeded)
        completion()

        XCTAssertEqual(tab.id, originalID)
        XCTAssertEqual(tab.kind, .empty)
        XCTAssertNil(tab.viewModel.sourcePath)
        XCTAssertEqual(tab.title, L.string("new_tab"))
        XCTAssertEqual(tab.viewModel.history.count, 1)

        workspace.requestOpen(
            url: URL(fileURLWithPath: "/tmp/next-source"),
            intent: .automatic
        )

        XCTAssertNil(workspace.pendingOpenRequest)
        XCTAssertEqual(tab.viewModel.sourcePath, "/tmp/next-source")
    }

    func testNewTabIsIndependentAndSelected() {
        let workspace = WorkspaceViewModel()
        let first = workspace.tabs[0]

        let second = workspace.newTab()

        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(workspace.selectedTabID, second.id)
        XCTAssertFalse(first.viewModel === second.viewModel)
    }

    func testClosingFinalTabReplacesItWithFreshEmptyTab() {
        let workspace = WorkspaceViewModel()
        let originalID = workspace.tabs[0].id

        workspace.closeImmediately(id: originalID)

        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertNotEqual(workspace.tabs[0].id, originalID)
        XCTAssertEqual(workspace.tabs[0].kind, .empty)
        XCTAssertEqual(workspace.selectedTabID, workspace.tabs[0].id)
    }

    func testNextAndPreviousSelectionWrap() {
        let workspace = WorkspaceViewModel()
        let firstID = workspace.tabs[0].id
        let secondID = workspace.newTab().id
        let thirdID = workspace.newTab().id

        workspace.selectNext()
        XCTAssertEqual(workspace.selectedTabID, firstID)

        workspace.selectPrevious()
        XCTAssertEqual(workspace.selectedTabID, thirdID)

        workspace.selectTab(id: firstID)
        workspace.selectPrevious()
        XCTAssertEqual(workspace.selectedTabID, thirdID)

        workspace.selectTab(id: secondID)
        workspace.selectNext()
        XCTAssertEqual(workspace.selectedTabID, thirdID)
    }

    func testNumberShortcutNineSelectsLastTab() {
        let workspace = WorkspaceViewModel()
        _ = workspace.newTab()
        let lastID = workspace.newTab().id
        workspace.selectTab(id: workspace.tabs[0].id)

        workspace.selectShortcutIndex(9)

        XCTAssertEqual(workspace.selectedTabID, lastID)
    }

    func testMoveTabsPreservesIdentityAndSelection() {
        let workspace = WorkspaceViewModel()
        let firstID = workspace.tabs[0].id
        let secondID = workspace.newTab().id
        let thirdID = workspace.newTab().id

        workspace.moveTab(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        XCTAssertEqual(workspace.tabs.map(\.id), [secondID, thirdID, firstID])
        XCTAssertEqual(workspace.selectedTabID, thirdID)
    }

    func testOperationGenerationRejectsStaleCallbacks() {
        let viewModel = ArchiveViewModel()
        let first = viewModel.beginOperation()
        let second = viewModel.beginOperation()

        XCTAssertFalse(viewModel.acceptsCallback(generation: first))
        XCTAssertTrue(viewModel.acceptsCallback(generation: second))

        viewModel.invalidateOperation()

        XCTAssertFalse(viewModel.acceptsCallback(generation: second))
    }

    func testSeparateTabsHaveIndependentOperationGenerations() {
        let workspace = WorkspaceViewModel()
        let firstTab = workspace.tabs[0]
        let secondTab = workspace.newTab()

        let firstGeneration = firstTab.viewModel.beginOperation()
        let secondGeneration = secondTab.viewModel.beginOperation()

        XCTAssertTrue(firstTab.viewModel.acceptsCallback(generation: firstGeneration))
        XCTAssertTrue(secondTab.viewModel.acceptsCallback(generation: secondGeneration))
        XCTAssertNotEqual(firstGeneration, secondGeneration)
    }
}
