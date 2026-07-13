import XCTest
@testable import ZwzCore

final class ZwzV2RoundTripTests: XCTestCase {
    func testRoundTripEmptyDirectoryAndEmptyFile() async throws {
        let dir = try ZwzV2TestSupport.makeTempDir()
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty-dir"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("empty.txt").path, contents: nil)

        try await roundTrip(root: root, archive: dir.appendingPathComponent("empty.zwz"), destination: dir.appendingPathComponent("out"))
    }

    func testRoundTripUnicodeLongPathsAndHiddenFiles() async throws {
        let dir = try ZwzV2TestSupport.makeTempDir()
        let root = dir.appendingPathComponent("root")
        let nested = root.appendingPathComponent("资料").appendingPathComponent(String(repeating: "深", count: 24))
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: nested.appendingPathComponent("文件.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden.txt"))

        try await roundTrip(root: root, archive: dir.appendingPathComponent("unicode.zwz"), destination: dir.appendingPathComponent("out"))
    }

    func testRoundTripFileSpanningManyBlocks() async throws {
        let dir = try ZwzV2TestSupport.makeTempDir()
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data((0..<96_000).map { UInt8($0 % 251) })
        try data.write(to: root.appendingPathComponent("many-blocks.bin"))

        try await roundTrip(
            root: root,
            archive: dir.appendingPathComponent("many.zwz"),
            destination: dir.appendingPathComponent("out"),
            options: ZwzV2Options(blockSize: 4 * 1024, threadCount: 3)
        )
    }

    func testRoundTripSplitArchiveSpanningVolumes() async throws {
        let dir = try ZwzV2TestSupport.makeTempDir()
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data((0..<64_000).map { UInt8(($0 * 17) % 251) }).write(to: root.appendingPathComponent("split.bin"))

        let archive = dir.appendingPathComponent("split.zwz")
        let options = ZwzV2Options(blockSize: 4 * 1024, splitVolumeSize: 3 * 1024, threadCount: 3)
        let urls = try await ZwzV2Compressor(options: options).compress(sourceURLs: [root], to: archive)
        XCTAssertGreaterThan(urls.count, 1)
        try await ZwzV2Extractor(options: options).extractAll(archiveURLs: urls, to: dir.appendingPathComponent("out"), password: nil)

        try ZwzV2TestSupport.assertTreesEqual(root, dir.appendingPathComponent("out"))
    }

    private func roundTrip(
        root: URL,
        archive: URL,
        destination: URL,
        options: ZwzV2Options = ZwzV2Options(blockSize: 16 * 1024, threadCount: 2)
    ) async throws {
        let urls = try await ZwzV2Compressor(options: options).compress(sourceURLs: [root], to: archive)
        try await ZwzV2Extractor(options: options).extractAll(archiveURLs: urls, to: destination, password: options.password)
        try ZwzV2TestSupport.assertTreesEqual(root, destination)
    }
}
