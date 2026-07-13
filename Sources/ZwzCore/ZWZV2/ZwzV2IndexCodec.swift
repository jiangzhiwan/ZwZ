import Foundation

public enum ZwzV2IndexCodec {
    private static let magic = Data("ZWZI".utf8)
    private static let version: UInt16 = 2
    private static let minimumEntryLength = 24
    private static let minimumBlockLength = 38

    public static func encodePlain(_ index: ZwzV2Index) throws -> Data {
        guard index.blockSize > 0, index.blockSize <= Int(UInt32.max) else {
            throw malformed("invalid index block size")
        }
        guard index.entries.count <= Int(UInt32.max) else {
            throw malformed("too many index entries")
        }

        try ZwzV2PathValidator.validateNoDuplicatePaths(index.entries)

        var writer = Writer()
        writer.write(magic)
        writer.write(version)
        writer.write(index.archiveID)
        writer.write(UInt32(index.blockSize))
        writer.write(UInt32(index.entries.count))

        for entry in index.entries {
            let path = Data(entry.path.utf8)
            guard path.count <= Int(UInt16.max) else {
                throw malformed("index path is too long")
            }
            guard entry.blocks.count <= Int(UInt32.max) else {
                throw malformed("too many entry blocks")
            }
            let modificationTimeMilliseconds = entry.modificationTime.timeIntervalSince1970 * 1_000
            let roundedModificationTimeMilliseconds = modificationTimeMilliseconds.rounded()
            guard modificationTimeMilliseconds.isFinite,
                  roundedModificationTimeMilliseconds == modificationTimeMilliseconds,
                  let modificationTimeMillisecondsInt64 = Int64(exactly: roundedModificationTimeMilliseconds) else {
                throw malformed("invalid index modification time")
            }

            writer.write(UInt16(path.count))
            writer.write(path)
            writer.write(entry.type.rawValue)
            writer.write(entry.originalSize)
            writer.write(UInt64(bitPattern: modificationTimeMillisecondsInt64))
            writer.write(entry.isHidden ? UInt8(1) : UInt8(0))
            writer.write(UInt32(entry.blocks.count))

            for block in entry.blocks {
                guard block.authenticationTag.count <= Int(UInt8.max) else {
                    throw malformed("block authentication tag is too long")
                }
                writer.write(block.sequence)
                writer.write(block.fileOffset)
                writer.write(block.archiveOffset)
                writer.write(block.storedLength)
                writer.write(block.originalLength)
                writer.write(block.codec.rawValue)
                writer.write(block.checksum)
                writer.write(UInt8(block.authenticationTag.count))
                writer.write(Data(block.authenticationTag))
            }
        }

        return writer.data
    }

    public static func decodePlain(_ data: Data) throws -> ZwzV2Index {
        var reader = Reader(data: data)
        guard try reader.readData(count: 4) == magic else {
            throw malformed("invalid index magic")
        }
        guard try reader.read(UInt16.self) == version else {
            throw malformed("unsupported index version")
        }

        let archiveID = try reader.readUUID()
        let blockSize = try reader.read(UInt32.self)
        guard blockSize > 0 else {
            throw malformed("invalid index block size")
        }

        let entryCount = try reader.read(UInt32.self)
        guard UInt64(entryCount) <= UInt64(reader.remaining / minimumEntryLength) else {
            throw malformed("impossible index entry count")
        }

        var entries = [ZwzV2Entry]()
        for _ in 0..<entryCount {
            let pathLength = Int(try reader.read(UInt16.self))
            let pathBytes = try reader.readData(count: pathLength)
            guard let path = String(data: pathBytes, encoding: .utf8) else {
                throw malformed("invalid index path UTF-8")
            }
            guard let type = ZwzV2EntryType(rawValue: try reader.read(UInt8.self)) else {
                throw malformed("unknown index entry type")
            }

            let originalSize = try reader.read(UInt64.self)
            let modificationTimeMilliseconds = Int64(bitPattern: try reader.read(UInt64.self))
            let hiddenFlag = try reader.read(UInt8.self)
            guard hiddenFlag <= 1 else {
                throw malformed("invalid index hidden flag")
            }
            let blockCount = try reader.read(UInt32.self)
            guard UInt64(blockCount) <= UInt64(reader.remaining / minimumBlockLength) else {
                throw malformed("impossible index block count")
            }

            var blocks = [ZwzV2BlockDescriptor]()
            for _ in 0..<blockCount {
                let sequence = try reader.read(UInt64.self)
                let fileOffset = try reader.read(UInt64.self)
                let archiveOffset = try reader.read(UInt64.self)
                let storedLength = try reader.read(UInt32.self)
                let originalLength = try reader.read(UInt32.self)
                guard let codec = ZwzV2Codec(rawValue: try reader.read(UInt8.self)) else {
                    throw malformed("unknown index block codec")
                }
                let checksum = try reader.read(UInt32.self)
                let tagLength = Int(try reader.read(UInt8.self))
                let tag = Array(try reader.readData(count: tagLength))

                blocks.append(ZwzV2BlockDescriptor(
                    sequence: sequence,
                    fileOffset: fileOffset,
                    archiveOffset: archiveOffset,
                    storedLength: storedLength,
                    originalLength: originalLength,
                    codec: codec,
                    checksum: checksum,
                    authenticationTag: tag
                ))
            }

            entries.append(ZwzV2Entry(
                path: path,
                type: type,
                originalSize: originalSize,
                modificationTime: Date(timeIntervalSince1970: Double(modificationTimeMilliseconds) / 1_000),
                isHidden: hiddenFlag == 1,
                blocks: blocks
            ))
        }

        guard reader.isAtEnd else {
            throw malformed("trailing index bytes")
        }

        try ZwzV2PathValidator.validateNoDuplicatePaths(entries)
        return ZwzV2Index(archiveID: archiveID, blockSize: Int(blockSize), entries: entries)
    }

    public static func encodeForArchive(
        _ index: ZwzV2Index,
        context: ZwzV2CryptoContext?
    ) throws -> (payload: Data, tag: Data) {
        let plaintext = try encodePlain(index)
        guard let context else {
            return (plaintext, Data())
        }
        let sealed = try ZwzV2Crypto.sealIndex(plaintext, context: context)
        return (sealed.ciphertext, sealed.tag)
    }

    public static func decodeFromArchive(
        payload: Data,
        tag: Data,
        context: ZwzV2CryptoContext?
    ) throws -> ZwzV2Index {
        let plaintext: Data
        if let context {
            plaintext = try ZwzV2Crypto.openIndex(payload, tag: tag, context: context)
        } else {
            guard tag.isEmpty else {
                throw malformed("unexpected plaintext index authentication tag")
            }
            plaintext = payload
        }
        return try decodePlain(plaintext)
    }

    private static func malformed(_ reason: String) -> ZwzV2Error {
        .malformedArchive(reason)
    }
}

private struct Writer {
    var data = Data()

    mutating func write(_ value: Data) {
        data.append(value)
    }

    mutating func write(_ value: UUID) {
        let bytes = value.uuid
        data.append(contentsOf: [
            bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15,
        ])
    }

    mutating func write<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}

private struct Reader {
    private let data: Data
    private(set) var offset = 0

    init(data: Data) {
        self.data = Data(data)
    }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { offset == data.count }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= remaining else {
            throw ZwzV2Error.malformedArchive("truncated index data")
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readUUID() throws -> UUID {
        let bytes = Array(try readData(count: 16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    mutating func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let bytes = try readData(count: MemoryLayout<T>.size)
        return bytes.enumerated().reduce(into: T.zero) { value, element in
            value |= T(element.element) << (element.offset * 8)
        }
    }
}
