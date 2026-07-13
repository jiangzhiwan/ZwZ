import XCTest
@testable import ZwzCore

final class ZwzV2SecurityTests: XCTestCase {
    func testPasswordArchivePreviewRequiresPassword() async throws {
        let fixture = try makeFixture()
        let archive = fixture.dir.appendingPathComponent("secure.zwz")
        let urls = try await ZwzV2Compressor(options: ZwzV2Options(password: "secret", threadCount: 2))
            .compress(sourceURLs: [fixture.root], to: archive)

        do {
            _ = try await ZwzV2Extractor().preview(archiveURLs: urls, password: nil)
            XCTFail("Encrypted preview should require a password")
        } catch ZwzV2Error.wrongPasswordOrTamperedData {
        }
    }

    func testPasswordArchiveDoesNotExposeFileNameBytes() async throws {
        let fixture = try makeFixture()
        let archive = fixture.dir.appendingPathComponent("private.zwz")
        _ = try await ZwzV2Compressor(options: ZwzV2Options(password: "secret", threadCount: 2))
            .compress(sourceURLs: [fixture.root], to: archive)

        let bytes = try Data(contentsOf: archive)
        XCTAssertNil(bytes.range(of: Data("secret-name.txt".utf8)))
    }

    func testWrongPasswordFailsBeforeOutput() async throws {
        let fixture = try makeFixture()
        let archive = fixture.dir.appendingPathComponent("secure.zwz")
        let urls = try await ZwzV2Compressor(options: ZwzV2Options(password: "secret", threadCount: 2))
            .compress(sourceURLs: [fixture.root], to: archive)
        let destination = fixture.dir.appendingPathComponent("out")

        do {
            _ = try await ZwzV2Extractor().extractAll(archiveURLs: urls, to: destination, password: "wrong")
            XCTFail("Wrong password should fail before output")
        } catch ZwzV2Error.wrongPasswordOrTamperedData {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testTamperedBlockFailsAuthenticationOrChecksum() async throws {
        let fixture = try makeFixture()
        let archive = fixture.dir.appendingPathComponent("plain.zwz")
        let urls = try await ZwzV2Compressor(options: ZwzV2Options(blockSize: 4 * 1024, threadCount: 2))
            .compress(sourceURLs: [fixture.root], to: archive)
        try await ZwzV2TestSupport.tamperFirstPayload(in: urls[0], entryPath: "secret-name.txt")

        do {
            _ = try await ZwzV2Extractor().extractAll(archiveURLs: urls, to: fixture.dir.appendingPathComponent("out"), password: nil)
            XCTFail("Tampered block should fail")
        } catch ZwzV2Error.checksumMismatch {
        } catch ZwzV2Error.decompressionFailed {
        } catch ZwzV2Error.wrongPasswordOrTamperedData {
        }
    }

    func testUnsafeIndexPathIsRejectedBeforeWriting() async throws {
        let dir = try ZwzV2TestSupport.makeTempDir()
        let archive = try ZwzV2TestSupport.writePlainArchiveWithUnsafeIndexPath(in: dir)
        let destination = dir.appendingPathComponent("out")

        do {
            _ = try await ZwzV2Extractor().extractAll(archiveURLs: [archive], to: destination, password: nil)
            XCTFail("Unsafe index path should be rejected")
        } catch ZwzV2Error.unsafePath {
        } catch ZwzV2Error.malformedArchive {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func makeFixture() throws -> (dir: URL, root: URL) {
        let dir = try ZwzV2TestSupport.makeTempDir()
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(String(repeating: "private", count: 10_000).utf8).write(to: root.appendingPathComponent("secret-name.txt"))
        return (dir, root)
    }
}
