import Foundation
@testable import ZwzCore

extension ZwzV3RecipientEnvelope {
    static func codecFixture(name: String = "Alice", fingerprint: String = "alice-fingerprint") -> Self {
        Self(
            recipientName: name,
            recipientFingerprint: fingerprint,
            ephemeralPublicKey: Data(repeating: 0x11, count: 32),
            nonce: Data(repeating: 0x22, count: 12),
            encryptedContentKey: Data(repeating: 0x33, count: 32),
            authenticationTag: Data(repeating: 0x44, count: 16)
        )
    }
}

extension ZwzV3SignerRecord {
    static func codecFixture(signature: Data = Data(repeating: 0x55, count: 64)) -> Self {
        Self(
            name: "Sender",
            fingerprint: "sender-fingerprint",
            signingPublicKey: Data(repeating: 0x66, count: 32),
            signature: signature
        )
    }
}

extension Data {
    static func fixture() throws -> Data {
        try ZwzV3ArchiveCodec.encode(
            recipients: [.codecFixture()],
            dataRegion: Data([0x70, 0x71, 0x72]),
            encryptedIndex: Data([0x80, 0x81]),
            signer: nil,
            archiveID: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
            dataBlockCount: 1
        )
    }

    static func signedFixture(signature: Data) throws -> Data {
        try ZwzV3ArchiveCodec.encode(
            recipients: [.codecFixture()],
            dataRegion: Data([0x70, 0x71, 0x72]),
            encryptedIndex: Data([0x80, 0x81]),
            signer: .codecFixture(signature: signature),
            archiveID: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
            dataBlockCount: 1
        )
    }

    static func fixtureWithOverlappingIndex() throws -> Data {
        var archive = try fixture()
        let dataOffset = readUInt64(at: 56, in: archive)
        writeUInt64(dataOffset, at: 72, in: &archive)
        return archive
    }

    static func writeUInt32(_ value: UInt32, at offset: Int, in data: inout Data) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { bytes in
            data.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
    }

    static func writeUInt64(_ value: UInt64, at offset: Int, in data: inout Data) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { bytes in
            data.replaceSubrange(offset..<(offset + 8), with: bytes)
        }
    }

    static func readUInt64(at offset: Int, in data: Data) -> UInt64 {
        data[offset..<(offset + 8)].enumerated().reduce(into: UInt64.zero) { value, element in
            value |= UInt64(element.element) << (element.offset * 8)
        }
    }
}
