import Foundation
@testable import ZwzCore
import XCTest

enum ZwzV2TestSupport {
    static func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func assertTreesEqual(_ expected: URL, _ actual: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try relativeDirectories(in: actual), try relativeDirectories(in: expected), file: file, line: line)
        let expectedFiles = try relativeFiles(in: expected)
        XCTAssertEqual(try relativeFiles(in: actual), expectedFiles, file: file, line: line)
        for path in expectedFiles {
            XCTAssertEqual(
                try Data(contentsOf: expected.appendingPathComponent(path)),
                try Data(contentsOf: actual.appendingPathComponent(path)),
                file: file,
                line: line
            )
        }
    }

    static func relativeFiles(in root: URL) throws -> [String] {
        try relativeItems(in: root, directories: false)
    }

    static func relativeDirectories(in root: URL) throws -> [String] {
        try relativeItems(in: root, directories: true)
    }

    static func tamperFirstPayload(
        in archiveURL: URL,
        entryPath: String,
        password: String? = nil
    ) async throws {
        let index = try await ZwzV2Extractor().preview(archiveURLs: [archiveURL], password: password)
        guard let block = index.entries.first(where: { $0.path == entryPath })?.blocks.first else {
            throw ZwzV2Error.malformedArchive("test archive entry has no block")
        }
        var data = try Data(contentsOf: archiveURL)
        let payloadOffset = Int(block.archiveOffset) + ZwzV2BlockRecordHeader.encodedLength
        data[payloadOffset] ^= 0x7f
        try data.write(to: archiveURL)
    }

    static func writePlainArchiveWithUnsafeIndexPath(in dir: URL) throws -> URL {
        let archiveID = UUID()
        let validPath = "safe/x"
        let index = ZwzV2Index(
            archiveID: archiveID,
            blockSize: 1_024,
            entries: [
                ZwzV2Entry(
                    path: validPath,
                    type: .file,
                    originalSize: 0,
                    modificationTime: Date(timeIntervalSince1970: 0),
                    isHidden: false,
                    blocks: []
                )
            ]
        )
        var indexPayload = try ZwzV2IndexCodec.encodePlain(index)
        guard let pathRange = indexPayload.range(of: Data(validPath.utf8)) else {
            throw ZwzV2Error.malformedArchive("test index path not found")
        }
        indexPayload.replaceSubrange(pathRange, with: Data("a/../b".utf8))

        var archive = Data()
        archive.append(try ZwzV2BinaryCodec.encodeHeader(ZwzV2Header(
            archiveID: archiveID,
            flags: [],
            blockSize: 1_024,
            kdfSalt: Data(),
            kdfIterations: 0
        )))
        let indexOffset = UInt64(archive.count)
        archive.append(indexPayload)
        archive.append(try ZwzV2BinaryCodec.encodeFooter(ZwzV2Footer(
            archiveID: archiveID,
            indexOffset: indexOffset,
            indexLength: UInt64(indexPayload.count),
            indexChecksum: checksum(of: indexPayload)
        )))

        let url = dir.appendingPathComponent("unsafe.zwz")
        try archive.write(to: url)
        return url
    }

    static func checksum(of data: Data) -> UInt32 {
        var value: UInt32 = 2_166_136_261
        for byte in data {
            value ^= UInt32(byte)
            value &*= 16_777_619
        }
        return value
    }

    private static func relativeItems(in root: URL, directories: Bool) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }
        var result: [String] = []
        for case let url as URL in enumerator {
            let isDirectory = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            guard isDirectory == directories else { continue }
            let path = try ZwzV2PathValidator.normalizedArchivePath(root: root, item: url)
            result.append(path)
        }
        return result.sorted()
    }
}
