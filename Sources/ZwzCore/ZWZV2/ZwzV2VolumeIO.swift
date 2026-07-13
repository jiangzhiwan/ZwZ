import Foundation

public struct ZwzV2VolumeSet: Equatable, Sendable {
    public let urls: [URL]

    public init(urls: [URL]) {
        self.urls = urls
    }
}

public final class ZwzV2VolumeWriter {
    private struct ActiveVolume {
        var url: URL
        var number: UInt32
        var handle: FileHandle
        var logicalOffset: UInt64
        var payloadLength: UInt64
        var checksum: UInt32
    }

    private let outputURL: URL
    private let archiveID: UUID
    private let splitVolumeSize: UInt64?
    private var singleFileHandle: FileHandle?
    private var activeVolume: ActiveVolume?
    private var completedURLs: [URL] = []
    private var logicalLength: UInt64 = 0
    private var isFinalized = false

    public init(outputURL: URL, archiveID: UUID, splitVolumeSize: UInt64? = nil) throws {
        guard splitVolumeSize != 0 else {
            throw ZwzV2Error.malformedArchive("split volume size must be greater than zero")
        }

        self.outputURL = outputURL
        self.archiveID = archiveID
        self.splitVolumeSize = splitVolumeSize

        if splitVolumeSize == nil {
            self.singleFileHandle = try Self.createFile(at: outputURL)
        }
    }

    deinit {
        try? singleFileHandle?.close()
        try? activeVolume?.handle.close()
    }

    public func write(_ data: Data) throws -> UInt64 {
        guard !isFinalized else {
            throw ZwzV2Error.malformedArchive("cannot write after finalizing volumes")
        }
        guard !logicalLength.addingReportingOverflow(UInt64(data.count)).overflow else {
            throw ZwzV2Error.malformedArchive("overflowing logical archive length")
        }

        let offset = logicalLength
        guard let splitVolumeSize else {
            try singleFileHandle?.write(contentsOf: data)
            logicalLength += UInt64(data.count)
            return offset
        }

        var dataOffset = 0
        while dataOffset < data.count {
            if activeVolume == nil {
                try beginVolume()
            }
            guard var volume = activeVolume else {
                throw ZwzV2Error.malformedArchive("could not open split volume")
            }

            let remainingPayload = splitVolumeSize - volume.payloadLength
            let remainingData = UInt64(data.count - dataOffset)
            let count = Int(min(remainingPayload, remainingData))
            let payload = data.subdata(in: dataOffset..<(dataOffset + count))
            try volume.handle.write(contentsOf: payload)
            volume.payloadLength += UInt64(count)
            volume.checksum = ZwzV2VolumeChecksum.updating(volume.checksum, with: payload)
            activeVolume = volume
            dataOffset += count
            logicalLength += UInt64(count)

            if volume.payloadLength == splitVolumeSize {
                try completeActiveVolume(isFinal: false)
            }
        }

        return offset
    }

    public func finalize() throws -> [URL] {
        guard !isFinalized else {
            throw ZwzV2Error.malformedArchive("volumes already finalized")
        }
        isFinalized = true

        guard splitVolumeSize != nil else {
            try singleFileHandle?.close()
            singleFileHandle = nil
            return [outputURL]
        }

        if activeVolume == nil {
            try beginVolume()
        }
        try completeActiveVolume(isFinal: true)
        return completedURLs
    }

    private func beginVolume() throws {
        let number = UInt32(completedURLs.count)
        let url = numberedVolumeURL(number: number)
        let handle = try Self.createFile(at: url)
        let volume = ActiveVolume(
            url: url,
            number: number,
            handle: handle,
            logicalOffset: logicalLength,
            payloadLength: 0,
            checksum: ZwzV2VolumeChecksum.initialValue
        )
        try writeEnvelope(for: volume, isFinal: false)
        try handle.seek(toOffset: UInt64(ZwzV2SplitEnvelope.encodedLength))
        activeVolume = volume
    }

    private func completeActiveVolume(isFinal: Bool) throws {
        guard let volume = activeVolume else {
            throw ZwzV2Error.malformedArchive("missing active split volume")
        }
        try writeEnvelope(for: volume, isFinal: isFinal)
        try volume.handle.close()
        activeVolume = nil

        if isFinal {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.moveItem(at: volume.url, to: outputURL)
            completedURLs.append(outputURL)
        } else {
            completedURLs.append(volume.url)
        }
    }

    private func writeEnvelope(for volume: ActiveVolume, isFinal: Bool) throws {
        let envelope = ZwzV2SplitEnvelope(
            archiveID: archiveID,
            volumeNumber: volume.number,
            isFinal: isFinal,
            logicalOffset: volume.logicalOffset,
            payloadLength: volume.payloadLength,
            payloadChecksum: volume.checksum
        )
        try volume.handle.seek(toOffset: 0)
        try volume.handle.write(contentsOf: ZwzV2BinaryCodec.encodeSplitEnvelope(envelope))
    }

    private func numberedVolumeURL(number: UInt32) -> URL {
        outputURL.deletingPathExtension().appendingPathExtension(String(format: "z%02u", number))
    }

    private static func createFile(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ZwzV2Error.malformedArchive("could not create volume file")
        }
        return try FileHandle(forWritingTo: url)
    }
}

public final class ZwzV2VolumeReader {
    private struct Volume {
        let url: URL
        let payloadFileOffset: UInt64
        let logicalOffset: UInt64
        let payloadLength: UInt64
    }

    private let volumes: [Volume]
    private let logicalLength: UInt64

    public convenience init(volumeSet: ZwzV2VolumeSet) throws {
        try self.init(urls: volumeSet.urls)
    }

    public init(urls: [URL]) throws {
        guard let firstURL = urls.first else {
            throw ZwzV2Error.malformedArchive("no archive volumes supplied")
        }

        let firstFileLength = try Self.fileSize(of: firstURL)
        let prefix = firstFileLength >= 4
            ? try Self.readExactly(from: firstURL, offset: 0, length: 4)
            : Data()
        if Array(prefix) == ZwzV2Format.splitMagic {
            let splitVolumes = try Self.validateSplitVolumes(urls)
            volumes = splitVolumes
            logicalLength = splitVolumes.last.map { $0.logicalOffset + $0.payloadLength } ?? 0
        } else {
            guard urls.count == 1 else {
                throw ZwzV2Error.malformedArchive("single archive cannot have multiple volume URLs")
            }
            volumes = [Volume(url: firstURL, payloadFileOffset: 0, logicalOffset: 0, payloadLength: firstFileLength)]
            logicalLength = firstFileLength
        }
    }

    public func read(offset: UInt64, length: Int) throws -> Data {
        guard length >= 0 else {
            throw ZwzV2Error.malformedArchive("negative logical read length")
        }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(length))
        guard !overflow, end <= logicalLength else {
            throw ZwzV2Error.malformedArchive("logical read exceeds archive length")
        }

        var result = Data()
        result.reserveCapacity(length)
        for volume in volumes {
            let volumeEnd = volume.logicalOffset + volume.payloadLength
            let start = max(offset, volume.logicalOffset)
            let stop = min(end, volumeEnd)
            guard start < stop else { continue }

            let payloadOffset = start - volume.logicalOffset
            let fileOffset = volume.payloadFileOffset + payloadOffset
            result.append(try Self.readExactly(from: volume.url, offset: fileOffset, length: Int(stop - start)))
        }
        return result
    }

    private static func validateSplitVolumes(_ urls: [URL]) throws -> [Volume] {
        var envelopes: [(URL, ZwzV2SplitEnvelope)] = []
        for url in urls {
            let header = try readExactly(from: url, offset: 0, length: ZwzV2SplitEnvelope.encodedLength)
            envelopes.append((url, try ZwzV2BinaryCodec.decodeSplitEnvelope(header)))
        }
        guard let first = envelopes.first else {
            throw ZwzV2Error.malformedArchive("no split volumes supplied")
        }
        let archiveID = first.1.archiveID
        var seenNumbers = Set<UInt32>()
        for (_, envelope) in envelopes {
            guard envelope.archiveID == archiveID else {
                throw ZwzV2Error.malformedArchive("split volume archive IDs do not match")
            }
            guard seenNumbers.insert(envelope.volumeNumber).inserted else {
                throw ZwzV2Error.malformedArchive("duplicate split volume number")
            }
        }

        var requiredNumber: UInt32 = 0
        for volumeNumber in seenNumbers.sorted() {
            guard volumeNumber == requiredNumber else {
                throw ZwzV2Error.missingVolume(Int(requiredNumber))
            }
            if requiredNumber == UInt32.max {
                break
            }
            requiredNumber += 1
        }

        var expectedNumber: UInt32 = 0
        var expectedOffset: UInt64 = 0
        var result: [Volume] = []

        for (index, pair) in envelopes.enumerated() {
            let (url, envelope) = pair
            guard envelope.volumeNumber == expectedNumber else {
                throw ZwzV2Error.malformedArchive("reordered split volume URLs")
            }
            guard envelope.logicalOffset == expectedOffset else {
                throw ZwzV2Error.malformedArchive("non-contiguous split logical ranges")
            }
            guard envelope.isFinal == (index == envelopes.count - 1) else {
                throw ZwzV2Error.malformedArchive("inconsistent final-volume marker")
            }
            guard try fileSize(of: url) == UInt64(ZwzV2SplitEnvelope.encodedLength) + envelope.payloadLength else {
                throw ZwzV2Error.malformedArchive("split payload length does not match file size")
            }
            guard try checksum(of: url, payloadLength: envelope.payloadLength) == envelope.payloadChecksum else {
                throw ZwzV2Error.malformedArchive("split payload checksum mismatch")
            }

            result.append(
                Volume(
                    url: url,
                    payloadFileOffset: UInt64(ZwzV2SplitEnvelope.encodedLength),
                    logicalOffset: envelope.logicalOffset,
                    payloadLength: envelope.payloadLength
                )
            )
            let (nextOffset, offsetOverflow) = expectedOffset.addingReportingOverflow(envelope.payloadLength)
            guard !offsetOverflow else {
                throw ZwzV2Error.malformedArchive("overflowing split logical range")
            }
            expectedOffset = nextOffset
            guard expectedNumber < UInt32.max else {
                throw ZwzV2Error.malformedArchive("too many split volumes")
            }
            expectedNumber += 1
        }
        return result
    }

    private static func checksum(of url: URL, payloadLength: UInt64) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(ZwzV2SplitEnvelope.encodedLength))

        var remaining = payloadLength
        var checksum = ZwzV2VolumeChecksum.initialValue
        while remaining > 0 {
            let chunkLength = Int(min(remaining, 64 * 1024))
            guard let chunk = try handle.read(upToCount: chunkLength), chunk.count == chunkLength else {
                throw ZwzV2Error.malformedArchive("truncated split payload")
            }
            checksum = ZwzV2VolumeChecksum.updating(checksum, with: chunk)
            remaining -= UInt64(chunkLength)
        }
        return checksum
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

    private static func fileSize(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw ZwzV2Error.malformedArchive("could not determine archive volume size")
        }
        return size.uint64Value
    }
}

extension ZwzV2VolumeReader: @unchecked Sendable {}

private enum ZwzV2VolumeChecksum {
    static let initialValue: UInt32 = 2_166_136_261

    static func updating(_ checksum: UInt32, with data: Data) -> UInt32 {
        var value = checksum
        for byte in data {
            value ^= UInt32(byte)
            value &*= 16_777_619
        }
        return value
    }
}
