import Foundation
import XCTest
@testable import ZwzCore

final class ZwzV3RecipientInfoTests: XCTestCase {
    func testRecipientInfoReadsPublicLabelsWithoutPrivateKey() throws {
        let fixture = try makeFixture(split: false)
        defer { fixture.cleanup() }

        XCTAssertEqual(
            try ZwzV3Extractor().recipientInfo(archivePath: fixture.finalArchive.path),
            [fixture.info]
        )
    }

    func testRecipientInfoReadsSplitArchiveFromFinalZwzVolume() throws {
        let fixture = try makeFixture(split: true)
        defer { fixture.cleanup() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("archive.z00").path))

        XCTAssertEqual(
            try ZwzV3Extractor().recipientInfo(archivePath: fixture.finalArchive.path),
            [fixture.info]
        )
    }

    func testRecipientInfoFailsStructurallyWhenSplitVolumeIsMissing() throws {
        let fixture = try makeFixture(split: true)
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("archive.z00"))

        XCTAssertThrowsError(try ZwzV3Extractor().recipientInfo(archivePath: fixture.finalArchive.path)) { error in
            guard case ZwzV2Error.missingVolume(0) = error else {
                return XCTFail("expected missingVolume(0), got \(error)")
            }
        }
    }

    func testRecipientInfoRejectsTruncatedArchive() throws {
        let fixture = try makeFixture(split: false)
        defer { fixture.cleanup() }
        try Data([0x5A, 0x57]).write(to: fixture.finalArchive)

        XCTAssertThrowsError(try ZwzV3Extractor().recipientInfo(archivePath: fixture.finalArchive.path)) { error in
            guard case ZwzV3Error.malformedArchive = error else {
                return XCTFail("expected malformedArchive, got \(error)")
            }
        }
    }

    private func makeFixture(split: Bool) throws -> RecipientFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZwzV3RecipientInfoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            let payload = Data((0..<4_096).map { UInt8($0 % 251) })
            try payload.write(to: sourceRoot.appendingPathComponent("payload.bin"))
            let archive = root.appendingPathComponent("archive.zwz")
            let recipient = ZwzV3IdentityFixture.make(name: "Untrusted Label")
            try ZwzV3Compressor().compress(
                sourcePath: sourceRoot.path,
                destinationPath: archive.path,
                options: CompressionOptions(
                    level: .none,
                    encryption: .publicKey(recipients: [recipient.recipient], signer: nil),
                    splitVolume: split ? .kiloBytes(1) : nil,
                    format: .zwz
                ),
                keyProvider: nil,
                progress: nil,
                cancellationToken: nil
            )
            return RecipientFixture(
                root: root,
                finalArchive: archive,
                info: ZwzRecipientInfo(
                    name: "Untrusted Label",
                    fingerprint: recipient.recipient.fingerprint
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}

private struct RecipientFixture {
    let root: URL
    let finalArchive: URL
    let info: ZwzRecipientInfo

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
