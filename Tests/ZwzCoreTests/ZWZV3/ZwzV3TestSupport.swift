import CryptoKit
import Foundation
@testable import ZwzCore

final class ZwzV3MemoryKeyProvider: ZwzPrivateKeyProvider, @unchecked Sendable {
    var agreementKeys: [String: Data]
    var signingKeys: [String: Data]
    var knownSigningKeys: Set<String>
    var lookupError: Error?

    init(
        agreementKeys: [String: Data] = [:],
        signingKeys: [String: Data] = [:],
        knownSigningKeys: Set<String> = []
    ) {
        self.agreementKeys = agreementKeys
        self.signingKeys = signingKeys
        self.knownSigningKeys = knownSigningKeys
    }

    func agreementPrivateKey(fingerprint: String, reason: String) throws -> Data {
        if let lookupError { throw lookupError }
        guard let key = agreementKeys[fingerprint] else { throw MissingKey() }
        return key
    }

    func signingPrivateKey(fingerprint: String, reason: String) throws -> Data {
        if let lookupError { throw lookupError }
        guard let key = signingKeys[fingerprint] else { throw MissingKey() }
        return key
    }

    func isKnownSigningKey(fingerprint: String) -> Bool {
        knownSigningKeys.contains(fingerprint)
    }

    private struct MissingKey: Error {}
}

struct ZwzV3IdentityFixture {
    let recipient: ZwzRecipient
    let agreementPrivateKey: Data
    let signingIdentity: ZwzSigningIdentity
    let signingPrivateKey: Data
    let signingFingerprint: String

    static func make(name: String) -> Self {
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        let signing = Curve25519.Signing.PrivateKey()
        let fingerprint = ZwzV3Crypto.fingerprint(
            agreement: agreement.publicKey.rawRepresentation,
            signing: signing.publicKey.rawRepresentation
        )
        return Self(
            recipient: ZwzRecipient(
                name: name,
                fingerprint: fingerprint,
                agreementPublicKey: agreement.publicKey.rawRepresentation
            ),
            agreementPrivateKey: agreement.rawRepresentation,
            signingIdentity: ZwzSigningIdentity(
                name: name,
                fingerprint: fingerprint,
                agreementPublicKey: agreement.publicKey.rawRepresentation,
                signingPublicKey: signing.publicKey.rawRepresentation
            ),
            signingPrivateKey: signing.rawRepresentation,
            signingFingerprint: fingerprint
        )
    }

    var provider: ZwzV3MemoryKeyProvider {
        ZwzV3MemoryKeyProvider(
            agreementKeys: [recipient.fingerprint: agreementPrivateKey],
            signingKeys: [signingFingerprint: signingPrivateKey]
        )
    }
}

enum ZwzV3TestSupport {
    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zwz-v3-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeSource(in directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("nested/\u{8d44}\u{6599}/empty-dir", isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: source.appendingPathComponent("empty.txt").path, contents: nil)
        try Data("hidden".utf8).write(to: source.appendingPathComponent(".hidden"))
        try Data("unicode".utf8).write(to: source.appendingPathComponent("nested/\u{8d44}\u{6599}/\u{6587}\u{4ef6}.txt"))
        try Data((0..<48_000).map { UInt8(($0 * 29) % 251) })
            .write(to: source.appendingPathComponent("nested/multi.bin"))
        return source
    }

    static func assertTreesEqual(_ expected: URL, _ actual: URL) throws {
        let expectedItems = try relativeItems(in: expected)
        let actualItems = try relativeItems(in: actual)
        guard expectedItems == actualItems else {
            throw TreeMismatch(expected: expectedItems.map(\.path), actual: actualItems.map(\.path))
        }
        for item in expectedItems where !item.isDirectory {
            let lhs = try Data(contentsOf: expected.appendingPathComponent(item.path))
            let rhs = try Data(contentsOf: actual.appendingPathComponent(item.path))
            guard lhs == rhs else { throw ByteMismatch(path: item.path) }
        }
    }

    private struct TreeMismatch: Error, CustomStringConvertible {
        let expected: [String]
        let actual: [String]
        var description: String { "expected \(expected), actual \(actual)" }
    }

    private struct ByteMismatch: Error {
        let path: String
    }

    static func mutate(_ archive: URL, at offset: Int) throws -> URL {
        var bytes = try Data(contentsOf: archive)
        bytes[offset] ^= 0x80
        let mutated = archive.deletingLastPathComponent().appendingPathComponent("mutated-\(UUID().uuidString).zwz")
        try bytes.write(to: mutated)
        return mutated
    }

    private struct RelativeItem: Equatable {
        let path: String
        let isDirectory: Bool
    }

    private static func relativeItems(in root: URL) throws -> [RelativeItem] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }
        var result: [RelativeItem] = []
        for case let url as URL in enumerator {
            let relative = try ZwzV2PathValidator.normalizedArchivePath(root: root, item: url)
            let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            result.append(RelativeItem(path: relative, isDirectory: directory))
        }
        return result.sorted { $0.path < $1.path }
    }
}
