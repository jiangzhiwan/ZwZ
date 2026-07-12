import Foundation

/// Compatibility adapter that preserves the existing synchronous API while reading ZWZ v2 archives.
public final class ZwzExtractor {
    public init() {}

    public func extract(
        archivePath: String,
        destinationPath: String,
        password: String? = nil,
        progress: ProgressHandler? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws {
        try cancellationToken?.checkCancellation()
        let archiveURLs = try Self.archiveURLs(for: archivePath)
        try Self.rejectV1Archive(at: archiveURLs[0])
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
    }

    public func listEntries(archivePath: String, password: String? = nil) throws -> [ArchiveEntry] {
        let archiveURLs = try Self.archiveURLs(for: archivePath)
        try Self.rejectV1Archive(at: archiveURLs[0])
        let index = try waitForZwzAsync {
            try await ZwzV2Extractor().preview(archiveURLs: archiveURLs, password: password)
        }
        return Self.archiveEntries(from: index.entries)
    }

    public func extractEntryToTemp(
        archivePath: String,
        entryPath: String,
        password: String? = nil
    ) throws -> URL {
        let archiveURLs = try Self.archiveURLs(for: archivePath)
        try Self.rejectV1Archive(at: archiveURLs[0])
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
        return Array(data) == ZwzV2Format.magic || Array(data) == ZwzV2Format.splitMagic
    }

    private static func archiveEntries(from entries: [ZwzV2Entry]) -> [ArchiveEntry] {
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

    private static func rejectV1Archive(at url: URL) throws {
        let prefix = try readPrefix(at: url, count: 4)
        if Array(prefix) == ZwzFormat.magic {
            throw ZwzV2Error.unsupportedVersion(1)
        }
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
        let isNumberedVolume = ext.count == 3 && ext.first == "z" && Int(ext.dropFirst()) != nil
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
