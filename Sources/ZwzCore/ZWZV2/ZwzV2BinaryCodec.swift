import Foundation

public struct ZwzV2Header: Equatable, Sendable {
    public static let encodedLength = 128

    public var archiveID: UUID
    public var flags: ZwzV2HeaderFlags
    public var blockSize: UInt32
    public var kdfSalt: Data
    public var kdfIterations: UInt32

    public init(
        archiveID: UUID,
        flags: ZwzV2HeaderFlags,
        blockSize: UInt32,
        kdfSalt: Data,
        kdfIterations: UInt32
    ) {
        self.archiveID = archiveID
        self.flags = flags
        self.blockSize = blockSize
        self.kdfSalt = kdfSalt
        self.kdfIterations = kdfIterations
    }
}

public struct ZwzV2HeaderFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let encrypted = ZwzV2HeaderFlags(rawValue: 1 << 0)
    public static let split = ZwzV2HeaderFlags(rawValue: 1 << 1)
}

public struct ZwzV2BlockRecordHeader: Equatable, Sendable {
    public static let encodedLength = 40

    public var sequence: UInt64
    public var codec: ZwzV2Codec
    public var storedLength: UInt32
    public var originalLength: UInt32
    public var checksum: UInt32
    public var tagLength: UInt8

    public init(
        sequence: UInt64,
        codec: ZwzV2Codec,
        storedLength: UInt32,
        originalLength: UInt32,
        checksum: UInt32,
        tagLength: UInt8
    ) {
        self.sequence = sequence
        self.codec = codec
        self.storedLength = storedLength
        self.originalLength = originalLength
        self.checksum = checksum
        self.tagLength = tagLength
    }
}

public struct ZwzV2Footer: Equatable, Sendable {
    public static let encodedLength = 64

    public var archiveID: UUID
    public var indexOffset: UInt64
    public var indexLength: UInt64
    public var indexChecksum: UInt32

    public init(archiveID: UUID, indexOffset: UInt64, indexLength: UInt64, indexChecksum: UInt32) {
        self.archiveID = archiveID
        self.indexOffset = indexOffset
        self.indexLength = indexLength
        self.indexChecksum = indexChecksum
    }
}

public struct ZwzV2SplitEnvelope: Equatable, Sendable {
    public static let encodedLength = 80

    public var archiveID: UUID
    public var volumeNumber: UInt32
    public var isFinal: Bool
    public var logicalOffset: UInt64
    public var payloadLength: UInt64
    public var payloadChecksum: UInt32

    public init(
        archiveID: UUID,
        volumeNumber: UInt32,
        isFinal: Bool,
        logicalOffset: UInt64,
        payloadLength: UInt64,
        payloadChecksum: UInt32
    ) {
        self.archiveID = archiveID
        self.volumeNumber = volumeNumber
        self.isFinal = isFinal
        self.logicalOffset = logicalOffset
        self.payloadLength = payloadLength
        self.payloadChecksum = payloadChecksum
    }
}

public enum ZwzV2BinaryCodec {
    private static let headerSaltCapacity = 32
    private static let supportedHeaderFlags: UInt32 = ZwzV2HeaderFlags.encrypted.rawValue | ZwzV2HeaderFlags.split.rawValue

    public static func encodeHeader(_ header: ZwzV2Header) throws -> Data {
        guard header.flags.rawValue & ~supportedHeaderFlags == 0 else {
            throw malformed("unsupported header flags")
        }
        guard header.blockSize > 0 else {
            throw malformed("invalid block size")
        }
        guard header.kdfSalt.count <= headerSaltCapacity else {
            throw malformed("invalid KDF salt length")
        }

        var data = Data(repeating: 0, count: ZwzV2Header.encodedLength)
        writeMagic(ZwzV2Format.magic, to: &data)
        write(ZwzV2Format.version, to: &data, at: 4)
        writeUUID(header.archiveID, to: &data, at: 8)
        write(header.flags.rawValue, to: &data, at: 24)
        write(header.blockSize, to: &data, at: 28)
        write(UInt32(header.kdfSalt.count), to: &data, at: 32)
        write(header.kdfIterations, to: &data, at: 36)
        data.replaceSubrange(40..<(40 + header.kdfSalt.count), with: header.kdfSalt)
        return data
    }

    public static func decodeHeader(_ data: Data) throws -> ZwzV2Header {
        let data = Data(data)
        try requireLength(data, ZwzV2Header.encodedLength, record: "header")
        try validateMagicAndVersion(data, magic: ZwzV2Format.magic, version: ZwzV2Format.version, record: "header")
        try requireZeroes(data, in: 6..<8, record: "header")
        try requireZeroes(data, in: 72..<ZwzV2Header.encodedLength, record: "header")

        let flags = try readUInt32(data, at: 24)
        guard flags & ~supportedHeaderFlags == 0 else {
            throw malformed("unsupported header flags")
        }
        let blockSize = try readUInt32(data, at: 28)
        guard blockSize > 0 else {
            throw malformed("invalid block size")
        }
        let saltLength = try readUInt32(data, at: 32)
        guard saltLength <= UInt32(headerSaltCapacity) else {
            throw malformed("invalid KDF salt length")
        }
        let saltEnd = 40 + Int(saltLength)
        try requireZeroes(data, in: saltEnd..<72, record: "header")

        return ZwzV2Header(
            archiveID: try readUUID(data, at: 8),
            flags: ZwzV2HeaderFlags(rawValue: flags),
            blockSize: blockSize,
            kdfSalt: data.subdata(in: 40..<saltEnd),
            kdfIterations: try readUInt32(data, at: 36)
        )
    }

    public static func encodeBlockRecordHeader(_ header: ZwzV2BlockRecordHeader) throws -> Data {
        var data = Data(repeating: 0, count: ZwzV2BlockRecordHeader.encodedLength)
        write(header.sequence, to: &data, at: 0)
        data[8] = header.codec.rawValue
        data[9] = header.tagLength
        write(header.storedLength, to: &data, at: 12)
        write(header.originalLength, to: &data, at: 16)
        write(header.checksum, to: &data, at: 20)
        return data
    }

    public static func decodeBlockRecordHeader(_ data: Data) throws -> ZwzV2BlockRecordHeader {
        let data = Data(data)
        try requireLength(data, ZwzV2BlockRecordHeader.encodedLength, record: "block record header")
        try requireZeroes(data, in: 10..<12, record: "block record header")
        try requireZeroes(data, in: 24..<ZwzV2BlockRecordHeader.encodedLength, record: "block record header")
        guard let codec = ZwzV2Codec(rawValue: data[8]) else {
            throw malformed("unknown block codec")
        }

        return ZwzV2BlockRecordHeader(
            sequence: try readUInt64(data, at: 0),
            codec: codec,
            storedLength: try readUInt32(data, at: 12),
            originalLength: try readUInt32(data, at: 16),
            checksum: try readUInt32(data, at: 20),
            tagLength: data[9]
        )
    }

    public static func encodeFooter(_ footer: ZwzV2Footer) throws -> Data {
        guard !footer.indexOffset.addingReportingOverflow(footer.indexLength).overflow else {
            throw malformed("overflowing footer index range")
        }

        var data = Data(repeating: 0, count: ZwzV2Footer.encodedLength)
        writeMagic(ZwzV2Format.magic, to: &data)
        write(ZwzV2Format.version, to: &data, at: 4)
        writeUUID(footer.archiveID, to: &data, at: 8)
        write(footer.indexOffset, to: &data, at: 24)
        write(footer.indexLength, to: &data, at: 32)
        write(footer.indexChecksum, to: &data, at: 40)
        return data
    }

    public static func decodeFooter(_ data: Data) throws -> ZwzV2Footer {
        let data = Data(data)
        try requireLength(data, ZwzV2Footer.encodedLength, record: "footer")
        try validateMagicAndVersion(data, magic: ZwzV2Format.magic, version: ZwzV2Format.version, record: "footer")
        try requireZeroes(data, in: 6..<8, record: "footer")
        try requireZeroes(data, in: 44..<ZwzV2Footer.encodedLength, record: "footer")

        let indexOffset = try readUInt64(data, at: 24)
        let indexLength = try readUInt64(data, at: 32)
        guard !indexOffset.addingReportingOverflow(indexLength).overflow else {
            throw malformed("overflowing footer index range")
        }

        return ZwzV2Footer(
            archiveID: try readUUID(data, at: 8),
            indexOffset: indexOffset,
            indexLength: indexLength,
            indexChecksum: try readUInt32(data, at: 40)
        )
    }

    public static func encodeSplitEnvelope(_ envelope: ZwzV2SplitEnvelope) throws -> Data {
        guard !envelope.logicalOffset.addingReportingOverflow(envelope.payloadLength).overflow else {
            throw malformed("overflowing split envelope payload range")
        }

        var data = Data(repeating: 0, count: ZwzV2SplitEnvelope.encodedLength)
        writeMagic(ZwzV2Format.splitMagic, to: &data)
        write(ZwzV2Format.splitEnvelopeVersion, to: &data, at: 4)
        writeUUID(envelope.archiveID, to: &data, at: 8)
        write(envelope.volumeNumber, to: &data, at: 24)
        data[28] = envelope.isFinal ? 1 : 0
        write(envelope.logicalOffset, to: &data, at: 32)
        write(envelope.payloadLength, to: &data, at: 40)
        write(envelope.payloadChecksum, to: &data, at: 48)
        return data
    }

    public static func decodeSplitEnvelope(_ data: Data) throws -> ZwzV2SplitEnvelope {
        let data = Data(data)
        try requireLength(data, ZwzV2SplitEnvelope.encodedLength, record: "split envelope")
        try validateMagicAndVersion(
            data,
            magic: ZwzV2Format.splitMagic,
            version: ZwzV2Format.splitEnvelopeVersion,
            record: "split envelope"
        )
        try requireZeroes(data, in: 6..<8, record: "split envelope")
        try requireZeroes(data, in: 29..<32, record: "split envelope")
        try requireZeroes(data, in: 52..<ZwzV2SplitEnvelope.encodedLength, record: "split envelope")
        guard data[28] <= 1 else {
            throw malformed("invalid final-volume marker")
        }

        let logicalOffset = try readUInt64(data, at: 32)
        let payloadLength = try readUInt64(data, at: 40)
        guard !logicalOffset.addingReportingOverflow(payloadLength).overflow else {
            throw malformed("overflowing split envelope payload range")
        }

        return ZwzV2SplitEnvelope(
            archiveID: try readUUID(data, at: 8),
            volumeNumber: try readUInt32(data, at: 24),
            isFinal: data[28] == 1,
            logicalOffset: logicalOffset,
            payloadLength: payloadLength,
            payloadChecksum: try readUInt32(data, at: 48)
        )
    }

    private static func validateMagicAndVersion(
        _ data: Data,
        magic: [UInt8],
        version: UInt16,
        record: String
    ) throws {
        let actualMagic = Array(data.prefix(4))
        if actualMagic == [0x5A, 0x57, 0x5A, 0x31] {
            throw ZwzV2Error.unsupportedVersion(1)
        }
        guard actualMagic == magic else {
            throw malformed("invalid \(record) magic")
        }
        guard try readUInt16(data, at: 4) == version else {
            throw malformed("unsupported \(record) version")
        }
    }

    private static func requireLength(_ data: Data, _ length: Int, record: String) throws {
        guard data.count == length else {
            throw malformed("invalid \(record) length")
        }
    }

    private static func requireZeroes(_ data: Data, in range: Range<Int>, record: String) throws {
        guard data[range].allSatisfy({ $0 == 0 }) else {
            throw malformed("nonzero reserved \(record) bytes")
        }
    }

    private static func malformed(_ reason: String) -> ZwzV2Error {
        .malformedArchive(reason)
    }

    private static func writeMagic(_ magic: [UInt8], to data: inout Data) {
        data.replaceSubrange(0..<4, with: magic)
    }

    private static func writeUUID(_ uuid: UUID, to data: inout Data, at offset: Int) {
        let value = uuid.uuid
        data.replaceSubrange(offset..<(offset + 16), with: [
            value.0, value.1, value.2, value.3, value.4, value.5, value.6, value.7,
            value.8, value.9, value.10, value.11, value.12, value.13, value.14, value.15,
        ])
    }

    private static func readUUID(_ data: Data, at offset: Int) throws -> UUID {
        guard offset >= 0, offset + 16 <= data.count else {
            throw malformed("short UUID field")
        }
        let bytes = Array(data[offset..<(offset + 16)])
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func write<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
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

    private static func readInteger<T: FixedWidthInteger>(_ data: Data, at offset: Int, as: T.Type) throws -> T {
        guard offset >= 0, offset + MemoryLayout<T>.size <= data.count else {
            throw malformed("short integer field")
        }
        return data[offset..<(offset + MemoryLayout<T>.size)].enumerated().reduce(into: T.zero) { value, element in
            value |= T(element.element) << (element.offset * 8)
        }
    }
}
