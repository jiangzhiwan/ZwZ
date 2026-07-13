import XCTest
@testable import ZwzCore

final class ZwzV2RecoveryTests: XCTestCase {
    func testStrictModeRemovesPartialOutputAfterCorruptBlock() async throws {
        let fixture = try makeFixture()
        let archive = fixture.dir.appendingPathComponent("strict.zwz")
        let urls = try await ZwzV2Compressor(options: ZwzV2Options(blockSize: 4 * 1024, threadCount: 2))
            .compress(sourceURLs: [fixture.root], to: archive)
        try await ZwzV2TestSupport.tamperFirstPayload(in: urls[0], entryPath: "bad.txt")
        let destination = fixture.dir.appendingPathComponent("out")

        do {
            _ = try await ZwzV2Extractor(options: ZwzV2Options(recoveryPolicy: .strict))
                .extractAll(archiveURLs: urls, to: destination, password: nil)
            XCTFail("Strict extraction should fail on corrupt block")
        } catch {
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("bad.txt").path))
    }

    func testRecoveryModeKeepsValidSiblingAndReportsFailedEntry() async throws {
        let fixture = try makeFixture()
        let archive = fixture.dir.appendingPathComponent("recover.zwz")
        let urls = try await ZwzV2Compressor(options: ZwzV2Options(blockSize: 4 * 1024, threadCount: 2))
            .compress(sourceURLs: [fixture.root], to: archive)
        try await ZwzV2TestSupport.tamperFirstPayload(in: urls[0], entryPath: "bad.txt")
        let destination = fixture.dir.appendingPathComponent("out")

        let report = try await ZwzV2Extractor(options: ZwzV2Options(recoveryPolicy: .recover))
            .extractAll(archiveURLs: urls, to: destination, password: nil)

        XCTAssertTrue(report.failedEntries.contains("bad.txt"))
        XCTAssertTrue(report.extractedEntries.contains("good.txt"))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("good.txt")),
            try Data(contentsOf: fixture.root.appendingPathComponent("good.txt"))
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("bad.txt").path))
    }

    func testMissingSplitVolumeReportsSpecificError() async throws {
        let dir = try ZwzV2TestSupport.makeTempDir()
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data((0..<64_000).map { UInt8($0 % 251) }).write(to: root.appendingPathComponent("split.bin"))
        let urls = try await ZwzV2Compressor(
            options: ZwzV2Options(blockSize: 4 * 1024, splitVolumeSize: 3 * 1024, threadCount: 2)
        ).compress(sourceURLs: [root], to: dir.appendingPathComponent("split.zwz"))
        XCTAssertGreaterThan(urls.count, 2)

        do {
            _ = try await ZwzV2Extractor().preview(archiveURLs: [urls[0]] + Array(urls.dropFirst(2)), password: nil)
            XCTFail("Missing split volume should be reported")
        } catch ZwzV2Error.missingVolume(let number) {
            XCTAssertEqual(number, 1)
        }
    }

    private func makeFixture() throws -> (dir: URL, root: URL) {
        let dir = try ZwzV2TestSupport.makeTempDir()
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data((0..<32_000).map { UInt8(($0 * 13) % 251) }).write(to: root.appendingPathComponent("bad.txt"))
        try Data("good".utf8).write(to: root.appendingPathComponent("good.txt"))
        return (dir, root)
    }
}
