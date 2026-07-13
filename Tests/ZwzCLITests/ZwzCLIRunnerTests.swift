import Foundation
import XCTest
import ZwzCore
@testable import zwz

final class ZwzCLIRunnerTests: XCTestCase {
    func testCreateListRenameAndDeleteConfirmation() throws {
        let harness = Harness()
        XCTAssertEqual(harness.run(["key", "create", "Alice"]), 0)
        XCTAssertEqual(harness.run(["key", "list"]), 0)
        XCTAssertTrue(harness.output.text.contains("Alice"))

        XCTAssertEqual(harness.run(["key", "rename", "alice", "Alicia"]), 0)
        harness.confirmations.values = ["no"]
        XCTAssertEqual(harness.run(["key", "delete", "Alicia"]), 1)
        XCTAssertEqual(try harness.store.identities().count, 1)
        harness.confirmations.values = ["yes"]
        XCTAssertEqual(harness.run(["key", "delete", "Alicia"]), 0)
        XCTAssertTrue(try harness.store.identities().isEmpty)
    }

    func testAmbiguousNamesPrintEveryFingerprint() throws {
        let harness = Harness()
        let first = try harness.store.createIdentity(named: "Same")
        let second = try harness.store.createIdentity(named: "same")
        XCTAssertEqual(harness.run(["key", "rename", "SAME", "Other"]), 1)
        XCTAssertTrue(harness.errors.text.contains(first.fingerprint))
        XCTAssertTrue(harness.errors.text.contains(second.fingerprint))
    }

    func testContactsResolveAsRecipientsSignerMustBeLocalAndDuplicatesCollapse() throws {
        let remote = InMemoryZwzIdentityStore()
        let contact = try remote.createIdentity(named: "Remote")
        let publicData = try remote.exportPublicIdentity(fingerprint: contact.fingerprint)
        let harness = Harness()
        _ = try harness.store.importPublicIdentity(publicData, conflict: .requireConfirmation)
        let source = try harness.makeFile("source.txt", contents: "data")

        XCTAssertEqual(harness.run(["compress", "-f", "zwz", "--recipient", "Remote", "--recipient", contact.fingerprint, source.path]), 0)
        guard case .publicKey(let recipients, _) = try XCTUnwrap(harness.archives.lastOptions).encryption else {
            return XCTFail("expected public-key mode")
        }
        XCTAssertEqual(recipients.map(\.fingerprint), [contact.fingerprint])

        XCTAssertEqual(harness.run(["compress", "-f", "zwz", "--recipient", "Remote", "--sign", "Remote", source.path]), 1)
        XCTAssertEqual(harness.archives.compressCalls, 1)
    }

    func testPublicExportImportConflictAndEncryptedBackupRestore() throws {
        let harness = Harness(passwords: ["strong backup password", "strong backup password"])
        let identity = try harness.store.createIdentity(named: "Alice")
        let publicURL = harness.root.appendingPathComponent("alice.zwzpub")
        let backupURL = harness.root.appendingPathComponent("alice.zwzkey")

        XCTAssertEqual(harness.run(["key", "export-public", identity.fingerprint, publicURL.path]), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: publicURL.path))
        XCTAssertEqual(harness.run(["key", "export-public", identity.fingerprint, publicURL.path]), 1)

        XCTAssertEqual(harness.run(["key", "backup", "Alice", backupURL.path]), 0)
        XCTAssertFalse(harness.output.text.contains("strong backup password"))
        XCTAssertFalse(harness.errors.text.contains("strong backup password"))

        let restore = Harness(passwords: ["strong backup password"])
        defer { restore.cleanup() }
        XCTAssertEqual(restore.run(["key", "restore", backupURL.path]), 0)
        XCTAssertEqual(try restore.store.identities().first?.fingerprint, identity.fingerprint)

        let contactHarness = Harness()
        defer { contactHarness.cleanup() }
        XCTAssertEqual(contactHarness.run(["key", "import-public", publicURL.path]), 0)
        XCTAssertEqual(contactHarness.run(["key", "import-public", publicURL.path]), 1)
        XCTAssertEqual(contactHarness.run(["key", "import-public", "--replace", publicURL.path]), 0)
    }

    func testExistingExportAndBackupOutputsFailBeforeEncodingOrPrivateKeyAccess() throws {
        let backing = InMemoryZwzIdentityStore()
        _ = try backing.createIdentity(named: "Alice")
        let counting = CountingIdentityStore(backing: backing)
        let harness = Harness(passwords: ["must not be read"], store: backing, identityStore: counting)
        let output = harness.root.appendingPathComponent("existing")
        try Data("keep".utf8).write(to: output)

        XCTAssertEqual(harness.run(["key", "export-public", "Alice", output.path]), 1)
        XCTAssertEqual(harness.run(["key", "backup", "Alice", output.path]), 1)
        XCTAssertEqual(counting.exportPublicCalls, 0)
        XCTAssertEqual(counting.exportBackupCalls, 0)
        XCTAssertEqual(harness.passwords.values, ["must not be read"])
        XCTAssertEqual(try Data(contentsOf: output), Data("keep".utf8))
    }

    func testBackupRejectsEmptyAndMismatchedPasswordsWithoutPartialOutput() throws {
        let mismatch = Harness(passwords: ["first password", "second password"])
        _ = try mismatch.store.createIdentity(named: "Alice")
        let output = mismatch.root.appendingPathComponent("backup.zwzkey")
        XCTAssertEqual(mismatch.run(["key", "backup", "Alice", output.path]), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: mismatch.root.path).contains { $0.hasSuffix(".tmp") })

        let empty = Harness(passwords: [""])
        defer { empty.cleanup() }
        _ = try empty.store.createIdentity(named: "Alice")
        XCTAssertEqual(empty.run(["key", "backup", "Alice", empty.root.appendingPathComponent("b").path]), 1)
    }

    func testTerminalSecretReaderRestoresStateOnSuccessAndEOF() throws {
        let session = FakeTerminalSession(lines: ["secret", nil])
        let reader = TerminalSecretReader(session: session, output: { _ in })
        XCTAssertEqual(try reader.read(prompt: "Password: "), "secret")
        XCTAssertEqual(try reader.read(prompt: "Password: "), "")
        XCTAssertEqual(session.disableCount, 2)
        XCTAssertEqual(session.restoreCount, 2)
    }

    func testMissingKeyGuidanceAndConcreteErrorsRemainDistinct() {
        let harness = Harness()
        let fingerprint = String(repeating: "a", count: 64)
        harness.archives.recipientLabels = [ZwzRecipientInfo(name: "Archive Alice", fingerprint: fingerprint)]
        harness.archives.failure = ZwzV3Error.noMatchingPrivateKey([fingerprint])
        XCTAssertEqual(harness.run(["list", "archive.zwz"]), 1)
        XCTAssertTrue(harness.errors.text.contains("Archive Alice \(fingerprint)"))
        XCTAssertTrue(harness.errors.text.contains("zwz key restore <backup.zwzkey>"))

        for error in [ZwzV3Error.userAuthenticationCancelled, .keychainFailure(-50), .invalidSignature, .authenticationFailed] {
            harness.errors.values = []
            harness.archives.failure = error
            XCTAssertEqual(harness.run(["list", "archive.zwz"]), 1)
            XCTAssertEqual(harness.errors.values.last, error.localizedDescription)
        }
    }

    func testHelpDocumentsLegacyAndPublicKeyWorkflows() {
        let harness = Harness()
        XCTAssertEqual(harness.run(["help"]), 0)
        let help = harness.output.text
        for expected in [
            "compress [options] <source-path> [output-path]",
            "extract [options] <archive-path> [output-directory]",
            "rename [options] <archive-path>",
            "c, compress", "x, extract", "l, list", "h, help",
            "-f, --format <zip|zwz>",
            "-l, --level <none|fastest|normal|max>",
            "-p, --password <password>", "--no-aes",
            "-s, --split <positive-size>", "MB or KB",
            "-t, --threads <nonnegative-count>",
            "key create", "key list", "key rename", "key delete",
            "key export-public", "key import-public", "key backup", "key restore",
            "--recipient <name-or-fingerprint>", "Repeat for multiple recipients; requires -f zwz",
            "--sign <local-identity-or-fingerprint>",
            "Requires -f zwz and at least one --recipient",
            "--rule <find-replace|prefix-suffix|numbering|regex-replace|case-conversion>",
            "--dry-run", "--include-extension", "--filter <glob>",
            "mutually exclusive", "read from stdin", "On a TTY, input is hidden",
            "never accepted as command arguments or environment options",
            "zwz c -f zwz --recipient Alice --recipient Bob --sign Me Source shared.zwz"
        ] {
            XCTAssertTrue(help.contains(expected), "help is missing: \(expected)")
        }
    }

    func testActualUnsignedAndSignedMultiRecipientV3RoundTrips() throws {
        let store = InMemoryZwzIdentityStore()
        _ = try store.createIdentity(named: "Alice")
        _ = try store.createIdentity(named: "Bob")
        _ = try store.createIdentity(named: "Sender")
        let harness = Harness(store: store, archives: ZwzAPIArchiveOperations())
        let sourceRoot = harness.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("payload.txt")
        try "public-key cli round trip".write(to: source, atomically: true, encoding: .utf8)

        for (name, signing) in [("unsigned.zwz", false), ("signed.zwz", true)] {
            let archive = harness.root.appendingPathComponent(name)
            var arguments = ["compress", "-f", "zwz", "--recipient", "Alice", "--recipient", "Bob"]
            if signing { arguments += ["--sign", "Sender"] }
            arguments += [sourceRoot.path, archive.path]
            XCTAssertEqual(harness.run(arguments), 0, harness.errors.text)
            XCTAssertEqual(harness.run(["list", archive.path]), 0, harness.errors.text)
            let destination = harness.root.appendingPathComponent(name + "-out")
            XCTAssertEqual(harness.run(["extract", archive.path, destination.path]), 0, harness.errors.text)
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload.txt"), encoding: .utf8), "public-key cli round trip")
            XCTAssertTrue(harness.output.text.contains(signing ? "Signature: valid known signer Sender" : "Signature: unsigned"))
        }
    }

    func testActualLegacyZIPAndV2CommandsStillRun() throws {
        let harness = Harness(archives: ZwzAPIArchiveOperations())
        let sourceRoot = harness.root.appendingPathComponent("legacy-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try "legacy".write(to: sourceRoot.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        for (name, formatArguments) in [("legacy.zip", [String]()), ("legacy.zwz", ["-f", "zwz"])] {
            let archive = harness.root.appendingPathComponent(name)
            XCTAssertEqual(harness.run(["c"] + formatArguments + [sourceRoot.path, archive.path]), 0, harness.errors.text)
            XCTAssertEqual(harness.run(["l", archive.path]), 0, harness.errors.text)
            let destination = harness.root.appendingPathComponent(name + "-out")
            XCTAssertEqual(harness.run(["x", archive.path, destination.path]), 0, harness.errors.text)
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("file.txt"), encoding: .utf8), "legacy")
        }
    }

    func testBatchRenameHandlesDestinationOccupiedByAnotherSelectedEntry() throws {
        let harness = Harness(archives: ZwzAPIArchiveOperations())
        let source = harness.root.appendingPathComponent("rename-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "from-a".write(to: source.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        try "from-b".write(to: source.appendingPathComponent("B.txt"), atomically: true, encoding: .utf8)
        let archive = harness.root.appendingPathComponent("rename.zip")
        XCTAssertEqual(harness.run(["compress", source.path, archive.path]), 0, harness.errors.text)

        XCTAssertEqual(harness.run([
            "rename", "--archive", archive.path,
            "--rule", "find-replace", "--find", "A", "--replace", "B"
        ]), 0, harness.errors.text)

        let extracted = harness.root.appendingPathComponent("rename-output", isDirectory: true)
        XCTAssertEqual(harness.run(["extract", archive.path, extracted.path]), 0, harness.errors.text)
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("B.txt"), encoding: .utf8), "from-a")
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("B_2.txt"), encoding: .utf8), "from-b")
    }

    func testBatchRenamePreservesPasswordEncryption() throws {
        let harness = Harness(archives: ZwzAPIArchiveOperations())
        let source = harness.root.appendingPathComponent("protected-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "secret body".write(
            to: source.appendingPathComponent("draft.txt"),
            atomically: true,
            encoding: .utf8
        )
        let archive = harness.root.appendingPathComponent("protected.zwz")
        XCTAssertEqual(harness.run([
            "compress", "-f", "zwz", "-p", "strong-password", source.path, archive.path
        ]), 0, harness.errors.text)

        XCTAssertEqual(harness.run([
            "rename", "--archive", archive.path, "-p", "strong-password",
            "--rule", "find-replace", "--find", "draft", "--replace", "final"
        ]), 0, harness.errors.text)

        XCTAssertEqual(harness.run(["list", archive.path]), 1)
        XCTAssertEqual(harness.run(["list", "-p", "strong-password", archive.path]), 0, harness.errors.text)
        XCTAssertTrue(harness.output.text.contains("final.txt"))
    }

    func testBatchRenameGlobFilterPreservesMatchingAndOutputOrder() {
        let archives = FakeArchiveOperations()
        archives.listingEntries = [
            ArchiveEntry(name: "alpha.txt", path: "alpha.txt", size: 1, isDirectory: false, modifiedDate: nil),
            ArchiveEntry(name: "beta.md", path: "beta.md", size: 1, isDirectory: false, modifiedDate: nil),
            ArchiveEntry(name: "gamma.txt", path: "gamma.txt", size: 1, isDirectory: false, modifiedDate: nil),
        ]
        let harness = Harness(archives: archives)

        XCTAssertEqual(harness.run([
            "rename", "--archive", "fixture.zip", "--dry-run", "--filter", "*.txt",
            "--rule", "prefix-suffix", "--prefix", "new_"
        ]), 0)
        XCTAssertEqual(harness.output.values, [
            "Batch rename preview (2 items):",
            "  alpha.txt  →  new_alpha.txt",
            "  gamma.txt  →  new_gamma.txt",
            "\nDry run — no changes made.",
        ])
    }
}

private final class Harness {
    let root: URL
    let store: InMemoryZwzIdentityStore
    let archives: FakeArchiveOperations
    let output = StringBox()
    let errors = StringBox()
    let passwords: ValueBox<String>
    let confirmations = ValueBox<String>()
    private let archiveOperations: any ZwzCLIArchiveOperations
    private let identityStore: any ZwzIdentityStore

    init(passwords: [String] = [], store: InMemoryZwzIdentityStore = InMemoryZwzIdentityStore(), identityStore: (any ZwzIdentityStore)? = nil, archives: (any ZwzCLIArchiveOperations)? = nil) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ZwzCLITests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.store = store
        self.identityStore = identityStore ?? store
        let fake = archives as? FakeArchiveOperations ?? FakeArchiveOperations()
        self.archives = fake
        archiveOperations = archives ?? fake
        self.passwords = ValueBox(passwords)
    }

    deinit { cleanup() }
    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func run(_ arguments: [String]) -> Int32 {
        ZwzCLI.run(arguments: arguments, dependencies: ZwzCLIDependencies(
            output: { self.output.values.append($0) },
            error: { self.errors.values.append($0) },
            passwordReader: { _ in self.passwords.next() ?? "" },
            confirmationReader: { _ in self.confirmations.next() },
            identityStore: identityStore,
            archives: archiveOperations,
            fileManager: .default
        ))
    }

    func makeFile(_ name: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private final class CountingIdentityStore: ZwzIdentityStore, @unchecked Sendable {
    let backing: InMemoryZwzIdentityStore
    var exportPublicCalls = 0
    var exportBackupCalls = 0
    init(backing: InMemoryZwzIdentityStore) { self.backing = backing }
    func createIdentity(named name: String) throws -> ZwzIdentityMetadata { try backing.createIdentity(named: name) }
    func identities() throws -> [ZwzIdentityMetadata] { try backing.identities() }
    func contacts() throws -> [ZwzPublicIdentity] { try backing.contacts() }
    func importPublicIdentity(_ data: Data, conflict: ZwzIdentityConflictPolicy) throws -> ZwzPublicIdentity { try backing.importPublicIdentity(data, conflict: conflict) }
    func exportPublicIdentity(fingerprint: String) throws -> Data { exportPublicCalls += 1; return try backing.exportPublicIdentity(fingerprint: fingerprint) }
    func exportPrivateBackup(fingerprint: String, password: String) throws -> Data { exportBackupCalls += 1; return try backing.exportPrivateBackup(fingerprint: fingerprint, password: password) }
    func importPrivateBackup(_ data: Data, password: String, conflict: ZwzIdentityConflictPolicy) throws -> ZwzIdentityMetadata { try backing.importPrivateBackup(data, password: password, conflict: conflict) }
    func rename(fingerprint: String, to name: String) throws { try backing.rename(fingerprint: fingerprint, to: name) }
    func delete(fingerprint: String) throws { try backing.delete(fingerprint: fingerprint) }
    func agreementPrivateKey(fingerprint: String, reason: String) throws -> Data { try backing.agreementPrivateKey(fingerprint: fingerprint, reason: reason) }
    func signingPrivateKey(fingerprint: String, reason: String) throws -> Data { try backing.signingPrivateKey(fingerprint: fingerprint, reason: reason) }
    func isKnownSigningKey(fingerprint: String, signingPublicKey: Data) -> Bool { backing.isKnownSigningKey(fingerprint: fingerprint, signingPublicKey: signingPublicKey) }
}

private final class StringBox {
    var values: [String] = []
    var text: String { values.joined(separator: "\n") }
}

private final class ValueBox<Value> {
    var values: [Value]
    init(_ values: [Value] = []) { self.values = values }
    func next() -> Value? { values.isEmpty ? nil : values.removeFirst() }
}

private final class FakeArchiveOperations: ZwzCLIArchiveOperations {
    var failure: Error?
    var recipientLabels: [ZwzRecipientInfo] = []
    var lastOptions: CompressionOptions?
    var compressCalls = 0
    var listingEntries: [ArchiveEntry] = []

    func compress(source: String, destination: String?, options: CompressionOptions, keyProvider: ZwzPrivateKeyProvider?) throws -> String {
        if let failure { throw failure }
        compressCalls += 1
        lastOptions = options
        return destination ?? source + ".zip"
    }

    func extract(archive: String, destination: String?, password: String?, keyProvider: ZwzPrivateKeyProvider?) throws -> ZwzExtractionResult {
        if let failure { throw failure }
        return ZwzExtractionResult(destinationPath: destination ?? "out", version: nil, securityInfo: nil)
    }

    func list(archive: String, password: String?, keyProvider: ZwzPrivateKeyProvider?) throws -> ZwzArchiveListing {
        if let failure { throw failure }
        return ZwzArchiveListing(entries: listingEntries, version: nil, securityInfo: nil)
    }

    func recipientInfo(archive: String) throws -> [ZwzRecipientInfo] { recipientLabels }
}

private final class FakeTerminalSession: TerminalSession {
    let isTerminal = true
    var lines: [String?]
    var disableCount = 0
    var restoreCount = 0

    init(lines: [String?]) { self.lines = lines }
    func disableEcho() throws -> () -> Void {
        disableCount += 1
        return { self.restoreCount += 1 }
    }
    func readLine() -> String? { lines.isEmpty ? nil : lines.removeFirst() }
}
