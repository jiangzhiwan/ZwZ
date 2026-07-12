import CryptoKit
import Foundation

public final class ZwzV3Extractor {
    static let defaultLogicalArchiveSizeLimit: UInt64 = 512 * 1_024 * 1_024
    private static let defaultReadChunkSize = 1 * 1_024 * 1_024

    public init() {}

    public func listEntries(
        archivePath: String,
        keyProvider: ZwzPrivateKeyProvider
    ) throws -> ZwzV3ArchiveListing {
        let opened = try openArchive(
            archivePath: archivePath,
            keyProvider: keyProvider,
            cancellationToken: nil
        )
        return ZwzV3ArchiveListing(entries: opened.index.entries, securityInfo: opened.securityInfo)
    }

    public func extractAll(
        archivePath: String,
        destinationPath: String,
        keyProvider: ZwzPrivateKeyProvider,
        progress: ProgressHandler?,
        cancellationToken: CancellationToken?
    ) throws -> ZwzArchiveSecurityInfo {
        try cancellationToken?.checkCancellation()
        let opened = try openArchive(
            archivePath: archivePath,
            keyProvider: keyProvider,
            cancellationToken: cancellationToken
        )
        try extract(
            entries: opened.index.entries,
            opened: opened,
            destination: URL(fileURLWithPath: destinationPath),
            progress: progress,
            cancellationToken: cancellationToken
        )
        return opened.securityInfo
    }

    public func extractEntryToTemp(
        archivePath: String,
        entryPath: String,
        keyProvider: ZwzPrivateKeyProvider,
        progress: ProgressHandler? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws -> URL {
        try cancellationToken?.checkCancellation()
        let opened = try openArchive(
            archivePath: archivePath,
            keyProvider: keyProvider,
            cancellationToken: cancellationToken
        )
        guard let root = opened.index.entries.first(where: { $0.path == entryPath }) else {
            throw ZwzV3Error.malformedArchive("requested entry not found")
        }
        let entries = root.type == .directory
            ? opened.index.entries.filter { $0.path == entryPath || $0.path.hasPrefix(entryPath + "/") }
            : [root]
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("zwz-v3-entry-\(UUID().uuidString)", isDirectory: true)
        do {
            try extract(
                entries: entries,
                opened: opened,
                destination: destination,
                progress: progress,
                cancellationToken: cancellationToken
            )
            return destination.appendingPathComponent(entryPath)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func loadLogicalArchive(
        from urls: [URL],
        sizeLimit: UInt64 = defaultLogicalArchiveSizeLimit,
        cancellationToken: CancellationToken? = nil,
        chunkSize: Int = defaultReadChunkSize,
        onChunkRead: ((Int) -> Void)? = nil
    ) throws -> Data {
        guard let first = urls.first else {
            throw ZwzV3Error.malformedArchive("no archive volumes")
        }
        guard chunkSize > 0 else {
            throw ZwzV3Error.malformedArchive("invalid archive read chunk size")
        }
        try cancellationToken?.checkCancellation()
        let prefix = try readExactly(first, count: 4)
        if Array(prefix) == ZwzV2Format.splitMagic {
            var volumes: [(url: URL, envelope: ZwzV2SplitEnvelope)] = []
            var logicalLength: UInt64 = 0
            var archiveID: UUID?
            var seenNumbers = Set<UInt32>()
            for url in urls {
                try cancellationToken?.checkCancellation()
                let envelope = try ZwzV2BinaryCodec.decodeSplitEnvelope(
                    try readExactly(url, count: ZwzV2SplitEnvelope.encodedLength)
                )
                if let archiveID {
                    guard envelope.archiveID == archiveID else {
                        throw ZwzV3Error.malformedArchive("split volume archive IDs do not match")
                    }
                } else {
                    archiveID = envelope.archiveID
                }
                guard seenNumbers.insert(envelope.volumeNumber).inserted else {
                    throw ZwzV3Error.malformedArchive("duplicate split volume number")
                }
                let end = envelope.logicalOffset.addingReportingOverflow(envelope.payloadLength)
                guard !end.overflow else {
                    throw ZwzV3Error.malformedArchive("overflowing split archive length")
                }
                let expectedFileSize = UInt64(ZwzV2SplitEnvelope.encodedLength)
                    .addingReportingOverflow(envelope.payloadLength)
                guard !expectedFileSize.overflow,
                      try fileSize(of: url) == expectedFileSize.partialValue else {
                    throw ZwzV3Error.malformedArchive("split payload length does not match file size")
                }
                try requireWithinSizeLimit(end.partialValue, limit: sizeLimit)
                volumes.append((url, envelope))
            }
            for (index, number) in seenNumbers.sorted().enumerated() {
                guard let expectedNumber = UInt32(exactly: index) else {
                    throw ZwzV3Error.malformedArchive("too many split volumes")
                }
                guard number == expectedNumber else { throw ZwzV2Error.missingVolume(index) }
            }
            for (index, volume) in volumes.enumerated() {
                guard let expectedNumber = UInt32(exactly: index) else {
                    throw ZwzV3Error.malformedArchive("too many split volumes")
                }
                guard volume.envelope.volumeNumber == expectedNumber else {
                    throw ZwzV3Error.malformedArchive("reordered split volume URLs")
                }
                guard volume.envelope.logicalOffset == logicalLength else {
                    throw ZwzV3Error.malformedArchive("non-contiguous split logical ranges")
                }
                guard volume.envelope.isFinal == (index == volumes.count - 1) else {
                    throw ZwzV3Error.malformedArchive("inconsistent final-volume marker")
                }
                let end = logicalLength.addingReportingOverflow(volume.envelope.payloadLength)
                guard !end.overflow else {
                    throw ZwzV3Error.malformedArchive("overflowing split archive length")
                }
                logicalLength = end.partialValue
            }
            try requireWithinSizeLimit(logicalLength, limit: sizeLimit)
            guard let length = Int(exactly: logicalLength) else {
                throw ZwzV3Error.malformedArchive("archive is too large")
            }
            try cancellationToken?.checkCancellation()
            var archive = Data()
            archive.reserveCapacity(length)
            for volume in volumes {
                let handle = try FileHandle(forReadingFrom: volume.url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(ZwzV2SplitEnvelope.encodedLength))
                var remaining = volume.envelope.payloadLength
                var checksum: UInt32 = 2_166_136_261
                while remaining > 0 {
                    try cancellationToken?.checkCancellation()
                    let readLength = Int(min(UInt64(chunkSize), remaining))
                    guard let chunk = try handle.read(upToCount: readLength),
                          chunk.count == readLength else {
                        throw ZwzV3Error.malformedArchive("truncated split payload")
                    }
                    for byte in chunk {
                        checksum ^= UInt32(byte)
                        checksum &*= 16_777_619
                    }
                    archive.append(chunk)
                    onChunkRead?(readLength)
                    remaining -= UInt64(readLength)
                }
                guard checksum == volume.envelope.payloadChecksum else {
                    throw ZwzV3Error.malformedArchive("split payload checksum mismatch")
                }
            }
            try cancellationToken?.checkCancellation()
            return archive
        }
        guard Array(prefix) == [0x5A, 0x57, 0x5A, 0x33], urls.count == 1 else {
            throw ZwzV3Error.malformedArchive("invalid version 3 archive magic")
        }
        try requireWithinSizeLimit(try fileSize(of: first), limit: sizeLimit)
        try cancellationToken?.checkCancellation()
        let archive = try Data(contentsOf: first, options: [.mappedIfSafe])
        onChunkRead?(archive.count)
        try cancellationToken?.checkCancellation()
        return archive
    }

    private func openArchive(
        archivePath: String,
        keyProvider: ZwzPrivateKeyProvider,
        cancellationToken: CancellationToken?
    ) throws -> ZwzV3OpenedArchive {
        try cancellationToken?.checkCancellation()
        let urls = try Self.archiveURLs(for: archivePath)
        let archive = try Self.loadLogicalArchive(
            from: urls,
            cancellationToken: cancellationToken
        )
        try cancellationToken?.checkCancellation()
        let parsed: ZwzV3ParsedArchive
        do {
            parsed = try ZwzV3BinaryCodec.parse(archive)
        } catch {
            if archive.count >= ZwzV3Header.encodedLength,
               let header = try? ZwzV3BinaryCodec.decodeHeader(
                   archive.subdata(in: 0..<ZwzV3Header.encodedLength)
               ),
               header.signatureAlgorithm == .ed25519 {
                throw ZwzV3Error.invalidSignature
            }
            throw error
        }

        let signature: ZwzSignatureVerification
        if let signer = parsed.signer {
            guard ZwzV3Crypto.verify(
                signer.signature,
                bytes: parsed.canonicalSignedBytes,
                publicKey: signer.signingPublicKey
            ) else {
                throw ZwzV3Error.invalidSignature
            }
            signature = keyProvider.isKnownSigningKey(
                fingerprint: signer.fingerprint,
                signingPublicKey: signer.signingPublicKey
            )
                ? .validKnownSigner(name: signer.name, fingerprint: signer.fingerprint)
                : .validUnknownSigner(name: signer.name, fingerprint: signer.fingerprint)
        } else {
            signature = .unsigned
        }

        let contentKey = try unwrapContentKey(parsed: parsed, keyProvider: keyProvider)
        let recipientRegion = try parsed.recipients.reduce(into: Data()) {
            $0.append(try ZwzV3BinaryCodec.encodeRecipient($1))
        }
        let plainIndex = try ZwzV3Crypto.open(
            parsed.encryptedIndex,
            key: contentKey,
            aad: ZwzV3PayloadCodec.indexAAD(
                archiveID: parsed.header.archiveID,
                recipientCount: parsed.header.recipientCount,
                recipientRegion: recipientRegion,
                dataBlockCount: parsed.header.dataBlockCount,
                dataRegion: parsed.dataRegion,
                signatureAlgorithm: parsed.header.signatureAlgorithm
            )
        )
        let index: ZwzV2Index
        do {
            index = try ZwzV2IndexCodec.decodePlain(plainIndex)
        } catch let error as ZwzV2Error {
            throw mapMalformed(error)
        }
        let records = try ZwzV3PayloadCodec.parseRecords(
            parsed.dataRegion,
            absoluteOffset: parsed.header.dataRegionOffset,
            expectedCount: parsed.header.dataBlockCount
        )
        do {
            try ZwzV3PayloadCodec.validate(index: index, parsed: parsed, records: records)
        } catch let error as ZwzV2Error {
            throw mapMalformed(error)
        }
        return ZwzV3OpenedArchive(
            parsed: parsed,
            index: index,
            records: records,
            contentKey: contentKey,
            securityInfo: ZwzArchiveSecurityInfo(
                encryption: .publicKey,
                recipientFingerprints: parsed.recipients.map(\.recipientFingerprint),
                signature: signature
            )
        )
    }

    private func unwrapContentKey(
        parsed: ZwzV3ParsedArchive,
        keyProvider: ZwzPrivateKeyProvider
    ) throws -> SymmetricKey {
        var obtainedMatchingKey = false
        for envelope in parsed.recipients {
            let rawPrivate: Data
            do {
                rawPrivate = try keyProvider.agreementPrivateKey(
                    fingerprint: envelope.recipientFingerprint,
                    reason: "Open ZWZ archive"
                )
            } catch ZwzV3Error.userAuthenticationCancelled {
                throw ZwzV3Error.userAuthenticationCancelled
            } catch ZwzV3Error.noMatchingPrivateKey {
                continue
            } catch {
                throw error
            }
            obtainedMatchingKey = true
            do {
                let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivate)
                return try ZwzV3Crypto.unwrap(
                    envelope,
                    privateKey: privateKey,
                    archiveID: parsed.header.archiveID
                )
            } catch {
                continue
            }
        }
        if obtainedMatchingKey { throw ZwzV3Error.keyUnwrapFailed }
        throw ZwzV3Error.noMatchingPrivateKey(parsed.recipients.map(\.recipientFingerprint))
    }

    private func extract(
        entries: [ZwzV2Entry],
        opened: ZwzV3OpenedArchive,
        destination: URL,
        progress: ProgressHandler?,
        cancellationToken: CancellationToken?
    ) throws {
        try cancellationToken?.checkCancellation()
        progress?(0)
        let fileManager = FileManager.default
        if (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            throw ZwzV2Error.unsafePath(destination.path)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var totalBytes: UInt64 = 0
        for entry in entries where entry.type == .file {
            totalBytes = try checkedAdd(
                totalBytes,
                entry.originalSize,
                reason: "extraction progress size overflow"
            )
        }
        var completedBytes: UInt64 = 0

        for entry in entries where entry.type == .directory {
            try cancellationToken?.checkCancellation()
            let output = try outputURL(for: entry.path, destination: destination)
            try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.modificationDate: entry.modificationTime], ofItemAtPath: output.path)
        }
        for entry in entries where entry.type == .file {
            try cancellationToken?.checkCancellation()
            let output = try outputURL(for: entry.path, destination: destination)
            do {
                try fileManager.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: output.path) {
                    let values = try output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory != true, values.isSymbolicLink != true else {
                        throw ZwzV2Error.unsafePath(entry.path)
                    }
                    try fileManager.removeItem(at: output)
                }
                guard fileManager.createFile(atPath: output.path, contents: nil) else {
                    throw ZwzV3Error.malformedArchive("could not create extraction file")
                }
                let handle = try FileHandle(forWritingTo: output)
                defer { try? handle.close() }
                for descriptor in entry.blocks {
                    try cancellationToken?.checkCancellation()
                    let record = opened.records[Int(descriptor.sequence)]
                    let encoded = try ZwzV3Crypto.open(
                        record.sealed,
                        key: opened.contentKey,
                        aad: ZwzV3PayloadCodec.blockAAD(
                            archiveID: opened.parsed.header.archiveID,
                            sequence: record.sequence,
                            codec: record.codec,
                            originalLength: record.originalLength
                        )
                    )
                    let decoded = try ZwzV2BlockCodec.decode(
                        codec: record.codec,
                        payload: encoded,
                        originalLength: Int(record.originalLength),
                        sequence: record.sequence
                    )
                    guard checksum(decoded) == descriptor.checksum else {
                        throw ZwzV2Error.checksumMismatch(sequence: record.sequence)
                    }
                    try handle.seek(toOffset: descriptor.fileOffset)
                    try handle.write(contentsOf: decoded)
                    completedBytes = try checkedAdd(
                        completedBytes,
                        UInt64(decoded.count),
                        reason: "extraction progress size overflow"
                    )
                    if totalBytes > 0 {
                        progress?(min(1, Double(completedBytes) / Double(totalBytes)))
                    }
                    try cancellationToken?.checkCancellation()
                }
                try? fileManager.setAttributes([.modificationDate: entry.modificationTime], ofItemAtPath: output.path)
            } catch {
                try? fileManager.removeItem(at: output)
                throw error
            }
        }
        try cancellationToken?.checkCancellation()
        progress?(1)
    }

    private func outputURL(for path: String, destination: URL) throws -> URL {
        let output = try ZwzV2PathValidator.validateExtractionPath(path, destination: destination)
        var current = destination.standardizedFileURL
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            current.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw ZwzV2Error.unsafePath(path)
            }
        }
        return output
    }

    private static func archiveURLs(for path: String) throws -> [URL] {
        let selected = URL(fileURLWithPath: path)
        let prefix = try readExactly(selected, count: 4)
        guard Array(prefix) == ZwzV2Format.splitMagic else { return [selected] }
        let directory = selected.deletingLastPathComponent()
        let base = splitBaseName(selected.lastPathComponent)
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let volumes = try candidates.compactMap { url -> (URL, UInt32)? in
            guard splitBaseName(url.lastPathComponent) == base,
                  let prefix = try? readExactly(url, count: 4),
                  Array(prefix) == ZwzV2Format.splitMagic else { return nil }
            let envelope = try ZwzV2BinaryCodec.decodeSplitEnvelope(
                readExactly(url, count: ZwzV2SplitEnvelope.encodedLength)
            )
            return (url, envelope.volumeNumber)
        }.sorted { $0.1 < $1.1 }.map(\.0)
        guard !volumes.isEmpty else { throw ZwzV2Error.missingVolume(0) }
        return volumes
    }

    private static func splitBaseName(_ name: String) -> String {
        let value = name as NSString
        let ext = value.pathExtension.lowercased()
        let numbered = ext.first == "z" && ext.dropFirst().allSatisfy(\.isNumber)
        return ext == "zwz" || numbered ? value.deletingPathExtension : name
    }

    private static func readExactly(_ url: URL, count: Int) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ZwzError.fileNotFound(url.path)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw ZwzV3Error.malformedArchive("truncated archive")
        }
        return data
    }

    private static func fileSize(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw ZwzV3Error.malformedArchive("could not determine archive size")
        }
        return size.uint64Value
    }

    private static func requireWithinSizeLimit(_ size: UInt64, limit: UInt64) throws {
        guard size <= limit else {
            throw ZwzV3Error.malformedArchive("logical archive exceeds size limit")
        }
    }

    private func mapMalformed(_ error: ZwzV2Error) -> Error {
        switch error {
        case .unsafePath, .duplicatePath:
            return error
        default:
            return ZwzV3Error.malformedArchive(error.localizedDescription)
        }
    }

    private func checksum(_ data: Data) -> UInt32 {
        var value: UInt32 = 2_166_136_261
        for byte in data {
            value ^= UInt32(byte)
            value &*= 16_777_619
        }
        return value
    }

    private func checkedAdd(_ lhs: UInt64, _ rhs: UInt64, reason: String) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw ZwzV3Error.malformedArchive(reason) }
        return result.partialValue
    }
}

private struct ZwzV3OpenedArchive {
    let parsed: ZwzV3ParsedArchive
    let index: ZwzV2Index
    let records: [ZwzV3DataRecord]
    let contentKey: SymmetricKey
    let securityInfo: ZwzArchiveSecurityInfo
}
