import Foundation

public enum ZwzV3ContentCipher: UInt8, Equatable, Sendable {
    case aes256GCM = 1
}

public enum ZwzV3KeyAgreement: UInt8, Equatable, Sendable {
    case x25519 = 1
}

public enum ZwzV3KDF: UInt8, Equatable, Sendable {
    case hkdfSHA256 = 1
}

public enum ZwzV3KeyWrapCipher: UInt8, Equatable, Sendable {
    case aes256GCM = 1
}

public enum ZwzV3SignatureAlgorithm: UInt8, Equatable, Sendable {
    case none = 0
    case ed25519 = 1
}

public enum ZwzV3IndexCipher: UInt8, Equatable, Sendable {
    case aes256GCM = 1
}

public struct ZwzV3Header: Equatable, Sendable {
    public static let encodedLength = 160

    public var archiveID: UUID
    public var recipientCount: UInt32
    public var recipientRegionOffset: UInt64
    public var recipientRegionLength: UInt64
    public var dataRegionOffset: UInt64
    public var dataRegionLength: UInt64
    public var encryptedIndexOffset: UInt64
    public var encryptedIndexLength: UInt64
    public var signerRegionOffset: UInt64
    public var signerRegionLength: UInt64
    public var signatureOffset: UInt64
    public var signatureLength: UInt64
    public var dataBlockCount: UInt64
    public var encryption: ZwzArchiveEncryptionKind
    public var contentCipher: ZwzV3ContentCipher
    public var keyAgreement: ZwzV3KeyAgreement
    public var kdf: ZwzV3KDF
    public var keyWrapCipher: ZwzV3KeyWrapCipher
    public var signatureAlgorithm: ZwzV3SignatureAlgorithm
    public var indexCipher: ZwzV3IndexCipher

    public init(
        archiveID: UUID,
        recipientCount: UInt32,
        recipientRegionOffset: UInt64,
        recipientRegionLength: UInt64,
        dataRegionOffset: UInt64,
        dataRegionLength: UInt64,
        encryptedIndexOffset: UInt64,
        encryptedIndexLength: UInt64,
        signerRegionOffset: UInt64 = 0,
        signerRegionLength: UInt64 = 0,
        signatureOffset: UInt64 = 0,
        signatureLength: UInt64 = 0,
        dataBlockCount: UInt64,
        encryption: ZwzArchiveEncryptionKind = .publicKey,
        contentCipher: ZwzV3ContentCipher = .aes256GCM,
        keyAgreement: ZwzV3KeyAgreement = .x25519,
        kdf: ZwzV3KDF = .hkdfSHA256,
        keyWrapCipher: ZwzV3KeyWrapCipher = .aes256GCM,
        signatureAlgorithm: ZwzV3SignatureAlgorithm = .none,
        indexCipher: ZwzV3IndexCipher = .aes256GCM
    ) {
        self.archiveID = archiveID
        self.recipientCount = recipientCount
        self.recipientRegionOffset = recipientRegionOffset
        self.recipientRegionLength = recipientRegionLength
        self.dataRegionOffset = dataRegionOffset
        self.dataRegionLength = dataRegionLength
        self.encryptedIndexOffset = encryptedIndexOffset
        self.encryptedIndexLength = encryptedIndexLength
        self.signerRegionOffset = signerRegionOffset
        self.signerRegionLength = signerRegionLength
        self.signatureOffset = signatureOffset
        self.signatureLength = signatureLength
        self.dataBlockCount = dataBlockCount
        self.encryption = encryption
        self.contentCipher = contentCipher
        self.keyAgreement = keyAgreement
        self.kdf = kdf
        self.keyWrapCipher = keyWrapCipher
        self.signatureAlgorithm = signatureAlgorithm
        self.indexCipher = indexCipher
    }
}

public struct ZwzV3ParsedArchive: Equatable, Sendable {
    public let header: ZwzV3Header
    public let recipients: [ZwzV3RecipientEnvelope]
    public let signer: ZwzV3SignerRecord?
    public let dataRegion: Data
    public let encryptedIndex: Data
    public let canonicalSignedBytes: Data

    public init(
        header: ZwzV3Header,
        recipients: [ZwzV3RecipientEnvelope],
        signer: ZwzV3SignerRecord?,
        dataRegion: Data,
        encryptedIndex: Data,
        canonicalSignedBytes: Data
    ) {
        self.header = header
        self.recipients = recipients
        self.signer = signer
        self.dataRegion = dataRegion
        self.encryptedIndex = encryptedIndex
        self.canonicalSignedBytes = canonicalSignedBytes
    }
}

public enum ZwzV3BinaryCodec {
    private static let magic = Data([0x5A, 0x57, 0x5A, 0x33])
    private static let version: UInt16 = 3
    private static let signedFlag: UInt32 = 1

    public static func encodeHeader(_ header: ZwzV3Header) throws -> Data {
        try validateHeader(header)

        var data = Data(repeating: 0, count: ZwzV3Header.encodedLength)
        data.replaceSubrange(0..<4, with: magic)
        write(version, to: &data, at: 4)
        write(UInt16(ZwzV3Header.encodedLength), to: &data, at: 6)
        write(header.signatureAlgorithm == .ed25519 ? signedFlag : 0, to: &data, at: 8)
        data[12] = header.encryption.rawValue
        data[13] = header.contentCipher.rawValue
        data[14] = header.keyAgreement.rawValue
        data[15] = header.kdf.rawValue
        data[16] = header.keyWrapCipher.rawValue
        data[17] = header.signatureAlgorithm.rawValue
        data[18] = header.indexCipher.rawValue
        writeUUID(header.archiveID, to: &data, at: 20)
        write(header.recipientCount, to: &data, at: 36)
        write(header.recipientRegionOffset, to: &data, at: 40)
        write(header.recipientRegionLength, to: &data, at: 48)
        write(header.dataRegionOffset, to: &data, at: 56)
        write(header.dataRegionLength, to: &data, at: 64)
        write(header.encryptedIndexOffset, to: &data, at: 72)
        write(header.encryptedIndexLength, to: &data, at: 80)
        write(header.signerRegionOffset, to: &data, at: 88)
        write(header.signerRegionLength, to: &data, at: 96)
        write(header.signatureOffset, to: &data, at: 104)
        write(header.signatureLength, to: &data, at: 112)
        write(header.dataBlockCount, to: &data, at: 120)
        return data
    }

    public static func decodeHeader(_ input: Data) throws -> ZwzV3Header {
        let data = Data(input)
        guard data.count == ZwzV3Header.encodedLength else {
            throw malformed("invalid header length")
        }
        guard data.prefix(4) == magic else { throw malformed("invalid magic") }
        guard try readUInt16(data, at: 4) == version else { throw malformed("invalid version") }
        guard try readUInt16(data, at: 6) == UInt16(ZwzV3Header.encodedLength) else {
            throw malformed("invalid header size")
        }

        let flags = try readUInt32(data, at: 8)
        guard flags & ~signedFlag == 0 else { throw malformed("unsupported flags") }
        guard data[19] == 0, data[128..<160].allSatisfy({ $0 == 0 }) else {
            throw malformed("nonzero reserved bytes")
        }
        guard let encryption = ZwzArchiveEncryptionKind(rawValue: data[12]), encryption == .publicKey,
              let contentCipher = ZwzV3ContentCipher(rawValue: data[13]),
              let keyAgreement = ZwzV3KeyAgreement(rawValue: data[14]),
              let kdf = ZwzV3KDF(rawValue: data[15]),
              let keyWrapCipher = ZwzV3KeyWrapCipher(rawValue: data[16]),
              let signatureAlgorithm = ZwzV3SignatureAlgorithm(rawValue: data[17]),
              let indexCipher = ZwzV3IndexCipher(rawValue: data[18]) else {
            throw malformed("unsupported algorithm")
        }
        guard (flags == signedFlag) == (signatureAlgorithm == .ed25519) else {
            throw malformed("inconsistent signature state")
        }

        let header = ZwzV3Header(
            archiveID: try readUUID(data, at: 20),
            recipientCount: try readUInt32(data, at: 36),
            recipientRegionOffset: try readUInt64(data, at: 40),
            recipientRegionLength: try readUInt64(data, at: 48),
            dataRegionOffset: try readUInt64(data, at: 56),
            dataRegionLength: try readUInt64(data, at: 64),
            encryptedIndexOffset: try readUInt64(data, at: 72),
            encryptedIndexLength: try readUInt64(data, at: 80),
            signerRegionOffset: try readUInt64(data, at: 88),
            signerRegionLength: try readUInt64(data, at: 96),
            signatureOffset: try readUInt64(data, at: 104),
            signatureLength: try readUInt64(data, at: 112),
            dataBlockCount: try readUInt64(data, at: 120),
            encryption: encryption,
            contentCipher: contentCipher,
            keyAgreement: keyAgreement,
            kdf: kdf,
            keyWrapCipher: keyWrapCipher,
            signatureAlgorithm: signatureAlgorithm,
            indexCipher: indexCipher
        )
        try validateHeader(header)
        return header
    }

    public static func parse(_ input: Data) throws -> ZwzV3ParsedArchive {
        let data = Data(input)
        guard data.count >= ZwzV3Header.encodedLength else { throw malformed("truncated header") }
        let header = try decodeHeader(data.subdata(in: 0..<ZwzV3Header.encodedLength))
        let fileLength = UInt64(data.count)

        let recipientEnd = try checkedEnd(header.recipientRegionOffset, header.recipientRegionLength)
        let dataEnd = try checkedEnd(header.dataRegionOffset, header.dataRegionLength)
        let indexEnd = try checkedEnd(header.encryptedIndexOffset, header.encryptedIndexLength)
        guard header.recipientRegionOffset == UInt64(ZwzV3Header.encodedLength),
              recipientEnd == header.dataRegionOffset,
              dataEnd == header.encryptedIndexOffset else {
            throw malformed("non-canonical region layout")
        }
        guard header.dataRegionLength != 0 || header.dataBlockCount == 0 else {
            throw malformed("empty data region with data blocks")
        }

        let isSigned = header.signatureAlgorithm == .ed25519
        if isSigned {
            let signerEnd = try checkedEnd(header.signerRegionOffset, header.signerRegionLength)
            guard indexEnd == header.signerRegionOffset, signerEnd == fileLength else {
                throw malformed("non-canonical signed region layout")
            }
        } else {
            guard indexEnd == fileLength else { throw malformed("trailing archive bytes") }
        }

        let recipients = try decodeRecipients(
            data,
            range: try intRange(header.recipientRegionOffset, recipientEnd, fileLength: fileLength),
            count: header.recipientCount
        )
        let dataRegion = data.subdata(
            in: try intRange(header.dataRegionOffset, dataEnd, fileLength: fileLength)
        )
        let encryptedIndex = data.subdata(
            in: try intRange(header.encryptedIndexOffset, indexEnd, fileLength: fileLength)
        )

        let signer: ZwzV3SignerRecord?
        let canonicalSignedBytes: Data
        if isSigned {
            let signerEnd = try checkedEnd(header.signerRegionOffset, header.signerRegionLength)
            signer = try decodeSigner(
                data,
                range: try intRange(header.signerRegionOffset, signerEnd, fileLength: fileLength),
                signatureOffset: header.signatureOffset
            )
            let signatureRange = try intRange(
                header.signatureOffset,
                try checkedEnd(header.signatureOffset, header.signatureLength),
                fileLength: fileLength
            )
            var canonical = Data()
            canonical.reserveCapacity(data.count - signatureRange.count)
            canonical.append(data.prefix(signatureRange.lowerBound))
            canonical.append(data.suffix(from: signatureRange.upperBound))
            canonicalSignedBytes = canonical
        } else {
            signer = nil
            canonicalSignedBytes = data
        }

        return ZwzV3ParsedArchive(
            header: header,
            recipients: recipients,
            signer: signer,
            dataRegion: dataRegion,
            encryptedIndex: encryptedIndex,
            canonicalSignedBytes: canonicalSignedBytes
        )
    }

    static func validateRecipient(_ recipient: ZwzV3RecipientEnvelope) throws {
        guard !recipient.recipientName.utf8.isEmpty,
              !recipient.recipientFingerprint.utf8.isEmpty,
              recipient.ephemeralPublicKey.count == 32,
              recipient.nonce.count == 12,
              recipient.encryptedContentKey.count == 32,
              recipient.authenticationTag.count == 16 else {
            throw malformed("invalid recipient record")
        }
    }

    static func validateSigner(_ signer: ZwzV3SignerRecord) throws {
        guard !signer.name.utf8.isEmpty,
              !signer.fingerprint.utf8.isEmpty,
              signer.signingPublicKey.count == 32,
              signer.signature.count == 64 else {
            throw malformed("invalid signer record")
        }
    }

    static func encodeRecipient(_ recipient: ZwzV3RecipientEnvelope) throws -> Data {
        try validateRecipient(recipient)
        var body = Data()
        try appendString(recipient.recipientName, to: &body)
        try appendString(recipient.recipientFingerprint, to: &body)
        body.append(recipient.ephemeralPublicKey)
        body.append(recipient.nonce)
        body.append(recipient.encryptedContentKey)
        body.append(recipient.authenticationTag)
        return try lengthPrefixed(body)
    }

    static func encodeSigner(_ signer: ZwzV3SignerRecord) throws -> Data {
        try validateSigner(signer)
        var body = Data()
        try appendString(signer.name, to: &body)
        try appendString(signer.fingerprint, to: &body)
        body.append(signer.signingPublicKey)
        body.append(signer.signature)
        return try lengthPrefixed(body)
    }

    private static func validateHeader(_ header: ZwzV3Header) throws {
        guard header.encryption == .publicKey,
              header.contentCipher == .aes256GCM,
              header.keyAgreement == .x25519,
              header.kdf == .hkdfSHA256,
              header.keyWrapCipher == .aes256GCM,
              header.indexCipher == .aes256GCM,
              header.recipientCount > 0,
              header.recipientRegionLength > 0,
              header.encryptedIndexLength > 0 else {
            throw malformed("invalid header fields")
        }
        let recipientEnd = try checkedEnd(header.recipientRegionOffset, header.recipientRegionLength)
        let dataEnd = try checkedEnd(header.dataRegionOffset, header.dataRegionLength)
        let indexEnd = try checkedEnd(header.encryptedIndexOffset, header.encryptedIndexLength)
        guard header.recipientRegionOffset == UInt64(ZwzV3Header.encodedLength),
              recipientEnd == header.dataRegionOffset,
              dataEnd == header.encryptedIndexOffset else {
            throw malformed("non-canonical header layout")
        }

        switch header.signatureAlgorithm {
        case .none:
            guard header.signerRegionOffset == 0,
                  header.signerRegionLength == 0,
                  header.signatureOffset == 0,
                  header.signatureLength == 0 else {
                throw malformed("inconsistent unsigned header")
            }
        case .ed25519:
            let signerEnd = try checkedEnd(header.signerRegionOffset, header.signerRegionLength)
            let signatureEnd = try checkedEnd(header.signatureOffset, header.signatureLength)
            guard header.signerRegionLength > 0,
                  header.signatureLength == 64,
                  indexEnd == header.signerRegionOffset,
                  header.signatureOffset >= header.signerRegionOffset,
                  signatureEnd == signerEnd else {
                throw malformed("inconsistent signed header")
            }
        }
    }

    private static func decodeRecipients(
        _ data: Data,
        range: Range<Int>,
        count: UInt32
    ) throws -> [ZwzV3RecipientEnvelope] {
        let minimumRecipientRecordLength = 106
        guard UInt64(count) <= UInt64(range.count / minimumRecipientRecordLength) else {
            throw malformed("recipient count exceeds region capacity")
        }
        var cursor = range.lowerBound
        var recipients: [ZwzV3RecipientEnvelope] = []
        recipients.reserveCapacity(Int(count))
        for _ in 0..<count {
            let recordEnd = try readRecordEnd(data, cursor: &cursor, limit: range.upperBound)
            let name = try readString(data, cursor: &cursor, limit: recordEnd)
            let fingerprint = try readString(data, cursor: &cursor, limit: recordEnd)
            let ephemeralPublicKey = try readData(data, count: 32, cursor: &cursor, limit: recordEnd)
            let nonce = try readData(data, count: 12, cursor: &cursor, limit: recordEnd)
            let encryptedContentKey = try readData(data, count: 32, cursor: &cursor, limit: recordEnd)
            let authenticationTag = try readData(data, count: 16, cursor: &cursor, limit: recordEnd)
            guard cursor == recordEnd else { throw malformed("recipient record length mismatch") }
            recipients.append(ZwzV3RecipientEnvelope(
                recipientName: name,
                recipientFingerprint: fingerprint,
                ephemeralPublicKey: ephemeralPublicKey,
                nonce: nonce,
                encryptedContentKey: encryptedContentKey,
                authenticationTag: authenticationTag
            ))
        }
        guard cursor == range.upperBound else { throw malformed("recipient region length mismatch") }
        return recipients
    }

    private static func decodeSigner(
        _ data: Data,
        range: Range<Int>,
        signatureOffset: UInt64
    ) throws -> ZwzV3SignerRecord {
        var cursor = range.lowerBound
        let recordEnd = try readRecordEnd(data, cursor: &cursor, limit: range.upperBound)
        let name = try readString(data, cursor: &cursor, limit: recordEnd)
        let fingerprint = try readString(data, cursor: &cursor, limit: recordEnd)
        let publicKey = try readData(data, count: 32, cursor: &cursor, limit: recordEnd)
        guard UInt64(cursor) == signatureOffset else { throw malformed("invalid signature offset") }
        let signature = try readData(data, count: 64, cursor: &cursor, limit: recordEnd)
        guard cursor == recordEnd, recordEnd == range.upperBound else {
            throw malformed("signer record length mismatch")
        }
        return ZwzV3SignerRecord(
            name: name,
            fingerprint: fingerprint,
            signingPublicKey: publicKey,
            signature: signature
        )
    }

    private static func readRecordEnd(_ data: Data, cursor: inout Int, limit: Int) throws -> Int {
        let length = try readUInt32Advancing(data, cursor: &cursor, limit: limit)
        let (end, overflow) = cursor.addingReportingOverflow(Int(length))
        guard !overflow, end <= limit else { throw malformed("record exceeds region") }
        return end
    }

    private static func readString(
        _ data: Data,
        cursor: inout Int,
        limit: Int
    ) throws -> String {
        let length = try readUInt32Advancing(data, cursor: &cursor, limit: limit)
        guard length > 0 else { throw malformed("empty string field") }
        let bytes = try readData(data, count: Int(length), cursor: &cursor, limit: limit)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw malformed("invalid UTF-8")
        }
        return value
    }

    private static func readUInt32Advancing(
        _ data: Data,
        cursor: inout Int,
        limit: Int
    ) throws -> UInt32 {
        let valueData = try readData(data, count: 4, cursor: &cursor, limit: limit)
        return try readUInt32(valueData, at: 0)
    }

    private static func readData(
        _ data: Data,
        count: Int,
        cursor: inout Int,
        limit: Int
    ) throws -> Data {
        let (end, overflow) = cursor.addingReportingOverflow(count)
        guard count >= 0, !overflow, cursor >= 0, end <= limit, end <= data.count else {
            throw malformed("truncated field")
        }
        defer { cursor = end }
        return data.subdata(in: cursor..<end)
    }

    private static func appendString(_ string: String, to data: inout Data) throws {
        let bytes = Data(string.utf8)
        guard !bytes.isEmpty, let length = UInt32(exactly: bytes.count) else {
            throw malformed("invalid string length")
        }
        append(length, to: &data)
        data.append(bytes)
    }

    private static func lengthPrefixed(_ body: Data) throws -> Data {
        guard let length = UInt32(exactly: body.count) else { throw malformed("record too large") }
        var data = Data()
        append(length, to: &data)
        data.append(body)
        return data
    }

    private static func checkedEnd(_ offset: UInt64, _ length: UInt64) throws -> UInt64 {
        let result = offset.addingReportingOverflow(length)
        guard !result.overflow else { throw malformed("overflowing region") }
        return result.partialValue
    }

    private static func intRange(
        _ start: UInt64,
        _ end: UInt64,
        fileLength: UInt64
    ) throws -> Range<Int> {
        guard start <= end, end <= fileLength,
              let intStart = Int(exactly: start), let intEnd = Int(exactly: end) else {
            throw malformed("region outside archive")
        }
        return intStart..<intEnd
    }

    private static func writeUUID(_ uuid: UUID, to data: inout Data, at offset: Int) {
        let value = uuid.uuid
        data.replaceSubrange(offset..<(offset + 16), with: [
            value.0, value.1, value.2, value.3, value.4, value.5, value.6, value.7,
            value.8, value.9, value.10, value.11, value.12, value.13, value.14, value.15,
        ])
    }

    private static func readUUID(_ data: Data, at offset: Int) throws -> UUID {
        guard offset >= 0, offset + 16 <= data.count else { throw malformed("short UUID") }
        let bytes = Array(data[offset..<(offset + 16)])
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func write<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { bytes in
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        try readInteger(data, at: offset, as: UInt16.self)
    }

    private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        try readInteger(data, at: offset, as: UInt32.self)
    }

    private static func readUInt64(_ data: Data, at offset: Int) throws -> UInt64 {
        try readInteger(data, at: offset, as: UInt64.self)
    }

    private static func readInteger<T: FixedWidthInteger>(
        _ data: Data,
        at offset: Int,
        as: T.Type
    ) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset <= data.count, size <= data.count - offset else {
            throw malformed("short integer")
        }
        return data[offset..<(offset + size)].enumerated().reduce(into: T.zero) { value, element in
            value |= T(element.element) << (element.offset * 8)
        }
    }

    private static func malformed(_ reason: String) -> ZwzV3Error {
        .malformedArchive(reason)
    }
}
