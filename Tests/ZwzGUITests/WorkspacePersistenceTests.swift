import XCTest
@testable import ZwzGUI

@MainActor
final class WorkspacePersistenceTests: XCTestCase {
    private func makePersistence() -> WorkspacePersistence {
        WorkspacePersistence(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("workspace-\(UUID().uuidString).json")
        )
    }

    func testSnapshotRoundTripsOrderedTabsAndSelection() throws {
        let persistence = makePersistence()
        let firstID = UUID()
        let secondID = UUID()
        let snapshot = WorkspaceSnapshot(
            version: 1,
            tabs: [
                WorkspaceTabSnapshot(id: firstID, kind: .archive, sourcePath: "/tmp/a.zwz", wasRunning: false),
                WorkspaceTabSnapshot(id: secondID, kind: .interrupted, sourcePath: "/tmp/b.zip", wasRunning: true),
            ],
            selectedTabID: secondID
        )

        try persistence.save(snapshot)
        let restored = try persistence.load()

        XCTAssertEqual(restored, snapshot)
    }

    func testSnapshotEncodingNeverContainsPassword() throws {
        let persistence = makePersistence()
        let workspace = WorkspaceViewModel(persistence: persistence, restoreTabs: false)
        workspace.selectedTab.viewModel.password = "top-secret-password"
        workspace.selectedTab.viewModel.sourcePath = "/tmp/a.zwz"
        workspace.selectedTab.kind = .archive

        workspace.saveSnapshot()

        let data = try Data(contentsOf: persistence.url)
        XCTAssertNil(String(data: data, encoding: .utf8)?.range(of: "top-secret-password"))
    }

    func testRestoreMapsRunningTabToInterruptedAndMissingPathToMissingFile() throws {
        let persistence = makePersistence()
        let runningID = UUID()
        let missingID = UUID()
        try persistence.save(WorkspaceSnapshot(
            version: 1,
            tabs: [
                WorkspaceTabSnapshot(id: runningID, kind: .archive, sourcePath: "/tmp/missing-running.zwz", wasRunning: true),
                WorkspaceTabSnapshot(id: missingID, kind: .archive, sourcePath: "/tmp/missing-idle.zwz", wasRunning: false),
            ],
            selectedTabID: missingID
        ))

        let workspace = WorkspaceViewModel(persistence: persistence, restoreTabs: true)

        XCTAssertEqual(workspace.tabs.map(\.kind), [.interrupted, .missingFile])
        XCTAssertEqual(workspace.selectedTabID, missingID)
        XCTAssertEqual(workspace.tabs.map { $0.viewModel.password }, ["", ""])
    }

    func testCorruptSnapshotFallsBackToOneEmptyTab() throws {
        let persistence = makePersistence()
        try Data("not-json".utf8).write(to: persistence.url)

        let workspace = WorkspaceViewModel(persistence: persistence, restoreTabs: true)

        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.tabs[0].kind, .empty)
    }

    func testUnsupportedSnapshotVersionFallsBackToOneEmptyTab() throws {
        let persistence = makePersistence()
        let unsupported = WorkspaceSnapshot(
            version: 999,
            tabs: [WorkspaceTabSnapshot(id: UUID(), kind: .archive, sourcePath: "/tmp/a.zwz", wasRunning: false)],
            selectedTabID: UUID()
        )
        try JSONEncoder().encode(unsupported).write(to: persistence.url)

        let workspace = WorkspaceViewModel(persistence: persistence, restoreTabs: true)

        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.tabs[0].kind, .empty)
    }

    func testDisabledRestorationStartsWithOneEmptyTab() throws {
        let persistence = makePersistence()
        let savedID = UUID()
        try persistence.save(WorkspaceSnapshot(
            version: 1,
            tabs: [WorkspaceTabSnapshot(id: savedID, kind: .archive, sourcePath: "/tmp/a.zwz", wasRunning: false)],
            selectedTabID: savedID
        ))

        let workspace = WorkspaceViewModel(persistence: persistence, restoreTabs: false)

        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.tabs[0].kind, .empty)
        XCTAssertNotEqual(workspace.tabs[0].id, savedID)
    }

    func testRelocatingToAnOpenPathSelectsExistingTabAndRemovesMissingTab() throws {
        let persistence = makePersistence()
        let replacement = FileManager.default.temporaryDirectory
            .appendingPathComponent("replacement-\(UUID().uuidString).zwz")
        try Data().write(to: replacement)
        defer { try? FileManager.default.removeItem(at: replacement) }

        let workspace = WorkspaceViewModel(persistence: persistence, restoreTabs: false)
        let missingID = workspace.selectedTab.id
        workspace.selectedTab.kind = .missingFile
        workspace.selectedTab.viewModel.sourcePath = "/tmp/missing.zwz"
        let existing = workspace.newTab()
        existing.kind = .archive
        existing.viewModel.sourcePath = replacement.path

        workspace.relocateMissingTab(id: missingID, to: replacement)

        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.selectedTabID, existing.id)
    }
}
