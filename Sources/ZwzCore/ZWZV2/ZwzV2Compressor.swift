import Foundation

public final class ZwzV2Compressor {
    private static let kdfIterations: UInt32 = 210_000

    private let options: ZwzV2Options

    public init(options: ZwzV2Options = ZwzV2Options()) {
        self.options = options
    }

    public func compress(
        sourceURLs: [URL],
        to outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil,
        cancellationToken: CancellationToken? = nil
    ) async throws -> [URL] {
        try cancellationToken?.checkCancellation()
        guard options.blockSize > 0, options.blockSize <= Int(UInt32.max) else {
            throw ZwzV2Error.malformedArchive("invalid compression block size")
        }

        let archiveID = UUID()
        let context = try makeCryptoContext(archiveID: archiveID)
        let sourceItems = try enumerateSources(sourceURLs)
        let totalBytes = sourceItems.reduce(UInt64(0)) { total, item in
            total + (item.type == .file ? item.size : 0)
        }
        var processedBytes: UInt64 = 0
        var entries = sourceItems.map {
            ZwzV2Entry(
                path: $0.archivePath,
                type: $0.type,
                originalSize: $0.size,
                modificationTime: normalizedModificationTime($0.modificationTime),
                isHidden: $0.isHidden,
                blocks: []
            )
        }
        try ZwzV2PathValidator.validateNoDuplicatePaths(entries)

        var entryPositions = [String: Int]()
        for (position, entry) in entries.enumerated() {
            entryPositions[entry.path] = position
        }

        let writer = try ZwzV2VolumeWriter(
            outputURL: outputURL,
            archiveID: archiveID,
            splitVolumeSize: options.splitVolumeSize
        )
        let header = ZwzV2Header(
            archiveID: archiveID,
            flags: headerFlags(encrypted: context != nil),
            blockSize: UInt32(options.blockSize),
            kdfSalt: context?.salt ?? Data(),
            kdfIterations: context?.iterations ?? 0
        )
        _ = try writer.write(try ZwzV2BinaryCodec.encodeHeader(header))

        var nextSequence: UInt64 = 0
        var nextSequenceToWrite: UInt64 = 0
        var completedBlocks = ZwzV2OrderedBlockWindow<ZwzV2EncodedArchiveBlock>()

        try await withThrowingTaskGroup(of: ZwzV2EncodedArchiveBlock.self) { group in
            var inFlight = 0

            func recordCompleted(_ block: ZwzV2EncodedArchiveBlock) throws {
                for nextBlock in completedBlocks.insert(block, sequence: block.sequence, nextSequenceToWrite: nextSequenceToWrite) {
                    try write(
                        nextBlock,
                        to: writer,
                        entries: &entries,
                        entryPositions: entryPositions
                    )
                    processedBytes += UInt64(nextBlock.originalLength)
                    if totalBytes > 0 {
                        progress?(min(0.99, Double(processedBytes) / Double(totalBytes)))
                    }
                    nextSequenceToWrite += 1
                }
            }

            func drainOne() async throws {
                guard let block = try await group.next() else {
                    throw ZwzV2Error.malformedArchive("compression task ended unexpectedly")
                }
                inFlight -= 1
                try recordCompleted(block)
            }

            func applyBackpressureIfNeeded() async throws {
                while completedBlocks.shouldApplyBackpressure(
                    inFlightCount: inFlight,
                    maxInFlightBlocks: options.maxInFlightBlocks
                ) {
                    try await drainOne()
                }
            }

            for sourceItem in sourceItems where sourceItem.type == .file {
                try cancellationToken?.checkCancellation()
                let handle = try FileHandle(forReadingFrom: sourceItem.url)
                defer { try? handle.close() }

                var fileOffset: UInt64 = 0
                while let chunk = try handle.read(upToCount: options.blockSize), !chunk.isEmpty {
                    try cancellationToken?.checkCancellation()
                    try await applyBackpressureIfNeeded()

                    let sequence = nextSequence
                    nextSequence += 1
                    let entryPath = sourceItem.archivePath
                    let blockFileOffset = fileOffset
                    let compressionLevel = options.compressionLevel

                    group.addTask {
                        let encoded = try ZwzV2BlockCodec.encode(chunk, level: compressionLevel)
                        let sealed: (payload: Data, tag: Data)
                        if let context {
                            let encrypted = try ZwzV2Crypto.sealBlock(encoded.payload, sequence: sequence, context: context)
                            sealed = (encrypted.ciphertext, encrypted.tag)
                        } else {
                            sealed = (encoded.payload, Data())
                        }
                        return ZwzV2EncodedArchiveBlock(
                            sequence: sequence,
                            entryPath: entryPath,
                            fileOffset: blockFileOffset,
                            originalLength: UInt32(encoded.originalLength),
                            codec: encoded.codec,
                            checksum: encoded.checksum,
                            payload: sealed.payload,
                            tag: sealed.tag
                        )
                    }
                    inFlight += 1
                    fileOffset += UInt64(chunk.count)

                    if inFlight == options.maxInFlightBlocks {
                        try await drainOne()
                        try await applyBackpressureIfNeeded()
                    }
                }
            }

            while inFlight > 0 {
                try cancellationToken?.checkCancellation()
                try await drainOne()
            }
        }

        guard completedBlocks.isEmpty, nextSequenceToWrite == nextSequence else {
            throw ZwzV2Error.malformedArchive("incomplete compressed block stream")
        }

        try cancellationToken?.checkCancellation()
        let index = ZwzV2Index(archiveID: archiveID, blockSize: options.blockSize, entries: entries)
        let encodedIndex = try ZwzV2IndexCodec.encodeForArchive(index, context: context)
        let indexOffset = try writer.write(encodedIndex.payload)
        _ = try writer.write(encodedIndex.tag)
        let footer = ZwzV2Footer(
            archiveID: archiveID,
            indexOffset: indexOffset,
            indexLength: UInt64(encodedIndex.payload.count),
            indexChecksum: checksum(of: encodedIndex.payload)
        )
        _ = try writer.write(try ZwzV2BinaryCodec.encodeFooter(footer))
        let urls = try writer.finalize()
        progress?(1.0)
        return urls
    }

    private func enumerateSources(_ sourceURLs: [URL]) throws -> [ZwzV2SourceItem] {
        let enumerator = ZwzV2SourceEnumerator()
        return try sourceURLs
            .sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
            .flatMap { try enumerator.enumerate(root: $0) }
            .sorted { $0.archivePath < $1.archivePath }
    }

    private func makeCryptoContext(archiveID: UUID) throws -> ZwzV2CryptoContext? {
        guard let password = options.password else {
            return nil
        }
        let salt = ZwzV2Crypto.makeSalt()
        return try ZwzV2Crypto.deriveContext(
            password: password,
            salt: salt,
            iterations: Self.kdfIterations,
            archiveID: archiveID
        )
    }

    private func headerFlags(encrypted: Bool) -> ZwzV2HeaderFlags {
        var flags: ZwzV2HeaderFlags = []
        if encrypted {
            flags.insert(.encrypted)
        }
        if options.splitVolumeSize != nil {
            flags.insert(.split)
        }
        return flags
    }

    private func write(
        _ block: ZwzV2EncodedArchiveBlock,
        to writer: ZwzV2VolumeWriter,
        entries: inout [ZwzV2Entry],
        entryPositions: [String: Int]
    ) throws {
        guard block.payload.count <= Int(UInt32.max), block.tag.count <= Int(UInt8.max) else {
            throw ZwzV2Error.malformedArchive("compressed block is too large")
        }
        guard let entryPosition = entryPositions[block.entryPath] else {
            throw ZwzV2Error.malformedArchive("missing block entry")
        }

        let recordHeader = ZwzV2BlockRecordHeader(
            sequence: block.sequence,
            codec: block.codec,
            storedLength: UInt32(block.payload.count),
            originalLength: block.originalLength,
            checksum: block.checksum,
            tagLength: UInt8(block.tag.count)
        )
        let archiveOffset = try writer.write(try ZwzV2BinaryCodec.encodeBlockRecordHeader(recordHeader))
        _ = try writer.write(block.payload)
        _ = try writer.write(block.tag)
        entries[entryPosition].blocks.append(
            ZwzV2BlockDescriptor(
                sequence: block.sequence,
                fileOffset: block.fileOffset,
                archiveOffset: archiveOffset,
                storedLength: UInt32(block.payload.count),
                originalLength: block.originalLength,
                codec: block.codec,
                checksum: block.checksum,
                authenticationTag: Array(block.tag)
            )
        )
    }

    private func checksum(of data: Data) -> UInt32 {
        var value: UInt32 = 2_166_136_261
        for byte in data {
            value ^= UInt32(byte)
            value &*= 16_777_619
        }
        return value
    }

    private func normalizedModificationTime(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.towardZero))
    }
}

struct ZwzV2OrderedBlockWindow<Element> {
    private var completed = [UInt64: Element]()

    var isEmpty: Bool {
        completed.isEmpty
    }

    mutating func insert(
        _ element: Element,
        sequence: UInt64,
        nextSequenceToWrite: UInt64
    ) -> [Element] {
        completed[sequence] = element

        var sequenceToWrite = nextSequenceToWrite
        var ready = [Element]()
        while let element = completed.removeValue(forKey: sequenceToWrite) {
            ready.append(element)
            sequenceToWrite += 1
        }
        return ready
    }

    func shouldApplyBackpressure(inFlightCount: Int, maxInFlightBlocks: Int) -> Bool {
        let bufferedLimit = max(1, maxInFlightBlocks - 1)
        return inFlightCount > 0 && completed.count >= bufferedLimit
    }
}

private struct ZwzV2EncodedArchiveBlock: Sendable {
    var sequence: UInt64
    var entryPath: String
    var fileOffset: UInt64
    var originalLength: UInt32
    var codec: ZwzV2Codec
    var checksum: UInt32
    var payload: Data
    var tag: Data
}
