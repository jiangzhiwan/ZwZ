import CryptoKit
import Foundation
@testable import ZwzCore

enum ZwzV3APITestSupport {
    struct Fixture {
        let directory: URL
        let source: URL
        let archive: URL
        let identity: ZwzV3IdentityFixture
    }

    static func makeFixture(
        name: String = "archive.zwz",
        signer: Bool = false,
        splitVolume: SplitVolume? = nil,
        contents: Data = Data("public api".utf8)
    ) throws -> Fixture {
        let directory = try ZwzV3TestSupport.makeTempDirectory()
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try contents.write(to: source.appendingPathComponent("file.txt"))
        let identity = ZwzV3IdentityFixture.make(name: "Alice")
        let archive = directory.appendingPathComponent(name)
        let signingIdentity = signer ? identity.signingIdentity : nil
        let options = CompressionOptions(
            level: .none,
            encryption: .publicKey(recipients: [identity.recipient], signer: signingIdentity),
            splitVolume: splitVolume,
            format: .zwz
        )
        _ = try ZwzAPI().compress(
            sourcePath: source.path,
            destinationPath: archive.path,
            options: options,
            keyProvider: signer ? identity.provider : nil
        )
        return Fixture(directory: directory, source: source, archive: archive, identity: identity)
    }

    static func logicalMagic(at archive: URL) throws -> [UInt8] {
        let data = try Data(contentsOf: archive)
        if Array(data.prefix(4)) == ZwzV2Format.splitMagic {
            return Array(data.dropFirst(ZwzV2SplitEnvelope.encodedLength).prefix(4))
        }
        return Array(data.prefix(4))
    }
}
