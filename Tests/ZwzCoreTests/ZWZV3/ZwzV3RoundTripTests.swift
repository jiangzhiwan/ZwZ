import Foundation
import XCTest
@testable import ZwzCore

final class ZwzV3RoundTripTests: XCTestCase {
    func testTwoRecipientsIndependentlyListAndExtractHiddenEmptyUnicodeAndMultiBlockFiles() throws {
        let directory = try ZwzV3TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZwzV3TestSupport.makeSource(in: directory)
        let archive = directory.appendingPathComponent("two-recipients.zwz")
        let alice = ZwzV3IdentityFixture.make(name: "Alice")
        let bob = ZwzV3IdentityFixture.make(name: "Bob")
        let options = CompressionOptions(
            level: .normal,
            encryption: .publicKey(recipients: [alice.recipient, bob.recipient], signer: nil),
            format: .zwz
        )

        try ZwzV3Compressor(blockSize: 4_096).compress(
            sourcePath: source.path,
            destinationPath: archive.path,
            options: options,
            keyProvider: nil,
            progress: nil,
            cancellationToken: nil
        )

        for identity in [alice, bob] {
            let listing = try ZwzV3Extractor().listEntries(
                archivePath: archive.path,
                keyProvider: identity.provider
            )
            XCTAssertEqual(listing.entries.count, 7)
            XCTAssertEqual(listing.securityInfo.recipientFingerprints.count, 2)
            let output = directory.appendingPathComponent("out-\(identity.recipient.name)")
            _ = try ZwzV3Extractor().extractAll(
                archivePath: archive.path,
                destinationPath: output.path,
                keyProvider: identity.provider,
                progress: nil,
                cancellationToken: nil
            )
            try ZwzV3TestSupport.assertTreesEqual(source, output)
        }
    }

    func testSingleFileAndDirectorySubtreeExtraction() throws {
        let fixture = try makeArchive()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let extractor = ZwzV3Extractor()
        let file = try extractor.extractEntryToTemp(
            archivePath: fixture.archive.path,
            entryPath: ".hidden",
            keyProvider: fixture.identity.provider
        )
        XCTAssertEqual(try Data(contentsOf: file), Data("hidden".utf8))

        let subtree = try extractor.extractEntryToTemp(
            archivePath: fixture.archive.path,
            entryPath: "nested/\u{8d44}\u{6599}",
            keyProvider: fixture.identity.provider
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: subtree.appendingPathComponent("\u{6587}\u{4ef6}.txt").path))
    }

    func testSplitVolumeRoundTripAndMissingVolumeFailure() throws {
        let directory = try ZwzV3TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZwzV3TestSupport.makeSource(in: directory)
        let identity = ZwzV3IdentityFixture.make(name: "Alice")
        let archive = directory.appendingPathComponent("split.zwz")
        let options = CompressionOptions(
            level: .none,
            encryption: .publicKey(recipients: [identity.recipient], signer: nil),
            splitVolume: .kiloBytes(4),
            format: .zwz
        )
        try ZwzV3Compressor(blockSize: 2_048).compress(
            sourcePath: source.path,
            destinationPath: archive.path,
            options: options,
            keyProvider: nil,
            progress: nil,
            cancellationToken: nil
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("split.z00").path))
        let splitURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("split.") }
            .sorted { $0.pathExtension < $1.pathExtension }
        XCTAssertThrowsError(try ZwzV3Extractor.loadLogicalArchive(from: Array(splitURLs.reversed())))
        let output = directory.appendingPathComponent("split-out")
        _ = try ZwzV3Extractor().extractAll(
            archivePath: archive.path,
            destinationPath: output.path,
            keyProvider: identity.provider,
            progress: nil,
            cancellationToken: nil
        )
        try ZwzV3TestSupport.assertTreesEqual(source, output)

        try FileManager.default.removeItem(at: directory.appendingPathComponent("split.z00"))
        XCTAssertThrowsError(try ZwzV3Extractor().listEntries(archivePath: archive.path, keyProvider: identity.provider))
    }

    func testCancellationCleansStagingAndPreservesExistingDestination() throws {
        let directory = try ZwzV3TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZwzV3TestSupport.makeSource(in: directory)
        let identity = ZwzV3IdentityFixture.make(name: "Alice")
        let archive = directory.appendingPathComponent("cancel.zwz")
        let original = Data("existing archive".utf8)
        try original.write(to: archive)
        let token = CancellationToken()
        XCTAssertThrowsError(try ZwzV3Compressor(blockSize: 1_024).compress(
            sourcePath: source.path,
            destinationPath: archive.path,
            options: CompressionOptions(
                encryption: .publicKey(recipients: [identity.recipient], signer: nil),
                format: .zwz
            ),
            keyProvider: nil,
            progress: { value in if value > 0 { token.cancel() } },
            cancellationToken: token
        ))
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains { $0.contains("partial-") })
    }

    func testVerifiedArchiveAtomicallyReplacesExistingArchive() throws {
        let directory = try ZwzV3TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZwzV3TestSupport.makeSource(in: directory)
        let identity = ZwzV3IdentityFixture.make(name: "Alice")
        let archive = directory.appendingPathComponent("replace.zwz")
        let options = CompressionOptions(
            encryption: .publicKey(recipients: [identity.recipient], signer: nil),
            format: .zwz
        )
        let compressor = ZwzV3Compressor(blockSize: 4_096)
        try compressor.compress(
            sourcePath: source.path,
            destinationPath: archive.path,
            options: options,
            keyProvider: nil,
            progress: nil,
            cancellationToken: nil
        )
        try Data("replacement".utf8).write(to: source.appendingPathComponent(".hidden"))
        try compressor.compress(
            sourcePath: source.path,
            destinationPath: archive.path,
            options: options,
            keyProvider: nil,
            progress: nil,
            cancellationToken: nil
        )
        let output = directory.appendingPathComponent("replacement-out")
        _ = try ZwzV3Extractor().extractAll(
            archivePath: archive.path,
            destinationPath: output.path,
            keyProvider: identity.provider,
            progress: nil,
            cancellationToken: nil
        )
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(".hidden")), Data("replacement".utf8))
    }

    private func makeArchive() throws -> (directory: URL, archive: URL, identity: ZwzV3IdentityFixture) {
        let directory = try ZwzV3TestSupport.makeTempDirectory()
        let source = try ZwzV3TestSupport.makeSource(in: directory)
        let identity = ZwzV3IdentityFixture.make(name: "Alice")
        let archive = directory.appendingPathComponent("archive.zwz")
        try ZwzV3Compressor(blockSize: 4_096).compress(
            sourcePath: source.path,
            destinationPath: archive.path,
            options: CompressionOptions(
                encryption: .publicKey(recipients: [identity.recipient], signer: nil),
                format: .zwz
            ),
            keyProvider: nil,
            progress: nil,
            cancellationToken: nil
        )
        return (directory, archive, identity)
    }
}
