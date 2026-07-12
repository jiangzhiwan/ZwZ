import CryptoKit
import Foundation

public final class ZwzV3Compressor {
    private let blockSize: Int

    public init(blockSize: Int = ZwzV2Format.defaultBlockSize) {
        self.blockSize = blockSize
    }

    public func compress(
        sourcePath: String,
        destinationPath: String,
        options: CompressionOptions,
        keyProvider: ZwzPrivateKeyProvider?,
        progress: ProgressHandler?,
        cancellationToken: CancellationToken?
    ) throws {
        guard options.format == .zwz,
              blockSize > 0,
              blockSize <= Int(UInt32.max),
              case .publicKey(let recipients, let signingIdentity) = try options.encryption.validated() else {
            throw ZwzV3Error.recipientRequired
        }
        progress?(0)

        let destination = URL(fileURLWithPath: destinationPath)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stagingDirectory = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).partial-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        try cancellationToken?.checkCancellation()
        let archiveID = UUID()
        let contentKey = SymmetricKey(size: .bits256)
        let envelopes = try ZwzV3Crypto.wrap(
            contentKey: contentKey,
            recipients: recipients,
            archiveID: archiveID
        )
        let recipientRegion = try envelopes.reduce(into: Data()) {
            $0.append(try ZwzV3BinaryCodec.encodeRecipient($1))
        }
        let sourceItems = try ZwzV2SourceEnumerator().enumerate(root: URL(fileURLWithPath: sourcePath))
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
        let entryPositions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.path, $0) })
        let totalBytes = sourceItems.reduce(UInt64(0)) { $0 + ($1.type == .file ? $1.size : 0) }
        var processedBytes: UInt64 = 0
        var sequence: UInt64 = 0
        var dataRegion = Data()
        let dataRegionOffset = UInt64(ZwzV3Header.encodedLength + recipientRegion.count)

        for item in sourceItems where item.type == .file {
            try cancellationToken?.checkCancellation()
            let handle = try FileHandle(forReadingFrom: item.url)
            defer { try? handle.close() }
            var fileOffset: UInt64 = 0
            while let chunk = try handle.read(upToCount: blockSize), !chunk.isEmpty {
                try cancellationToken?.checkCancellation()
                let encoded = try ZwzV2BlockCodec.encode(chunk, level: options.level.v3CompressionLevel)
                guard let originalLength = UInt32(exactly: encoded.originalLength) else {
                    throw ZwzV3Error.malformedArchive("block is too large")
                }
                let sealed = try ZwzV3Crypto.seal(
                    encoded.payload,
                    key: contentKey,
                    nonce: AES.GCM.Nonce(),
                    aad: ZwzV3PayloadCodec.blockAAD(
                        archiveID: archiveID,
                        sequence: sequence,
                        codec: encoded.codec,
                        originalLength: originalLength
                    )
                )
                let archiveOffset = try checkedAdd(dataRegionOffset, UInt64(dataRegion.count))
                dataRegion.append(try ZwzV3PayloadCodec.encodeRecord(
                    sequence: sequence,
                    codec: encoded.codec,
                    originalLength: originalLength,
                    sealed: sealed
                ))
                guard let entryIndex = entryPositions[item.archivePath],
                      let storedLength = UInt32(exactly: sealed.count) else {
                    throw ZwzV3Error.malformedArchive("invalid block descriptor")
                }
                entries[entryIndex].blocks.append(ZwzV2BlockDescriptor(
                    sequence: sequence,
                    fileOffset: fileOffset,
                    archiveOffset: archiveOffset,
                    storedLength: storedLength,
                    originalLength: originalLength,
                    codec: encoded.codec,
                    checksum: encoded.checksum,
                    authenticationTag: []
                ))
                guard sequence < UInt64.max else {
                    throw ZwzV3Error.malformedArchive("too many data blocks")
                }
                sequence += 1
                fileOffset += UInt64(chunk.count)
                processedBytes += UInt64(chunk.count)
                if totalBytes > 0 {
                    progress?(min(0.9, Double(processedBytes) / Double(totalBytes) * 0.9))
                }
                try cancellationToken?.checkCancellation()
            }
        }

        let index = ZwzV2Index(archiveID: archiveID, blockSize: blockSize, entries: entries)
        let plainIndex = try ZwzV2IndexCodec.encodePlain(index)
        let encryptedIndex = try ZwzV3Crypto.seal(
            plainIndex,
            key: contentKey,
            nonce: AES.GCM.Nonce(),
            aad: ZwzV3PayloadCodec.indexAAD(
                archiveID: archiveID,
                recipientCount: UInt32(envelopes.count),
                recipientRegion: recipientRegion,
                dataBlockCount: sequence,
                dataRegion: dataRegion,
                signatureAlgorithm: signingIdentity == nil ? .none : .ed25519
            )
        )

        var archive = try assembleArchive(
            recipients: recipients,
            envelopes: envelopes,
            dataRegion: dataRegion,
            encryptedIndex: encryptedIndex,
            archiveID: archiveID,
            dataBlockCount: sequence,
            signingIdentity: signingIdentity,
            keyProvider: keyProvider
        )
        try ZwzV3PayloadCodec.verifyBuiltArchive(archive, contentKey: contentKey)
        try cancellationToken?.checkCancellation()

        let stagedDestination = stagingDirectory.appendingPathComponent(destination.lastPathComponent)
        let splitSize = options.splitVolume.flatMap { $0.bytes > 0 ? UInt64($0.bytes) : nil }
        let writer = try ZwzV2VolumeWriter(
            outputURL: stagedDestination,
            archiveID: archiveID,
            splitVolumeSize: splitSize
        )
        _ = try writer.write(archive)
        archive.removeAll(keepingCapacity: false)
        let stagedURLs = try writer.finalize()
        let stagedArchive = try ZwzV3Extractor.loadLogicalArchive(from: stagedURLs)
        try ZwzV3PayloadCodec.verifyBuiltArchive(stagedArchive, contentKey: contentKey)
        try cancellationToken?.checkCancellation()
        try publish(stagedURLs: stagedURLs, destination: destination, stagingDirectory: stagingDirectory)
        progress?(1)
    }

    private func assembleArchive(
        recipients _: [ZwzRecipient],
        envelopes: [ZwzV3RecipientEnvelope],
        dataRegion: Data,
        encryptedIndex: Data,
        archiveID: UUID,
        dataBlockCount: UInt64,
        signingIdentity: ZwzSigningIdentity?,
        keyProvider: ZwzPrivateKeyProvider?
    ) throws -> Data {
        guard let signingIdentity else {
            return try ZwzV3ArchiveCodec.encode(
                recipients: envelopes,
                dataRegion: dataRegion,
                encryptedIndex: encryptedIndex,
                signer: nil,
                archiveID: archiveID,
                dataBlockCount: dataBlockCount
            )
        }
        guard let keyProvider else { throw ZwzV3Error.keyUnwrapFailed }
        let rawPrivate: Data
        do {
            rawPrivate = try keyProvider.signingPrivateKey(
                fingerprint: signingIdentity.fingerprint,
                reason: "Sign ZWZ archive"
            )
        } catch ZwzV3Error.userAuthenticationCancelled {
            throw ZwzV3Error.userAuthenticationCancelled
        } catch {
            throw ZwzV3Error.keyUnwrapFailed
        }
        let privateKey: Curve25519.Signing.PrivateKey
        do {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivate)
        } catch {
            throw ZwzV3Error.keyUnwrapFailed
        }
        guard signingIdentity.agreementPublicKey.count == 32,
              signingIdentity.signingPublicKey.count == 32,
              privateKey.publicKey.rawRepresentation == signingIdentity.signingPublicKey,
              ZwzV3Crypto.fingerprint(
                agreement: signingIdentity.agreementPublicKey,
                signing: signingIdentity.signingPublicKey
              ) == signingIdentity.fingerprint else {
            throw ZwzV3Error.keyUnwrapFailed
        }
        let placeholder = ZwzV3SignerRecord(
            name: signingIdentity.name,
            fingerprint: signingIdentity.fingerprint,
            signingPublicKey: privateKey.publicKey.rawRepresentation,
            signature: Data(repeating: 0, count: 64)
        )
        var archive = try ZwzV3ArchiveCodec.encode(
            recipients: envelopes,
            dataRegion: dataRegion,
            encryptedIndex: encryptedIndex,
            signer: placeholder,
            archiveID: archiveID,
            dataBlockCount: dataBlockCount
        )
        let parsed = try ZwzV3BinaryCodec.parse(archive)
        let signature = try ZwzV3Crypto.sign(parsed.canonicalSignedBytes, privateKey: privateKey)
        guard signature.count == 64, let offset = Int(exactly: parsed.header.signatureOffset) else {
            throw ZwzV3Error.invalidSignature
        }
        archive.replaceSubrange(offset..<(offset + 64), with: signature)
        return archive
    }

    private func publish(stagedURLs: [URL], destination: URL, stagingDirectory: URL) throws {
        let fileManager = FileManager.default
        let stagedMappings = stagedURLs.map { staged -> (URL, URL) in
            if staged.pathExtension.lowercased() == "zwz" {
                return (staged, destination)
            }
            return (staged, destination.deletingPathExtension().appendingPathExtension(staged.pathExtension))
        }
        let backupDirectory = stagingDirectory.appendingPathComponent("backups", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        if stagedMappings.count == 1 {
            let staged = stagedMappings[0].0
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
            try removeStaleVolumes(for: destination)
            return
        }
        var backups: [(URL, URL)] = []
        var published: [URL] = []
        do {
            let existing = try existingVolumeFamily(for: destination)
            for final in existing {
                let backup = backupDirectory.appendingPathComponent(UUID().uuidString)
                try fileManager.moveItem(at: final, to: backup)
                backups.append((backup, final))
            }
            for (staged, final) in stagedMappings {
                try fileManager.moveItem(at: staged, to: final)
                published.append(final)
            }
        } catch {
            for url in published { try? fileManager.removeItem(at: url) }
            for (backup, final) in backups { try? fileManager.moveItem(at: backup, to: final) }
            throw error
        }
    }

    private func removeStaleVolumes(for destination: URL) throws {
        for url in try existingVolumeFamily(for: destination)
            where url != destination && url.pathExtension.lowercased() != "zwz" {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func existingVolumeFamily(for destination: URL) throws -> [URL] {
        let parent = destination.deletingLastPathComponent()
        let base = destination.deletingPathExtension().lastPathComponent
        return try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard url.deletingPathExtension().lastPathComponent == base else { return false }
            let ext = url.pathExtension.lowercased()
            return ext == "zwz" || (ext.first == "z" && ext.dropFirst().allSatisfy(\.isNumber))
        }
    }

    private func normalizedModificationTime(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    private func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw ZwzV3Error.malformedArchive("archive too large") }
        return result.partialValue
    }
}

private extension CompressionLevel {
    var v3CompressionLevel: ZwzV2CompressionLevel {
        switch self {
        case .none: return .none
        case .fastest: return .fastest
        case .normal: return .normal
        case .max: return .max
        }
    }
}

struct ZwzV3DataRecord: Sendable {
    let sequence: UInt64
    let codec: ZwzV2Codec
    let originalLength: UInt32
    let sealed: Data
    let archiveOffset: UInt64
}

enum ZwzV3PayloadCodec {
    private static let blockDomain = Data("ZWZ3 data block v1".utf8)
    private static let indexDomain = Data("ZWZ3 encrypted index v1".utf8)

    static func encodeRecord(
        sequence: UInt64,
        codec: ZwzV2Codec,
        originalLength: UInt32,
        sealed: Data
    ) throws -> Data {
        guard originalLength > 0,
              sealed.count >= 28,
              let sealedLength = UInt32(exactly: sealed.count),
              let recordLength = UInt32(exactly: 20 + sealed.count) else {
            throw ZwzV3Error.malformedArchive("invalid data block record")
        }
        var data = Data()
        append(recordLength, to: &data)
        append(sequence, to: &data)
        data.append(codec.rawValue)
        data.append(contentsOf: [0, 0, 0])
        append(originalLength, to: &data)
        append(sealedLength, to: &data)
        data.append(sealed)
        return data
    }

    static func parseRecords(
        _ data: Data,
        absoluteOffset: UInt64,
        expectedCount: UInt64
    ) throws -> [ZwzV3DataRecord] {
        guard expectedCount <= UInt64(data.count / 32) else {
            throw ZwzV3Error.malformedArchive("impossible data block count")
        }
        var cursor = 0
        var expectedSequence: UInt64 = 0
        var records: [ZwzV3DataRecord] = []
        while expectedSequence < expectedCount {
            let recordStart = cursor
            let recordLength = Int(try read(UInt32.self, from: data, cursor: &cursor))
            let (recordEnd, overflow) = cursor.addingReportingOverflow(recordLength)
            guard !overflow, recordLength >= 48, recordEnd <= data.count else {
                throw ZwzV3Error.malformedArchive("invalid data block record length")
            }
            let sequence = try read(UInt64.self, from: data, cursor: &cursor)
            guard sequence == expectedSequence else {
                throw ZwzV3Error.malformedArchive("non-canonical data block sequence")
            }
            guard cursor < recordEnd, let codec = ZwzV2Codec(rawValue: data[cursor]) else {
                throw ZwzV3Error.malformedArchive("unknown data block codec")
            }
            cursor += 1
            guard cursor + 3 <= recordEnd, data[cursor..<(cursor + 3)].allSatisfy({ $0 == 0 }) else {
                throw ZwzV3Error.malformedArchive("non-zero data block reserved bytes")
            }
            cursor += 3
            let originalLength = try read(UInt32.self, from: data, cursor: &cursor)
            let sealedLength = try read(UInt32.self, from: data, cursor: &cursor)
            guard originalLength > 0,
                  sealedLength >= 28,
                  recordLength == 20 + Int(sealedLength),
                  Int(sealedLength) == recordEnd - cursor else {
                throw ZwzV3Error.malformedArchive("inconsistent data block lengths")
            }
            let sealed = data.subdata(in: cursor..<recordEnd)
            let offsetResult = absoluteOffset.addingReportingOverflow(UInt64(recordStart))
            guard !offsetResult.overflow else {
                throw ZwzV3Error.malformedArchive("overflowing data block offset")
            }
            records.append(ZwzV3DataRecord(
                sequence: sequence,
                codec: codec,
                originalLength: originalLength,
                sealed: sealed,
                archiveOffset: offsetResult.partialValue
            ))
            cursor = recordEnd
            guard expectedSequence < UInt64.max else {
                throw ZwzV3Error.malformedArchive("too many data block records")
            }
            expectedSequence += 1
        }
        guard cursor == data.count else {
            throw ZwzV3Error.malformedArchive("trailing data region bytes")
        }
        return records
    }

    static func blockAAD(
        archiveID: UUID,
        sequence: UInt64,
        codec: ZwzV2Codec,
        originalLength: UInt32
    ) -> Data {
        var aad = blockDomain
        aad.append(archiveID.bytes)
        append(sequence, to: &aad)
        aad.append(codec.rawValue)
        append(originalLength, to: &aad)
        return aad
    }

    static func indexAAD(
        archiveID: UUID,
        recipientCount: UInt32,
        recipientRegion: Data,
        dataBlockCount: UInt64,
        dataRegion: Data,
        signatureAlgorithm: ZwzV3SignatureAlgorithm
    ) -> Data {
        var aad = indexDomain
        aad.append(archiveID.bytes)
        aad.append(contentsOf: [
            ZwzArchiveEncryptionKind.publicKey.rawValue,
            ZwzV3ContentCipher.aes256GCM.rawValue,
            ZwzV3KeyAgreement.x25519.rawValue,
            ZwzV3KDF.hkdfSHA256.rawValue,
            ZwzV3KeyWrapCipher.aes256GCM.rawValue,
            signatureAlgorithm.rawValue,
            ZwzV3IndexCipher.aes256GCM.rawValue,
        ])
        append(recipientCount, to: &aad)
        aad.append(recipientRegion)
        append(dataBlockCount, to: &aad)
        aad.append(Data(SHA256.hash(data: dataRegion)))
        return aad
    }

    static func verifyBuiltArchive(_ archive: Data, contentKey: SymmetricKey) throws {
        let parsed = try ZwzV3BinaryCodec.parse(archive)
        if let signer = parsed.signer,
           !ZwzV3Crypto.verify(
               signer.signature,
               bytes: parsed.canonicalSignedBytes,
               publicKey: signer.signingPublicKey
           ) {
            throw ZwzV3Error.invalidSignature
        }
        let recipientRegion = try parsed.recipients.reduce(into: Data()) {
            $0.append(try ZwzV3BinaryCodec.encodeRecipient($1))
        }
        let plainIndex = try ZwzV3Crypto.open(
            parsed.encryptedIndex,
            key: contentKey,
            aad: indexAAD(
                archiveID: parsed.header.archiveID,
                recipientCount: parsed.header.recipientCount,
                recipientRegion: recipientRegion,
                dataBlockCount: parsed.header.dataBlockCount,
                dataRegion: parsed.dataRegion,
                signatureAlgorithm: parsed.header.signatureAlgorithm
            )
        )
        let index = try ZwzV2IndexCodec.decodePlain(plainIndex)
        let records = try parseRecords(
            parsed.dataRegion,
            absoluteOffset: parsed.header.dataRegionOffset,
            expectedCount: parsed.header.dataBlockCount
        )
        try validate(index: index, parsed: parsed, records: records)
    }

    static func validate(
        index: ZwzV2Index,
        parsed: ZwzV3ParsedArchive,
        records: [ZwzV3DataRecord]
    ) throws {
        guard index.archiveID == parsed.header.archiveID,
              index.blockSize > 0,
              UInt64(records.count) == parsed.header.dataBlockCount else {
            throw ZwzV3Error.malformedArchive("index metadata mismatch")
        }
        try ZwzV2PathValidator.validateNoDuplicatePaths(index.entries)
        var seen = Set<UInt64>()
        for entry in index.entries {
            if entry.type == .directory {
                guard entry.blocks.isEmpty, entry.originalSize == 0 else {
                    throw ZwzV3Error.malformedArchive("directory entry has data")
                }
                continue
            }
            var expectedFileOffset: UInt64 = 0
            for descriptor in entry.blocks {
                guard descriptor.sequence < UInt64(records.count),
                      seen.insert(descriptor.sequence).inserted else {
                    throw ZwzV3Error.malformedArchive("duplicate or missing block sequence")
                }
                let record = records[Int(descriptor.sequence)]
                guard descriptor.sequence == record.sequence,
                      descriptor.fileOffset == expectedFileOffset,
                      descriptor.archiveOffset == record.archiveOffset,
                      descriptor.storedLength == UInt32(record.sealed.count),
                      descriptor.originalLength == record.originalLength,
                      descriptor.codec == record.codec,
                      descriptor.authenticationTag.isEmpty else {
                    throw ZwzV3Error.malformedArchive("block descriptor mismatch")
                }
                let next = expectedFileOffset.addingReportingOverflow(UInt64(descriptor.originalLength))
                guard !next.overflow, next.partialValue <= entry.originalSize else {
                    throw ZwzV3Error.malformedArchive("block layout exceeds file size")
                }
                expectedFileOffset = next.partialValue
            }
            guard expectedFileOffset == entry.originalSize else {
                throw ZwzV3Error.malformedArchive("block layout does not cover file")
            }
        }
        guard seen.count == records.count else {
            throw ZwzV3Error.malformedArchive("unreferenced data block")
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(
        _ type: T.Type,
        from data: Data,
        cursor: inout Int
    ) throws -> T {
        let size = MemoryLayout<T>.size
        let end = cursor.addingReportingOverflow(size)
        guard !end.overflow, end.partialValue <= data.count else {
            throw ZwzV3Error.malformedArchive("truncated data block field")
        }
        defer { cursor = end.partialValue }
        return data[cursor..<end.partialValue].enumerated().reduce(into: T.zero) { value, byte in
            value |= T(byte.element) << (byte.offset * 8)
        }
    }
}
