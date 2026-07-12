import XCTest
@testable import ZwzCore

final class RarPreviewFallbackTests: XCTestCase {
    func testPreviewRarUsesBSDTarWhenLsarIsUnavailable() throws {
        let archivePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/zwz测试.rar").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: archivePath), "Desktop RAR fixture is unavailable")

        let entries = try ArchivePreviewer().preview(archivePath: archivePath)
        let paths = Set(entries.map(\.path))

        XCTAssertTrue(paths.contains { $0.hasSuffix("测试说明.txt") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("子目录/sample.txt") })
        XCTAssertFalse(entries.count == 1 && entries[0].size == 0)
    }
}
