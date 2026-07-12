import XCTest
@testable import ZwzCore

final class OperationCancellationTests: XCTestCase {
    func testZipCancellationRemovesNewOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<3 {
            try Data(repeating: UInt8(index), count: 4096).write(to: root.appendingPathComponent("\(index).bin"))
        }
        let output = root.appendingPathComponent("out.zip")
        let token = CancellationToken()

        XCTAssertThrowsError(try ZipCompressor().compress(
            sourcePath: root.path,
            destinationPath: output.path,
            options: CompressionOptions(threadCount: 1),
            progress: { _ in token.cancel() },
            cancellationToken: token
        )) { error in
            guard case ZwzError.operationCancelled = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
