import Foundation
import XCTest
@testable import ZwzCore

final class ZwzV2APITests: XCTestCase {
    func testPublicAPIWritesV2ArchiveAndListIncludesHiddenFileForGUIFiltering() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let archive = fixture.directory.appendingPathComponent("api.zwz")
        let api = ZwzAPI()

        _ = try api.compress(
            sourcePath: fixture.root.path,
            destinationPath: archive.path,
            options: CompressionOptions(format: .zwz)
        )

        let bytes = try Data(contentsOf: archive)
        XCTAssertEqual(Array(bytes.prefix(4)), ZwzV2Format.magic)

        let entries = try api.list(archivePath: archive.path)
        XCTAssertTrue(entries.contains { $0.path == ".hidden.txt" })
    }

    func testPublicAPIExtractsV2Archive() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let archive = fixture.directory.appendingPathComponent("extract.zwz")
        let destination = fixture.directory.appendingPathComponent("output", isDirectory: true)
        let api = ZwzAPI()

        _ = try api.compress(
            sourcePath: fixture.root.path,
            destinationPath: archive.path,
            options: CompressionOptions(format: .zwz)
        )
        _ = try api.extract(archivePath: archive.path, destinationPath: destination.path)

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("visible.txt")),
            Data("shown".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent(".hidden.txt")),
            Data("hidden".utf8)
        )
    }

    func testPublicAPIPasswordOptionEncryptsV2Index() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let archive = fixture.directory.appendingPathComponent("encrypted.zwz")
        let api = ZwzAPI()
        _ = try api.compress(
            sourcePath: fixture.root.path,
            destinationPath: archive.path,
            options: CompressionOptions(password: "correct horse battery staple", format: .zwz)
        )

        XCTAssertThrowsError(try api.list(archivePath: archive.path)) { error in
            XCTAssertEqual(error as? ZwzV2Error, .wrongPasswordOrTamperedData)
        }
        _ = try api.extract(
            archivePath: archive.path,
            destinationPath: fixture.directory.appendingPathComponent("decrypted").path,
            password: "correct horse battery staple"
        )
    }

    func testPublicAPISplitArchiveCanBeListedAndExtractedFromFinalVolume() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zwz-v2-split-api-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let payload = Data((0..<(768 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try payload.write(to: source.appendingPathComponent("payload.bin"))

        let archive = directory.appendingPathComponent("split.zwz")
        let api = ZwzAPI()
        _ = try api.compress(
            sourcePath: source.path,
            destinationPath: archive.path,
            options: CompressionOptions(
                level: .none,
                splitVolume: .kiloBytes(128),
                format: .zwz
            )
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("split.z00").path))
        XCTAssertTrue(try api.list(archivePath: archive.path).contains { $0.path == "payload.bin" })

        let output = directory.appendingPathComponent("output", isDirectory: true)
        _ = try api.extract(archivePath: archive.path, destinationPath: output.path)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("payload.bin")), payload)
    }

    func testPublicAPIRejectsV1ArchiveAsUnsupported() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zwz-v1-api-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("legacy.zwz")
        try Data(ZwzFormat.magic + [0, 0, 0, 0]).write(to: archive)

        XCTAssertThrowsError(try ZwzAPI().list(archivePath: archive.path)) { error in
            XCTAssertEqual(error as? ZwzV2Error, .unsupportedVersion(1))
        }
    }

    private func makeFixture() throws -> (directory: URL, root: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zwz-v2-api-\(UUID().uuidString)", isDirectory: true)
        let root = directory.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("shown".utf8).write(to: root.appendingPathComponent("visible.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden.txt"))
        return (directory, root)
    }
}
