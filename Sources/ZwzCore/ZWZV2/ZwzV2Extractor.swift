import Foundation

public struct ZwzV2RecoveryReport: Equatable, Sendable {
    public var extractedEntries: [String]
    public var failedEntries: [String]
    public var failedBlocks: [UInt64]

    public init(extractedEntries: [String] = [], failedEntries: [String] = [], failedBlocks: [UInt64] = []) {
        self.extractedEntries = extractedEntries
        self.failedEntries = failedEntries
        self.failedBlocks = failedBlocks
    }
}

public final class ZwzV2Extractor {
    private let options: ZwzV2Options

    public init(options: ZwzV2Options = ZwzV2Options()) {
        self.options = options
    }

    public func preview(archiveURLs: [URL], password: String?) async throws -> ZwzV2Index {
        let archive = try openArchive(archiveURLs: archiveURLs, password: password)
        return archive.index
    }

    public func extractAll(
        archiveURLs: [URL],
        to destination: URL,
        password: String?
    ) async throws -> ZwzV2RecoveryReport {
        let archive = try openArchive(archiveURLs: archiveURLs, password: password)
        return try await extract(
            entries: archive.index.entries,
            archive: archive,
            to: destination,
            maximumBytes: nil,
            cancellationToken: nil
        )
    }

    public func extractEntry(
        path: String,
        archiveURLs: [URL],
        to destination: URL,
        password: String?,
        maximumBytes: Int64? = nil,
        cancellationToken: CancellationToken? = nil
    ) async throws -> ZwzV2RecoveryReport {
        try cancellationToken?.checkCancellation()
        try Task.checkCancellation()
        if let maximumBytes, maximumBytes < 0 {
            throw ZwzError.extractionFailed("Invalid single-entry extraction byte limit")
        }
        let archive = try openArchive(archiveURLs: archiveURLs, password: password)
        try cancellationToken?.checkCancellation()
        try Task.checkCancellation()
        guard let rootEntry = archive.index.entries.first(where: { $0.path == path }) else {
            throw ZwzV2Error.malformedArchive("requested entry not found")
        }

        let selectedEntries: [ZwzV2Entry]
        if rootEntry.type == .directory {
            selectedEntries = archive.index.entries.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
        } else {
            selectedEntries = [rootEntry]
        }
        try enforceExtractionBudget(entries: selectedEntries, maximumBytes: maximumBytes)
        return try await extract(
            entries: selectedEntries,
            archive: archive,
            to: destination,
            maximumBytes: maximumBytes,
            cancellationToken: cancellationToken
        )
    }

    private func openArchive(archiveURLs: [URL], password: String?) throws -> ZwzV2OpenedArchive {
        let reader = try ZwzV2VolumeReader(urls: archiveURLs)
        let header = try ZwzV2BinaryCodec.decodeHeader(reader.read(offset: 0, length: ZwzV2Header.encodedLength))
        let logicalLength = try Self.logicalLength(of: archiveURLs)
        guard logicalLength >= UInt64(ZwzV2Header.encodedLength + ZwzV2Footer.encodedLength) else {
            throw ZwzV2Error.malformedArchive("archive is too short")
        }

        let footerOffset = logicalLength - UInt64(ZwzV2Footer.encodedLength)
        let footer = try ZwzV2BinaryCodec.decodeFooter(reader.read(offset: footerOffset, length: ZwzV2Footer.encodedLength))
        guard footer.archiveID == header.archiveID else {
            throw ZwzV2Error.malformedArchive("header and footer archive IDs do not match")
        }
        guard !footer.indexOffset.addingReportingOverflow(footer.indexLength).overflow,
              footer.indexOffset + footer.indexLength <= footerOffset else {
            throw ZwzV2Error.malformedArchive("index range exceeds archive metadata bounds")
        }

        let context = try makeCryptoContext(header: header, password: password)
        let payload = try reader.read(offset: footer.indexOffset, length: Int(footer.indexLength))
        guard checksum(of: payload) == footer.indexChecksum else {
            throw ZwzV2Error.malformedArchive("index checksum mismatch")
        }

        let tagLength = header.flags.contains(.encrypted) ? 16 : 0
        guard footer.indexOffset + footer.indexLength + UInt64(tagLength) <= footerOffset else {
            throw ZwzV2Error.malformedArchive("index authentication tag exceeds archive metadata bounds")
        }
        let tag = try reader.read(offset: footer.indexOffset + footer.indexLength, length: tagLength)
        let index = try ZwzV2IndexCodec.decodeFromArchive(payload: payload, tag: tag, context: context)
        guard index.archiveID == header.archiveID else {
            throw ZwzV2Error.malformedArchive("index archive ID does not match header")
        }
        guard index.blockSize == Int(header.blockSize) else {
            throw ZwzV2Error.malformedArchive("index block size does not match header")
        }
        try validateIndexLayout(index)

        return ZwzV2OpenedArchive(reader: reader, header: header, index: index, context: context)
    }

    private func extract(
        entries: [ZwzV2Entry],
        archive: ZwzV2OpenedArchive,
        to destination: URL,
        maximumBytes: Int64?,
        cancellationToken: CancellationToken?
    ) async throws -> ZwzV2RecoveryReport {
        try cancellationToken?.checkCancellation()
        try Task.checkCancellation()
        try enforceExtractionBudget(entries: entries, maximumBytes: maximumBytes)
        var report = ZwzV2RecoveryReport()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        for entry in entries where entry.type == .directory {
            try cancellationToken?.checkCancellation()
            try Task.checkCancellation()
            let outputURL = try outputURL(for: entry.path, destination: destination)
            try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.modificationDate: entry.modificationTime], ofItemAtPath: outputURL.path)
            report.extractedEntries.append(entry.path)
        }

        for entry in entries where entry.type == .file {
            try cancellationToken?.checkCancellation()
            try Task.checkCancellation()
            let outputURL = try outputURL(for: entry.path, destination: destination)
            do {
                try await extractFile(
                    entry,
                    archive: archive,
                    to: outputURL,
                    cancellationToken: cancellationToken
                )
                try? fileManager.setAttributes([.modificationDate: entry.modificationTime], ofItemAtPath: outputURL.path)
                report.extractedEntries.append(entry.path)
            } catch {
                try? fileManager.removeItem(at: outputURL)
                if cancellationToken?.isCancelled == true || error is CancellationError {
                    throw error
                }
                report.failedEntries.append(entry.path)
                report.failedBlocks.append(contentsOf: entry.blocks.map(\.sequence))
                if options.recoveryPolicy == .strict {
                    throw error
                }
            }
        }

        return report
    }

    private func extractFile(
        _ entry: ZwzV2Entry,
        archive: ZwzV2OpenedArchive,
        to outputURL: URL,
        cancellationToken: CancellationToken?
    ) async throws {
        try cancellationToken?.checkCancellation()
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: outputURL.path) {
            let values = try outputURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory != true else {
                throw ZwzV2Error.unsafePath(entry.path)
            }
            try fileManager.removeItem(at: outputURL)
        }
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            throw ZwzV2Error.malformedArchive("could not create extraction output file")
        }
        let writer = try ZwzV2FileWriter(url: outputURL)
        defer { try? writer.close() }

        try await withThrowingTaskGroup(of: ZwzV2DecodedArchiveBlock.self) { group in
            var inFlight = 0
            var nextBlockIndex = 0

            func schedule(_ block: ZwzV2BlockDescriptor) {
                let reader = archive.reader
                let context = archive.context
                group.addTask {
                    try cancellationToken?.checkCancellation()
                    try Task.checkCancellation()
                    let decoded = try decode(block: block, reader: reader, context: context)
                    try cancellationToken?.checkCancellation()
                    try Task.checkCancellation()
                    return decoded
                }
                inFlight += 1
            }

            while nextBlockIndex < entry.blocks.count && inFlight < options.maxInFlightBlocks {
                try cancellationToken?.checkCancellation()
                try Task.checkCancellation()
                schedule(entry.blocks[nextBlockIndex])
                nextBlockIndex += 1
            }

            while inFlight > 0 {
                try cancellationToken?.checkCancellation()
                try Task.checkCancellation()
                guard let block = try await group.next() else {
                    throw ZwzV2Error.malformedArchive("extraction task ended unexpectedly")
                }
                inFlight -= 1
                try cancellationToken?.checkCancellation()
                try Task.checkCancellation()
                try writer.write(block.data, at: block.fileOffset)

                if nextBlockIndex < entry.blocks.count {
                    schedule(entry.blocks[nextBlockIndex])
                    nextBlockIndex += 1
                }
            }
        }
    }

    private func enforceExtractionBudget(
        entries: [ZwzV2Entry],
        maximumBytes: Int64?
    ) throws {
        guard let maximumBytes else { return }
        let limit = UInt64(maximumBytes)
        var total: UInt64 = 0
        for entry in entries where entry.type == .file {
            let next = total.addingReportingOverflow(entry.originalSize)
            guard !next.overflow, next.partialValue <= limit else {
                throw ZwzError.extractionFailed("Archive entry exceeds the extraction byte limit")
            }
            total = next.partialValue
        }
    }

    private func outputURL(for path: String, destination: URL) throws -> URL {
        let outputURL = try ZwzV2PathValidator.validateExtractionPath(path, destination: destination)
        try rejectExistingSymlinkComponents(path, destination: destination)
        return outputURL
    }

    private func rejectExistingSymlinkComponents(_ path: String, destination: URL) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var current = destination.standardizedFileURL
        for component in components {
            current = current.appendingPathComponent(component)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw ZwzV2Error.unsafePath(path)
            }
        }
    }

    private func validateIndexLayout(_ index: ZwzV2Index) throws {
        var seenSequences = Set<UInt64>()
        for entry in index.entries {
            switch entry.type {
            case .directory:
                guard entry.blocks.isEmpty else {
                    throw ZwzV2Error.malformedArchive("directory entry cannot contain data blocks")
                }
            case .file:
                try validateFileLayout(entry, seenSequences: &seenSequences)
            }
        }
    }

    private func validateFileLayout(_ entry: ZwzV2Entry, seenSequences: inout Set<UInt64>) throws {
        var expectedOffset: UInt64 = 0
        for block in entry.blocks {
            guard seenSequences.insert(block.sequence).inserted else {
                throw ZwzV2Error.malformedArchive("duplicate block sequence in index")
            }
            guard block.fileOffset == expectedOffset else {
                throw ZwzV2Error.malformedArchive("non-contiguous block layout")
            }
            guard block.originalLength > 0 else {
                throw ZwzV2Error.malformedArchive("invalid empty file block")
            }
            let (nextOffset, overflow) = expectedOffset.addingReportingOverflow(UInt64(block.originalLength))
            guard !overflow, nextOffset <= entry.originalSize else {
                throw ZwzV2Error.malformedArchive("block layout exceeds file size")
            }
            expectedOffset = nextOffset
        }
        guard expectedOffset == entry.originalSize else {
            throw ZwzV2Error.malformedArchive("block layout does not cover file size")
        }
    }

    private func makeCryptoContext(header: ZwzV2Header, password: String?) throws -> ZwzV2CryptoContext? {
        guard header.flags.contains(.encrypted) else {
            return nil
        }
        guard let password, !password.isEmpty else {
            throw ZwzV2Error.wrongPasswordOrTamperedData
        }
        return try ZwzV2Crypto.deriveContext(
            password: password,
            salt: header.kdfSalt,
            iterations: header.kdfIterations,
            archiveID: header.archiveID
        )
    }

    private static func logicalLength(of urls: [URL]) throws -> UInt64 {
        var total: UInt64 = 0
        for url in urls {
            let size = try fileSize(of: url)
            let prefix = size >= 4 ? try readExactly(from: url, offset: 0, length: 4) : Data()
            let payloadLength = Array(prefix) == ZwzV2Format.splitMagic
                ? size - UInt64(ZwzV2SplitEnvelope.encodedLength)
                : size
            guard !total.addingReportingOverflow(payloadLength).overflow else {
                throw ZwzV2Error.malformedArchive("overflowing logical archive length")
            }
            total += payloadLength
        }
        return total
    }

    private static func fileSize(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw ZwzV2Error.malformedArchive("could not determine archive volume size")
        }
        return size.uint64Value
    }

    private static func readExactly(from url: URL, offset: UInt64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: length), data.count == length else {
            throw ZwzV2Error.malformedArchive("truncated archive volume")
        }
        return data
    }

    private func checksum(of data: Data) -> UInt32 {
        var value: UInt32 = 2_166_136_261
        for byte in data {
            value ^= UInt32(byte)
            value &*= 16_777_619
        }
        return value
    }
}

private func decode(
    block: ZwzV2BlockDescriptor,
    reader: ZwzV2VolumeReader,
    context: ZwzV2CryptoContext?
) throws -> ZwzV2DecodedArchiveBlock {
    let header = try ZwzV2BinaryCodec.decodeBlockRecordHeader(
        reader.read(offset: block.archiveOffset, length: ZwzV2BlockRecordHeader.encodedLength)
    )
    guard header.sequence == block.sequence,
          header.codec == block.codec,
          header.storedLength == block.storedLength,
          header.originalLength == block.originalLength,
          header.checksum == block.checksum,
          Int(header.tagLength) == block.authenticationTag.count else {
        throw ZwzV2Error.malformedArchive("block record header does not match index descriptor")
    }

    let payloadOffset = block.archiveOffset + UInt64(ZwzV2BlockRecordHeader.encodedLength)
    let payload = try reader.read(offset: payloadOffset, length: Int(block.storedLength))
    let tag = try reader.read(offset: payloadOffset + UInt64(block.storedLength), length: block.authenticationTag.count)
    guard Array(tag) == block.authenticationTag else {
        throw ZwzV2Error.wrongPasswordOrTamperedData
    }

    let encodedPayload: Data
    if let context {
        encodedPayload = try ZwzV2Crypto.openBlock(payload, tag: tag, sequence: block.sequence, context: context)
    } else {
        encodedPayload = payload
    }
    let data = try ZwzV2BlockCodec.decode(
        codec: block.codec,
        payload: encodedPayload,
        originalLength: Int(block.originalLength),
        sequence: block.sequence
    )
    guard checksum(of: data) == block.checksum else {
        throw ZwzV2Error.checksumMismatch(sequence: block.sequence)
    }
    return ZwzV2DecodedArchiveBlock(fileOffset: block.fileOffset, data: data)
}

private func checksum(of data: Data) -> UInt32 {
    var value: UInt32 = 2_166_136_261
    for byte in data {
        value ^= UInt32(byte)
        value &*= 16_777_619
    }
    return value
}

private struct ZwzV2OpenedArchive {
    let reader: ZwzV2VolumeReader
    let header: ZwzV2Header
    let index: ZwzV2Index
    let context: ZwzV2CryptoContext?
}

private struct ZwzV2DecodedArchiveBlock: Sendable {
    let fileOffset: UInt64
    let data: Data
}

private final class ZwzV2FileWriter {
    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ data: Data, at offset: UInt64) throws {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
    }

    func close() throws {
        try handle.close()
    }
}
