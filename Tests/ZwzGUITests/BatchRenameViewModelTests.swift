import XCTest
import ZwzCore
@testable import ZwzGUI

@MainActor
final class BatchRenameViewModelTests: XCTestCase {
    func testBatchRenameCallsEditorRefreshesEntriesAndMarksUnsavedChanges() {
        let editor = BatchRenameEditWorkflowSpy()
        editor.refreshedEntries = [
            ArchiveEntry(
                name: "renamed.txt",
                path: "renamed.txt",
                size: 4,
                isDirectory: false,
                modifiedDate: nil
            )
        ]
        let viewModel = ArchiveViewModel(editClient: editor)

        viewModel.batchRenameInArchive(items: [
            (sourcePath: "original.txt", newName: "renamed.txt")
        ])

        XCTAssertEqual(editor.recordedItems.count, 1)
        XCTAssertEqual(editor.recordedItems[0].sourcePath, "original.txt")
        XCTAssertEqual(editor.recordedItems[0].newName, "renamed.txt")
        XCTAssertEqual(viewModel.editEntries.map(\.path), ["renamed.txt"])
        XCTAssertTrue(viewModel.hasUnsavedArchiveEdits)
    }

    func testPreviewUsesUnselectedNamesForConflictResolution() throws {
        let viewModel = ArchiveViewModel()
        viewModel.batchRenameRuleType = .findReplace
        viewModel.batchFindText = "draft"
        viewModel.batchReplaceText = "report"
        let selected = ArchiveEntry(
            name: "draft.txt",
            path: "draft.txt",
            size: 1,
            isDirectory: false,
            modifiedDate: nil
        )
        let existing = ArchiveEntry(
            name: "report.txt",
            path: "report.txt",
            size: 1,
            isDirectory: false,
            modifiedDate: nil
        )

        let preview = try XCTUnwrap(viewModel.computeBatchRenamePreview(
            selectedEntries: [selected],
            allEntriesInDir: [selected, existing]
        ))

        XCTAssertEqual(preview.first?.computedName, "report.txt")
        XCTAssertEqual(preview.first?.finalName, "report_2.txt")
        XCTAssertEqual(preview.first?.hasConflict, true)
    }
}

private final class BatchRenameEditWorkflowSpy: ArchiveEditWorkflowClient, @unchecked Sendable {
    private(set) var recordedItems: [(sourcePath: String, newName: String)] = []
    var refreshedEntries: [ArchiveEntry] = []
    private(set) var hasChanges = false

    func open(
        archivePath: String,
        password: String?,
        securityInfo: ZwzArchiveSecurityInfo?,
        identityStore: any ZwzIdentityStore
    ) throws -> [ArchiveEntry] {
        refreshedEntries
    }

    func entries() throws -> [ArchiveEntry] {
        refreshedEntries
    }

    func batchRename(items: [(sourcePath: String, newName: String)]) throws {
        recordedItems = items
        hasChanges = !items.isEmpty
    }

    func save(identityStore: any ZwzIdentityStore) throws {}
}
