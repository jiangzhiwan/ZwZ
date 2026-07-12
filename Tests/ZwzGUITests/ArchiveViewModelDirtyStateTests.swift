import XCTest
import ZIPFoundation
@testable import ZwzGUI

@MainActor
final class ArchiveViewModelDirtyStateTests: XCTestCase {
    func testViewModelOnlyMarksAppliedContentChangesAsUnsaved() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = try await openEditor(for: fixture.archive)

        XCTAssertFalse(viewModel.hasUnsavedArchiveEdits)
        XCTAssertTrue(viewModel.saveTextInArchive("before", path: "file.txt"))
        XCTAssertFalse(viewModel.hasUnsavedArchiveEdits)

        XCTAssertTrue(viewModel.saveTextInArchive("after", path: "file.txt"))
        XCTAssertTrue(viewModel.hasUnsavedArchiveEdits)

        viewModel.discardArchiveEdits()
        XCTAssertFalse(viewModel.hasUnsavedArchiveEdits)
    }

    func testWorkspaceOnlyPromptsWhenEditorContentChanged() async throws {
        let cleanFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: cleanFixture.root) }
        let cleanWorkspace = WorkspaceViewModel()
        let cleanTabID = cleanWorkspace.selectedTabID
        _ = try await openEditor(for: cleanFixture.archive, in: cleanWorkspace.selectedTab.viewModel)

        cleanWorkspace.requestClose(id: cleanTabID)

        XCTAssertFalse(cleanWorkspace.hasPendingUnsavedChanges)
        XCTAssertFalse(cleanWorkspace.tabs.contains(where: { $0.id == cleanTabID }))

        let dirtyFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dirtyFixture.root) }
        let dirtyWorkspace = WorkspaceViewModel()
        let dirtyTabID = dirtyWorkspace.selectedTabID
        let dirtyViewModel = try await openEditor(
            for: dirtyFixture.archive,
            in: dirtyWorkspace.selectedTab.viewModel
        )
        XCTAssertTrue(dirtyViewModel.saveTextInArchive("after", path: "file.txt"))

        dirtyWorkspace.requestClose(id: dirtyTabID)

        XCTAssertTrue(dirtyWorkspace.hasPendingUnsavedChanges)
        XCTAssertTrue(dirtyWorkspace.tabs.contains(where: { $0.id == dirtyTabID }))

        dirtyWorkspace.resolveUnsavedChanges(save: false)
        XCTAssertFalse(dirtyWorkspace.hasPendingUnsavedChanges)
        XCTAssertFalse(dirtyWorkspace.tabs.contains(where: { $0.id == dirtyTabID }))
    }

    private func openEditor(
        for archive: URL,
        in viewModel: ArchiveViewModel = ArchiveViewModel()
    ) async throws -> ArchiveViewModel {
        viewModel.sourcePath = archive.path
        viewModel.archiveName = archive.lastPathComponent
        viewModel.detectedFormat = .zip
        viewModel.beginArchiveEditing()

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !viewModel.showArchiveEditor, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(viewModel.showArchiveEditor)
        return viewModel
    }

    private func makeFixture() throws -> (root: URL, archive: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveViewModelDirtyStateTests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("before".utf8).write(to: source.appendingPathComponent("file.txt"))

        let archiveURL = root.appendingPathComponent("archive.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        _ = try archive.addEntry(
            with: "file.txt",
            fileURL: source.appendingPathComponent("file.txt"),
            compressionMethod: .deflate
        )
        return (root, archiveURL)
    }
}
