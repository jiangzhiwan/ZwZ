import Foundation

private struct MissingZwzPrivateKeyProvider: ZwzPrivateKeyProvider {
    func agreementPrivateKey(fingerprint: String, reason: String) throws -> Data {
        throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
    }

    func signingPrivateKey(fingerprint: String, reason: String) throws -> Data {
        throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
    }

    func isKnownSigningKey(fingerprint: String, signingPublicKey: Data) -> Bool { false }
}

/// Compatibility adapter that routes synchronous ZWZ APIs by logical archive magic.
public final class ZwzExtractor {
    public init() {}

    public func extract(
        archivePath: String,
        destinationPath: String,
        password: String? = nil,
        progress: ProgressHandler? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws {
        _ = try extract(
            archivePath: archivePath,
            destinationPath: destinationPath,
            password: password,
            keyProvider: nil,
            progress: progress,
            cancellationToken: cancellationToken
        )
    }

    public func extract(
        archivePath: String,
        destinationPath: String,
        password: String? = nil,
        keyProvider: ZwzPrivateKeyProvider?,
        progress: ProgressHandler? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws -> ZwzArchiveSecurityInfo {
        try cancellationToken?.checkCancellation()
        let archiveURLs = try Self.archiveURLs(for: archivePath)
        switch try Self.codec(for: archiveURLs) {
        case .v2(let header):
            let destinationURL = URL(fileURLWithPath: destinationPath)
            _ = try waitForZwzAsync {
                try await ZwzV2Extractor().extractAll(
                    archiveURLs: archiveURLs,
                    to: destinationURL,
                    password: password
                )
            }
            try cancellationToken?.checkCancellation()
            progress?(1.0)
            return Self.v2SecurityInfo(header: header)
        case .v3:
            return try ZwzV3Extractor().extractAll(
                archivePath: archivePath,
                destinationPath: destinationPath,
                keyProvider: keyProvider ?? MissingZwzPrivateKeyProvider(),
                progress: progress,
                cancellationToken: cancellationToken
            )
        }
    }

    public func listEntries(archivePath: String, password: String? = nil) throws -> [ArchiveEntry] {
        try listEntries(archivePath: archivePath, password: password, keyProvider: nil).entries
    }

    public func listEntries(
        archivePath: String,
        password: String? = nil,
        keyProvider: ZwzPrivateKeyProvider?
    ) throws -> ZwzArchiveListing {
        let archiveURLs = try Self.archiveURLs(for: archivePath)
        switch try Self.codec(for: archiveURLs) {
        case .v2(let header):
            let index = try waitForZwzAsync {
                try await ZwzV2Extractor().preview(archiveURLs: archiveURLs, password: password)
            }
            return ZwzArchiveListing(
                entries: Self.archiveEntries(from: index.entries),
                version: 2,
                securityInfo: Self.v2SecurityInfo(header: header)
            )
        case .v3:
            let listing = try ZwzV3Extractor().listEntries(
                archivePath: archivePath,
                keyProvider: keyProvider ?? MissingZwzPrivateKeyProvider()
            )
            return ZwzArchiveListing(
                entries: Self.archiveEntries(from: listing.entries),
                version: 3,
                securityInfo: listing.securityInfo
            )
        }
    }

    public func extractEntryToTemp(
        archivePath: String,
        entryPath: String,
        password: String? = nil
    ) throws -> URL {
        try extractEntryToTemp(
            archivePath: archivePath,
            entryPath: entryPath,
            password: password,
            keyProvider: nil
        )
    }

    public func extractEntryToTemp(
        archivePath: String,
        entryPath: String,
        password: String? = nil,
        keyProvider: ZwzPrivateKeyProvider?
    ) throws -> URL {
        let archiveURLs = try Self.archiveURLs(for: archivePath)
        if case .v3 = try Self.codec(for: archiveURLs) {
            return try ZwzV3Extractor().extractEntryToTemp(
                archivePath: archivePath,
                entryPath: entryPath,
                keyProvider: keyProvider ?? MissingZwzPrivateKeyProvider()
            )
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("zwz-entry-\(UUID().uuidString)", isDirectory: true)

        _ = try waitForZwzAsync {
            try await ZwzV2Extractor().extractEntry(
                path: entryPath,
                archiveURLs: archiveURLs,
                to: destination,
                password: password
            )
        }
        return destination.appendingPathComponent(entryPath)
    }

    public func isZwzFormat(_ path: String) -> Bool {
        guard let data = try? Self.readPrefix(at: URL(fileURLWithPath: path), count: 4) else {
            return false
        }
        return Array(data) == ZwzFormat.magic ||
            Array(data) == ZwzV2Format.magic ||
            Array(data) == [0x5A, 0x57, 0x5A, 0x33] ||
            Array(data) == ZwzV2Format.splitMagic
    }

    static func archiveEntries(from entries: [ZwzV2Entry]) -> [ArchiveEntry] {
        let directorySizes = entries
            .filter { $0.type == .directory }
            .reduce(into: [String: Int64]()) { result, directory in
                let prefix = directory.path + "/"
                result[directory.path] = entries
                    .filter { $0.type == .file && $0.path.hasPrefix(prefix) }
                    .reduce(0) { $0 + Int64(clamping: $1.originalSize) }
            }

        return entries.map { entry in
            ArchiveEntry(
                name: (entry.path as NSString).lastPathComponent,
                path: entry.path,
                size: entry.type == .directory
                    ? directorySizes[entry.path, default: 0]
                    : Int64(clamping: entry.originalSize),
                isDirectory: entry.type == .directory,
                modifiedDate: entry.modificationTime
            )
        }
    }

    private enum Codec {
        case v2(ZwzV2Header)
        case v3
    }

    private static func codec(for archiveURLs: [URL]) throws -> Codec {
        let reader = try ZwzV2VolumeReader(urls: archiveURLs)
        let magic = Array(try reader.read(offset: 0, length: 4))
        if magic == ZwzFormat.magic { throw ZwzV2Error.unsupportedVersion(1) }
        if magic == ZwzV2Format.magic {
            let header = try ZwzV2BinaryCodec.decodeHeader(
                reader.read(offset: 0, length: ZwzV2Header.encodedLength)
            )
            return .v2(header)
        }
        if magic == [0x5A, 0x57, 0x5A, 0x33] { return .v3 }
        throw ZwzV3Error.malformedArchive("unsupported logical archive magic")
    }

    private static func v2SecurityInfo(header: ZwzV2Header) -> ZwzArchiveSecurityInfo {
        ZwzArchiveSecurityInfo(
            encryption: header.flags.contains(.encrypted) ? .password : .none,
            signature: .unsigned
        )
    }

    private static func archiveURLs(for path: String) throws -> [URL] {
        let selectedURL = URL(fileURLWithPath: path)
        let prefix = try readPrefix(at: selectedURL, count: 4)
        guard Array(prefix) == ZwzV2Format.splitMagic else {
            return [selectedURL]
        }

        let directory = selectedURL.deletingLastPathComponent()
        let baseName = splitBaseName(for: selectedURL.lastPathComponent)
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let volumes = try candidates
            .filter { splitBaseName(for: $0.lastPathComponent) == baseName }
            .compactMap { url -> (url: URL, number: UInt32)? in
                guard let prefix = try? readPrefix(at: url, count: 4),
                      Array(prefix) == ZwzV2Format.splitMagic else {
                    return nil
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                guard let data = try handle.read(upToCount: ZwzV2SplitEnvelope.encodedLength),
                      data.count == ZwzV2SplitEnvelope.encodedLength else {
                    throw ZwzV2Error.malformedArchive("truncated split volume envelope")
                }
                let envelope = try ZwzV2BinaryCodec.decodeSplitEnvelope(data)
                return (url, envelope.volumeNumber)
            }
            .sorted { $0.number < $1.number }
            .map(\.url)

        guard !volumes.isEmpty else {
            throw ZwzV2Error.missingVolume(0)
        }
        return volumes
    }

    private static func splitBaseName(for name: String) -> String {
        let nsName = name as NSString
        let ext = nsName.pathExtension.lowercased()
        let volumeDigits = ext.dropFirst()
        let isNumberedVolume = ext.first == "z" &&
            volumeDigits.count >= 2 &&
            volumeDigits.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
        return ext == "zwz" || isNumberedVolume ? nsName.deletingPathExtension : name
    }

    private static func readPrefix(at url: URL, count: Int) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ZwzError.fileNotFound(url.path)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw ZwzV2Error.malformedArchive("archive is too short")
        }
        return data
    }
}
