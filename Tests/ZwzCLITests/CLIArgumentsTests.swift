import XCTest
@testable import zwz

final class CLIArgumentsTests: XCTestCase {
    func testParsesKeyCommands() throws {
        XCTAssertEqual(try CLIArguments.parse(["key", "create", "Alice"]), .key(.create(name: "Alice")))
        XCTAssertEqual(try CLIArguments.parse(["key", "list"]), .key(.list))
        XCTAssertEqual(try CLIArguments.parse(["key", "rename", "Alice", "Alicia"]), .key(.rename(identity: "Alice", newName: "Alicia")))
        XCTAssertEqual(try CLIArguments.parse(["key", "delete", "--yes", "Alice"]), .key(.delete(identity: "Alice", confirmed: true)))
        XCTAssertEqual(try CLIArguments.parse(["key", "export-public", "Alice", "alice.zwzpub"]), .key(.exportPublic(identity: "Alice", output: "alice.zwzpub")))
        XCTAssertEqual(try CLIArguments.parse(["key", "import-public", "--replace", "alice.zwzpub"]), .key(.importPublic(input: "alice.zwzpub", replace: true)))
        XCTAssertEqual(try CLIArguments.parse(["key", "backup", "Alice", "alice.zwzkey"]), .key(.backup(identity: "Alice", output: "alice.zwzkey")))
        XCTAssertEqual(try CLIArguments.parse(["key", "restore", "--replace", "alice.zwzkey"]), .key(.restore(input: "alice.zwzkey", replace: true)))
    }

    func testCompressParsesRecipientsSignerAndLegacyOptions() throws {
        let command = try CLIArguments.parse([
            "compress", "-f", "zwz", "--recipient", "Alice", "--recipient", "Bob",
            "--sign", "Me", "-l", "max", "-s", "500KB", "-t", "4", "input", "output.zwz"
        ])
        guard case .compress(let options) = command else { return XCTFail("wrong command") }
        XCTAssertEqual(options.recipients, ["Alice", "Bob"])
        XCTAssertEqual(options.signer, "Me")
        XCTAssertEqual(options.source, "input")
        XCTAssertEqual(options.output, "output.zwz")
        XCTAssertEqual(options.threadCount, 4)
    }

    func testAliasesRemainSupported() throws {
        guard case .compress = try CLIArguments.parse(["c", "input"]) else { return XCTFail() }
        guard case .extract = try CLIArguments.parse(["x", "archive.zip"]) else { return XCTFail() }
        guard case .list = try CLIArguments.parse(["l", "archive.zip"]) else { return XCTFail() }
        XCTAssertEqual(try CLIArguments.parse(["h"]), .help)
        XCTAssertEqual(try CLIArguments.parse(["compress", "--help"]), .help)
        XCTAssertEqual(try CLIArguments.parse(["rename", "--help"]), .help)
    }

    func testRejectsInvalidCompressionArguments() {
        assertInvalid(["compress", "-p", "secret", "--recipient", "Alice", "input"])
        assertInvalid(["compress", "--sign", "Me", "input"])
        assertInvalid(["compress", "--recipient", "Alice", "input"])
        assertInvalid(["compress", "-f", "zip", "--recipient", "Alice", "input"])
        assertInvalid(["compress", "-f", "zwz", "--recipient"])
        assertInvalid(["compress", "-f", "zip", "--format", "zwz", "input"])
        assertInvalid(["compress", "-p", "one", "-p", "two", "input"])
        assertInvalid(["compress", "-s", "0MB", "input"])
        assertInvalid(["compress", "-s", "-1MB", "input"])
        assertInvalid(["compress", "-s", "9223372036854775807MB", "input"])
        assertInvalid(["compress", "-t", "-1", "input"])
        assertInvalid(["compress", "input", "output", "extra"])
        assertInvalid(["compress", "--unknown", "input"])
    }

    func testRejectsInvalidKeyAndArchiveArguments() {
        assertInvalid(["key", "list", "extra"])
        assertInvalid(["key", "delete", "--yes", "--yes", "Alice"])
        assertInvalid(["key", "import-public", "--replace", "--replace", "file"])
        assertInvalid(["key", "backup", "--password", "secret", "Alice", "file"])
        assertInvalid(["key", "restore", "--password-file", "p", "file"])
        assertInvalid(["key", "create", "--unknown"])
        assertInvalid(["key", "rename", "Alice", "--unknown"])
        assertInvalid(["extract", "-p"])
        assertInvalid(["extract", "a", "b", "c"])
        assertInvalid(["list", "-p", "one", "--password", "two", "a"])
    }

    private func assertInvalid(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try CLIArguments.parse(arguments), file: file, line: line)
    }
}
