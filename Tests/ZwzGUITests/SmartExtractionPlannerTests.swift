import XCTest
import ZwzCore
@testable import ZwzGUI

final class SmartExtractionPlannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartExtractionPlannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSingleTopLevelDirectoryExtractsBesideArchiveWithoutExtraWrapper() {
        let archive = root.appendingPathComponent("photos.zip")
        let entries = [entry("Holiday/photo.jpg"), entry("Holiday/notes.txt")]

        let plan = SmartExtractionPlanner.makePlan(archiveURL: archive, entries: entries)

        XCTAssertEqual(plan.extractionDirectory, root)
        XCTAssertEqual(plan.resultDirectory.lastPathComponent, "Holiday")
        XCTAssertNil(plan.extractedTopLevelName)
    }

    func testMultipleTopLevelItemsUseUniqueArchiveNamedDirectory() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bundle"), withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("bundle.tar.gz")
        let entries = [entry("readme.txt"), entry("Sources/main.swift")]

        let plan = SmartExtractionPlanner.makePlan(archiveURL: archive, entries: entries)

        XCTAssertEqual(plan.resultDirectory.lastPathComponent, "bundle 2")
        XCTAssertEqual(plan.extractionDirectory, plan.resultDirectory)
    }

    func testExistingTopLevelDirectoryUsesStagingAndUniqueResultName() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Holiday"), withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("photos.zip")

        let plan = SmartExtractionPlanner.makePlan(
            archiveURL: archive,
            entries: [entry("Holiday/photo.jpg")],
            temporaryDirectory: root
        )

        XCTAssertEqual(plan.resultDirectory.lastPathComponent, "Holiday 2")
        XCTAssertEqual(plan.extractedTopLevelName, "Holiday")
        XCTAssertNotEqual(plan.extractionDirectory, root)
    }

    private func entry(_ path: String) -> ArchiveEntry {
        ArchiveEntry(
            name: (path as NSString).lastPathComponent,
            path: path,
            size: 1,
            isDirectory: false,
            modifiedDate: nil
        )
    }
}
