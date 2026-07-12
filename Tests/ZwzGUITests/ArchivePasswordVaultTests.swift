import XCTest
@testable import ZwzGUI

@MainActor
final class ArchivePasswordVaultTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchivePasswordVaultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "ArchivePasswordVaultTests-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testLocalVaultEncryptsStoresAndUnlocksPassword() throws {
        let vault = ArchivePasswordVault(baseURL: root, defaults: defaults)
        try vault.configure(masterPassword: "correct horse battery staple")
        try vault.save(password: "archive-password", fingerprint: "fingerprint", archiveName: "archive.zip", storage: .local)

        XCTAssertEqual(try vault.password(for: "fingerprint", storage: .local), "archive-password")
        XCTAssertEqual(vault.records(for: .local).map(\.archiveName), ["archive.zip"])

        vault.lock()
        XCTAssertThrowsError(try vault.password(for: "fingerprint", storage: .local))
        XCTAssertThrowsError(try vault.unlock(masterPassword: "wrong password"))

        try vault.unlock(masterPassword: "correct horse battery staple")
        XCTAssertEqual(try vault.password(for: "fingerprint", storage: .local), "archive-password")
    }

    func testRemovingLocalRecordRemovesItsPassword() throws {
        let vault = ArchivePasswordVault(baseURL: root, defaults: defaults)
        try vault.configure(masterPassword: "master password")
        try vault.save(password: "one", fingerprint: "one", archiveName: "one.zip", storage: .local)
        try vault.save(password: "two", fingerprint: "two", archiveName: "two.zip", storage: .local)

        try vault.remove(fingerprint: "one", storage: .local)

        XCTAssertNil(try vault.password(for: "one", storage: .local))
        XCTAssertEqual(try vault.password(for: "two", storage: .local), "two")
    }

    func testFingerprintDoesNotDependOnFileNameOrLocation() throws {
        let original = root.appendingPathComponent("original.zip")
        let moved = root.appendingPathComponent("Moved/archive-copy.zip")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("same archive bytes".utf8).write(to: original)
        try FileManager.default.copyItem(at: original, to: moved)

        XCTAssertEqual(try ArchiveFingerprint.make(for: original), try ArchiveFingerprint.make(for: moved))
    }
}
