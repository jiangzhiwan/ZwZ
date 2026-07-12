import Foundation
import XCTest
@testable import ZwzCore

final class ZwzV3RecipientInfoTests: XCTestCase {
    func testRecipientInfoReadsPublicLabelsWithoutPrivateKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZwzV3RecipientInfoTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("payload.txt")
        try Data("payload".utf8).write(to: source)
        let archive = root.appendingPathComponent("archive.zwz")
        let recipient = ZwzV3IdentityFixture.make(name: "Untrusted Label")
        try ZwzV3Compressor().compress(
            sourcePath: sourceRoot.path, destinationPath: archive.path,
            options: CompressionOptions(
                encryption: .publicKey(recipients: [recipient.recipient], signer: nil),
                format: .zwz
            ), keyProvider: nil, progress: nil, cancellationToken: nil
        )

        XCTAssertEqual(
            try ZwzV3Extractor().recipientInfo(archivePath: archive.path),
            [ZwzRecipientInfo(name: "Untrusted Label", fingerprint: recipient.recipient.fingerprint)]
        )
    }
}
