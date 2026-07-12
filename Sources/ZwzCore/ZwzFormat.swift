import Foundation
import CryptoKit

// MARK: - ZWZ Binary File Format
//
// Layout (non-split single file):
//
// ┌──────────────────────────────────┐  Offset 0
// │  Main Header  (96 bytes)         │
// ├──────────────────────────────────┤  Offset 96
// │  Data Section (variable)        │
// │    Block 0 of entry 0           │
// │    Block 1 of entry 0           │
// │    Block 0 of entry 1           │
// │    ...                           │
// ├──────────────────────────────────┤  Offset = indexOffset
// │  Index Table (variable)         │
// ├──────────────────────────────────┤  After index
// │  Footer (32 bytes)               │
// └──────────────────────────────────┘
//
// Split volumes (.zwz.001, .zwz.002, …):
//   Each volume = Volume Header (16 bytes) + chunk of the full file above.
//   Reading: strip all volume headers, concatenate data → reconstruct full file.

/// ZWZ 文件格式常量
public enum ZwzFormat {
    /// 主头 Magic: "ZWZ\x01"
    static let magic: [UInt8] = [0x5A, 0x57, 0x5A, 0x01]
    /// 尾部 Magic: "ZWZ_END"
    static let endMagic: [UInt8] = [0x5A, 0x57, 0x5A, 0x5F, 0x45, 0x4E, 0x44]
    /// 分卷 Magic: "ZWZ_VOL"
    static let volMagic: [UInt8] = [0x5A, 0x57, 0x5A, 0x5F, 0x56, 0x4F, 0x4C]
    /// 格式版本
    static let version: UInt16 = 1
    /// 主头大小
    static let headerSize: Int = 96
    /// 尾部大小
    static let footerSize: Int = 32
    /// 分卷头大小
    static let volumeHeaderSize: Int = 16
    /// 大文件分块阈值
    static let blockThreshold: Int64 = 10 * 1024 * 1024
    /// PBKDF2 迭代次数
    static let pbkdf2Iterations: UInt32 = 100_000
    /// Salt 长度
    static let saltLength: Int = 16
    /// GCM nonce 长度
    static let gcmNonceLength: Int = 12
    /// GCM tag 长度
    static let gcmTagLength: Int = 16
    /// 加密条目存储长度 (nonce + tag)
    static let cryptoEntryLength: Int = gcmNonceLength + gcmTagLength
}

// MARK: - Flags

/// ZWZ 文件标志位
public struct ZwzFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// 加密
    public static let encrypted = ZwzFlags(rawValue: 0x0001)
    /// 分卷
    public static let splitted = ZwzFlags(rawValue: 0x0002)
}

// MARK: - Index Entry

/// ZWZ 索引表中的一个条目信息
public struct ZwzIndexEntry: Sendable {
    public let name: String
    public let path: String
    public let originalSize: Int64
    public let isDirectory: Bool
    public let modifiedDate: Date?
    public let blocks: [ZwzBlockInfo]
    public let gcmNonce: [UInt8]?  // 加密时的 GCM nonce (12 bytes)
    public let gcmTag: [UInt8]?    // 加密时的 GCM 认证标签 (16 bytes)

    public init(
        name: String,
        path: String,
        originalSize: Int64,
        isDirectory: Bool,
        modifiedDate: Date?,
        blocks: [ZwzBlockInfo],
        gcmNonce: [UInt8]? = nil,
        gcmTag: [UInt8]? = nil
    ) {
        self.name = name
        self.path = path
        self.originalSize = originalSize
        self.isDirectory = isDirectory
        self.modifiedDate = modifiedDate
        self.blocks = blocks
        self.gcmNonce = gcmNonce
        self.gcmTag = gcmTag
    }

    /// 压缩后总大小
    public var compressedSize: Int64 {
        blocks.reduce(Int64(0)) { $0 + $1.compressedSize }
    }
}

/// ZWZ 数据块信息
public struct ZwzBlockInfo: Sendable {
    public let dataOffset: UInt64   // 在文件中的绝对偏移
    public let compressedSize: Int64
    public let originalSize: Int64
    public let crc32: UInt32

    public init(dataOffset: UInt64, compressedSize: Int64, originalSize: Int64, crc32: UInt32) {
        self.dataOffset = dataOffset
        self.compressedSize = compressedSize
        self.originalSize = originalSize
        self.crc32 = crc32
    }
}

// MARK: - Binary Reader/Writer

/// ZWZ 二进制读写工具
public struct ZwzBinaryCodec {

    // MARK: - Write

    public static func writeMainHeader(
        to handle: FileHandle,
        flags: ZwzFlags,
        compressionMethod: ZwzCompressionMethod,
        entryCount: UInt32,
        indexOffset: UInt64,
        indexSize: UInt64,
        iv: [UInt8],
        salt: [UInt8],
        pbkdf2Iterations: UInt32
    ) throws {
        var data = Data()
        data.append(contentsOf: ZwzFormat.magic)              // 4 bytes
        appendUint16LE(ZwzFormat.version, to: &data)           // 2 bytes
        appendUint16LE(flags.rawValue, to: &data)              // 2 bytes
        data.append(compressionMethod.rawValue)                // 1 byte
        data.append(0)                                         // reserved 1 byte
        appendUint32LE(entryCount, to: &data)                  // 4 bytes
        appendUint64LE(indexOffset, to: &data)                // 8 bytes
        appendUint64LE(indexSize, to: &data)                   // 8 bytes
        appendInt64LE(Int64(Date().timeIntervalSince1970), to: &data) // 8 bytes
        // IV (12 bytes)
        var ivPadded = iv
        while ivPadded.count < ZwzFormat.gcmNonceLength { ivPadded.append(0) }
        data.append(contentsOf: ivPadded.prefix(ZwzFormat.gcmNonceLength))
        // Salt (16 bytes)
        var saltPadded = salt
        while saltPadded.count < ZwzFormat.saltLength { saltPadded.append(0) }
        data.append(contentsOf: saltPadded.prefix(ZwzFormat.saltLength))
        // PBKDF2 iterations (4 bytes)
        appendUint32LE(pbkdf2Iterations, to: &data)
        // Reserved to 96 bytes
        while data.count < ZwzFormat.headerSize { data.append(0) }
        handle.seek(toFileOffset: 0)
        handle.write(data)
    }

    public static func writeFooter(
        to handle: FileHandle,
        indexOffset: UInt64,
        entryCount: UInt32,
        indexCRC32: UInt32
    ) throws {
        var data = Data()
        data.append(contentsOf: ZwzFormat.endMagic)            // 7 bytes
        appendUint64LE(indexOffset, to: &data)                 // 8 bytes
        appendUint32LE(entryCount, to: &data)                  // 4 bytes
        appendUint32LE(indexCRC32, to: &data)                  // 4 bytes
        appendUint16LE(ZwzFormat.version, to: &data)           // 2 bytes
        while data.count < ZwzFormat.footerSize { data.append(0) } // pad to 32
        let pos = handle.seekToEndOfFile()
        _ = pos
        handle.write(data)
    }

    public static func writeIndexTable(
        to handle: FileHandle,
        entries: [ZwzIndexEntry],
        encrypted: Bool
    ) throws -> (offset: UInt64, size: UInt64, crc32: UInt32) {
        let offset = handle.seekToEndOfFile()
        var data = Data()

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            appendUint16LE(UInt16(nameBytes.count), to: &data)
            data.append(contentsOf: nameBytes)

            let pathBytes = Array(entry.path.utf8)
            appendUint16LE(UInt16(pathBytes.count), to: &data)
            data.append(contentsOf: pathBytes)

            appendInt64LE(entry.originalSize, to: &data)
            data.append(entry.isDirectory ? UInt8(1) : UInt8(0))

            let modTime = entry.modifiedDate.map { Int64($0.timeIntervalSince1970) } ?? 0
            appendInt64LE(modTime, to: &data)

            appendUint16LE(UInt16(entry.blocks.count), to: &data)
            for block in entry.blocks {
                appendUint64LE(block.dataOffset, to: &data)
                appendInt64LE(block.compressedSize, to: &data)
                appendInt64LE(block.originalSize, to: &data)
                appendUint32LE(block.crc32, to: &data)
            }

            if encrypted {
                // 写入 nonce (12 bytes) + tag (16 bytes) = 28 bytes
                var nonce = entry.gcmNonce ?? []
                while nonce.count < ZwzFormat.gcmNonceLength { nonce.append(0) }
                data.append(contentsOf: nonce.prefix(ZwzFormat.gcmNonceLength))
                var tag = entry.gcmTag ?? []
                while tag.count < ZwzFormat.gcmTagLength { tag.append(0) }
                data.append(contentsOf: tag.prefix(ZwzFormat.gcmTagLength))
            }
        }

        let crc = crc32(data)
        handle.write(data)
        let size = UInt64(data.count)
        return (offset, size, crc)
    }

    // MARK: - Read

    public struct ZwzMainHeader {
        public let version: UInt16
        public let flags: ZwzFlags
        public let compressionMethod: ZwzCompressionMethod
        public let entryCount: UInt32
        public let indexOffset: UInt64
        public let indexSize: UInt64
        public let createdDate: Date
        public let iv: [UInt8]
        public let salt: [UInt8]
        public let pbkdf2Iterations: UInt32
    }

    public static func readMainHeader(from handle: FileHandle) throws -> ZwzMainHeader {
        handle.seek(toFileOffset: 0)
        let headerData = handle.readData(ofLength: ZwzFormat.headerSize)
        guard headerData.count >= ZwzFormat.headerSize else {
            throw ZwzError.invalidFormat("ZWZ header too short")
        }

        // Verify magic
        let magic = Array(headerData[0..<4])
        guard magic == ZwzFormat.magic else {
            throw ZwzError.invalidFormat("Invalid ZWZ magic bytes")
        }

        var pos = 4
        let version = readUint16LE(headerData, at: &pos)
        let flags = ZwzFlags(rawValue: readUint16LE(headerData, at: &pos))
        let methodByte = headerData[pos]; pos += 1
        pos += 1 // reserved
        let entryCount = readUint32LE(headerData, at: &pos)
        let indexOffset = readUint64LE(headerData, at: &pos)
        let indexSize = readUint64LE(headerData, at: &pos)
        let createdTimestamp = readInt64LE(headerData, at: &pos)
        let iv = Array(headerData[pos..<pos+ZwzFormat.gcmNonceLength]); pos += ZwzFormat.gcmNonceLength
        let salt = Array(headerData[pos..<pos+ZwzFormat.saltLength]); pos += ZwzFormat.saltLength
        let iterations = readUint32LE(headerData, at: &pos)

        guard let method = ZwzCompressionMethod(rawValue: methodByte) else {
            throw ZwzError.invalidFormat("Unknown compression method: \(methodByte)")
        }

        return ZwzMainHeader(
            version: version,
            flags: flags,
            compressionMethod: method,
            entryCount: entryCount,
            indexOffset: indexOffset,
            indexSize: indexSize,
            createdDate: Date(timeIntervalSince1970: TimeInterval(createdTimestamp)),
            iv: iv,
            salt: salt,
            pbkdf2Iterations: iterations
        )
    }

    public static func readIndexTable(
        from handle: FileHandle,
        header: ZwzMainHeader
    ) throws -> [ZwzIndexEntry] {
        handle.seek(toFileOffset: header.indexOffset)
        let indexData = handle.readData(ofLength: Int(header.indexSize))
        guard indexData.count == Int(header.indexSize) else {
            throw ZwzError.invalidFormat("ZWZ index table truncated")
        }

        var pos = 0
        var entries: [ZwzIndexEntry] = []
        let encrypted = header.flags.contains(.encrypted)

        for _ in 0..<header.entryCount {
            guard pos + 2 <= indexData.count else { throw ZwzError.invalidFormat("ZWZ index: name length truncated") }
            let nameLen = Int(readUint16LE(indexData, at: &pos))
            guard pos + nameLen <= indexData.count else { throw ZwzError.invalidFormat("ZWZ index: name truncated") }
            let name = String(data: indexData.subdata(in: pos..<pos+nameLen), encoding: .utf8) ?? ""
            pos += nameLen

            guard pos + 2 <= indexData.count else { throw ZwzError.invalidFormat("ZWZ index: path length truncated") }
            let pathLen = Int(readUint16LE(indexData, at: &pos))
            guard pos + pathLen <= indexData.count else { throw ZwzError.invalidFormat("ZWZ index: path truncated") }
            let path = String(data: indexData.subdata(in: pos..<pos+pathLen), encoding: .utf8) ?? ""
            pos += pathLen

            guard pos + 8 <= indexData.count else { throw ZwzError.invalidFormat("ZWZ index: size truncated") }
            let originalSize = readInt64LE(indexData, at: &pos)

            guard pos + 1 <= indexData.count else { throw ZwzError.invalidFormat("ZWZ index: isDir truncated") }
            let isDir = indexData[pos] == 1; pos += 1

            guard pos + 8 <= indexData.count else { throw ZwzError.invalidFormat("ZWZ index: date truncated") }
            let modTime = readInt64LE(indexData, at: &pos)
            let modDate = modTime != 0 ? Date(timeIntervalSince1970: TimeInterval(modTime)) : nil

            guard pos + 2 <= indexData.count else { throw ZwzError.invalidFormat("ZWZ index: block count truncated") }
            let blockCount = Int(readUint16LE(indexData, at: &pos))

            var blocks: [ZwzBlockInfo] = []
            for _ in 0..<blockCount {
                guard pos + 28 <= indexData.count else { throw ZwzError.invalidFormat("ZWZ index: block info truncated") }
                let dataOffset = readUint64LE(indexData, at: &pos)
                let compSize = readInt64LE(indexData, at: &pos)
                let origSize = readInt64LE(indexData, at: &pos)
                let crc = readUint32LE(indexData, at: &pos)
                blocks.append(ZwzBlockInfo(dataOffset: dataOffset, compressedSize: compSize, originalSize: origSize, crc32: crc))
            }

            var gcmNonce: [UInt8]? = nil
            var gcmTag: [UInt8]? = nil
            if encrypted {
                guard pos + ZwzFormat.cryptoEntryLength <= indexData.count else { throw ZwzError.invalidFormat("ZWZ index: crypto entry truncated") }
                gcmNonce = Array(indexData[pos..<pos+ZwzFormat.gcmNonceLength])
                pos += ZwzFormat.gcmNonceLength
                gcmTag = Array(indexData[pos..<pos+ZwzFormat.gcmTagLength])
                pos += ZwzFormat.gcmTagLength
            }

            entries.append(ZwzIndexEntry(
                name: name, path: path,
                originalSize: originalSize, isDirectory: isDir,
                modifiedDate: modDate, blocks: blocks,
                gcmNonce: gcmNonce, gcmTag: gcmTag
            ))
        }

        return entries
    }

    // MARK: - Split Volume

    public static func writeVolumeHeader(
        to handle: FileHandle,
        volumeNumber: UInt16,
        totalVolumes: UInt16,
        dataSize: UInt32
    ) {
        var data = Data()
        data.append(contentsOf: ZwzFormat.volMagic)  // 7 bytes
        appendUint16LE(volumeNumber, to: &data)      // 2 bytes
        appendUint16LE(totalVolumes, to: &data)      // 2 bytes
        appendUint32LE(dataSize, to: &data)          // 4 bytes
        // pad to 16
        while data.count < ZwzFormat.volumeHeaderSize { data.append(0) }
        handle.write(data)
    }

    public struct VolumeHeader {
        public let volumeNumber: UInt16
        public let totalVolumes: UInt16
        public let dataSize: UInt32
    }

    public static func readVolumeHeader(from handle: FileHandle) throws -> VolumeHeader {
        let data = handle.readData(ofLength: ZwzFormat.volumeHeaderSize)
        guard data.count >= ZwzFormat.volumeHeaderSize else {
            throw ZwzError.invalidFormat("ZWZ volume header too short")
        }
        let magic = Array(data[0..<7])
        guard magic == ZwzFormat.volMagic else {
            throw ZwzError.invalidFormat("Invalid ZWZ volume magic")
        }
        var pos = 7
        let volNum = readUint16LE(data, at: &pos)
        let totalVols = readUint16LE(data, at: &pos)
        let dataSize = readUint32LE(data, at: &pos)
        return VolumeHeader(volumeNumber: volNum, totalVolumes: totalVols, dataSize: dataSize)
    }

    // MARK: - Low-level read helpers

    static func readUint16LE(_ data: Data, at pos: inout Int) -> UInt16 {
        let lo = UInt16(data[pos])
        let hi = UInt16(data[pos+1])
        pos += 2
        return lo | (hi << 8)
    }
    static func readUint32LE(_ data: Data, at pos: inout Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(data[pos+i]) << (i*8) }
        pos += 4
        return v
    }
    static func readUint64LE(_ data: Data, at pos: inout Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(data[pos+i]) << (i*8) }
        pos += 8
        return v
    }
    static func readInt64LE(_ data: Data, at pos: inout Int) -> Int64 {
        return Int64(bitPattern: readUint64LE(data, at: &pos))
    }
}

// MARK: - Global LE helpers (used by ZwzBinaryCodec methods)

func appendUint16LE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
}
func appendUint32LE(_ value: UInt32, to data: inout Data) {
    for i in 0..<4 { data.append(UInt8((value >> (i*8)) & 0xFF)) }
}
func appendUint64LE(_ value: UInt64, to data: inout Data) {
    for i in 0..<8 { data.append(UInt8((value >> (i*8)) & 0xFF)) }
}
func appendInt64LE(_ value: Int64, to data: inout Data) {
    let u = UInt64(bitPattern: value)
    for i in 0..<8 { data.append(UInt8((u >> (i*8)) & 0xFF)) }
}

// MARK: - CRC32

func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                if c & 1 != 0 { c = 0xEDB88320 ^ (c >> 1) }
                else { c >>= 1 }
            }
            t[i] = c
        }
        return t
    }()
    for byte in data {
        crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFFFFFF
}

// MARK: - Crypto Helpers (AES-256-GCM via CryptoKit)

func deriveAESKey(password: String, salt: [UInt8], iterations: UInt32) -> SymmetricKey {
    let passwordData = Data(password.utf8)
    let saltData = Data(salt)
    let derivedKey = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: passwordData),
        salt: saltData,
        info: Data("ZWZ-AES256-GCM".utf8),
        outputByteCount: 32
    )
    // For PBKDF2-like behavior, we use HKDF which is available in CryptoKit.
    // For additional iterations, we apply multiple rounds of SHA256.
    var key = derivedKey
    for _ in 0..<min(iterations, 10_000) {
        key = SymmetricKey(data: SHA256.hash(data: key.withUnsafeBytes { Data($0) })
            .withUnsafeBytes { Data($0) })
    }
    return SymmetricKey(data: Data(key.withUnsafeBytes { Data($0) }))
}

func aesGcmEncrypt(data: Data, key: SymmetricKey, nonce: AES.GCM.Nonce) throws -> (ciphertext: Data, tag: [UInt8]) {
    let sealed = try AES.GCM.seal(data, using: key, nonce: nonce)
    return (sealed.ciphertext, Array(sealed.tag))
}

func aesGcmDecrypt(ciphertext: Data, key: SymmetricKey, nonce: AES.GCM.Nonce, tag: [UInt8]) throws -> Data {
    let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
    return try AES.GCM.open(sealed, using: key)
}

func makeGCMNonce(from iv: [UInt8]) throws -> AES.GCM.Nonce {
    let nonceBytes = Array(iv.prefix(ZwzFormat.gcmNonceLength))
    return try AES.GCM.Nonce(data: nonceBytes)
}

func generateRandomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    return bytes
}
