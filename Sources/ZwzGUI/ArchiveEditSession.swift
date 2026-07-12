import Foundation
import ZwzCore

enum ArchiveEditorError: LocalizedError {
    case unsupportedFormat
    case invalidPath
    case notTextFile
    case textFileTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "Only ZIP and ZWZ archives can be edited."
        case .invalidPath: return "The archive path is invalid."
        case .notTextFile: return "This file cannot be edited as text."
        case .textFileTooLarge: return "Text files larger than 2 MB cannot be edited in place."
        }
    }
}

final class ArchiveEditSession {
    let archiveURL: URL
    let format: ExtractionFormat
    let workspaceURL: URL
    private(set) var hasChanges = false
    private let fileManager = FileManager.default

    private static let textExtensions: Set<String> = [
        "txt", "md", "json", "xml", "csv", "yaml", "yml", "log", "swift", "js", "ts", "html", "css", "py",
        "java", "c", "cc", "cpp", "cxx", "h", "hpp"
    ]

    private init(archiveURL: URL, format: ExtractionFormat, workspaceURL: URL) {
        self.archiveURL = archiveURL
        self.format = format
        self.workspaceURL = workspaceURL
    }

    static func create(archiveURL: URL, password: String?) throws -> ArchiveEditSession {
        let extractor = ArchiveExtractor()
        let format = try extractor.detectFormat(archivePath: archiveURL.path)
        guard format == .zip || format == .zwz else { throw ArchiveEditorError.unsupportedFormat }

        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zwz-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        do {
            if format == .zip {
                try extractZip(archiveURL: archiveURL, to: workspaceURL, password: password)
            } else {
                try extractor.extract(archivePath: archiveURL.path, destinationPath: workspaceURL.path, password: password)
            }
            return ArchiveEditSession(archiveURL: archiveURL, format: format, workspaceURL: workspaceURL)
        } catch {
            try? FileManager.default.removeItem(at: workspaceURL)
            throw error
        }
    }

    deinit { try? fileManager.removeItem(at: workspaceURL) }

    func entries() throws -> [ArchiveEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(at: workspaceURL, includingPropertiesForKeys: Array(keys)) else { return [] }
        var results: [ArchiveEntry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            let relative = relativePath(of: url)
            let isDirectory = values.isDirectory ?? false
            results.append(ArchiveEntry(
                name: url.lastPathComponent,
                path: isDirectory ? relative + "/" : relative,
                size: isDirectory ? 0 : Int64(values.fileSize ?? 0),
                isDirectory: isDirectory,
                modifiedDate: values.contentModificationDate
            ))
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func add(urls: [URL], into directoryPath: String) throws {
        guard !urls.isEmpty else { return }
        for url in urls {
            guard fileManager.fileExists(atPath: url.path) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
        }
        let directory = try safeURL(for: directoryPath, allowEmpty: true)
        let directoryExisted = fileManager.fileExists(atPath: directory.path)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !directoryExisted { hasChanges = true }
        for url in urls {
            let destination = directory.appendingPathComponent(url.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                if fileManager.contentsEqual(atPath: url.path, andPath: destination.path) { continue }
                try replaceItemAtomically(at: destination, with: url)
            } else {
                try fileManager.copyItem(at: url, to: destination)
            }
            hasChanges = true
        }
    }

    func delete(path: String) throws {
        try fileManager.removeItem(at: safeURL(for: path))
        hasChanges = true
    }

    func rename(path: String, to newName: String) throws {
        guard !newName.isEmpty, !newName.contains("/"), newName != ".", newName != ".." else { throw ArchiveEditorError.invalidPath }
        let source = try safeURL(for: path)
        guard source.lastPathComponent != newName else { return }
        let destination = source.deletingLastPathComponent().appendingPathComponent(newName)
        guard !fileManager.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try fileManager.moveItem(at: source, to: destination)
        hasChanges = true
    }

    func replace(path: String, with sourceURL: URL) throws {
        let destination = try safeURL(for: path)
        if fileManager.contentsEqual(atPath: sourceURL.path, andPath: destination.path) { return }
        try replaceItemAtomically(at: destination, with: sourceURL)
        hasChanges = true
    }

    func text(for path: String) throws -> String {
        let url = try safeURL(for: path)
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size <= 2 * 1024 * 1024 else { throw ArchiveEditorError.textFileTooLarge }
        guard Self.textExtensions.contains(url.pathExtension.lowercased()),
              let text = try? String(contentsOf: url, encoding: .utf8) else { throw ArchiveEditorError.notTextFile }
        return text
    }

    func writeText(_ text: String, to path: String) throws {
        let url = try safeURL(for: path)
        guard let data = text.data(using: .utf8) else { throw ArchiveEditorError.notTextFile }
        if (try? Data(contentsOf: url)) == data { return }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        hasChanges = true
    }

    func save(password: String?, progress: ProgressHandler? = nil) throws {
        let temporaryOutput = archiveURL.deletingLastPathComponent()
            .appendingPathComponent(".zwz-edit-save-\(UUID().uuidString).\(archiveURL.pathExtension)")
        let options = CompressionOptions(level: .normal, password: password, aes256: true, format: format == .zip ? .zip : .zwz)
        do {
            switch format {
            case .zip:
                try ZipCompressor().compress(sourcePath: workspaceURL.path, destinationPath: temporaryOutput.path, options: options, progress: progress)
            case .zwz:
                try ZwzCompressor().compress(sourcePath: workspaceURL.path, destinationPath: temporaryOutput.path, options: options, progress: progress)
            default:
                throw ArchiveEditorError.unsupportedFormat
            }
            _ = try fileManager.replaceItemAt(archiveURL, withItemAt: temporaryOutput, backupItemName: nil, options: .usingNewMetadataOnly)
            hasChanges = false
        } catch {
            try? fileManager.removeItem(at: temporaryOutput)
            throw error
        }
    }

    private func safeURL(for path: String, allowEmpty: Bool = false) throws -> URL {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.isEmpty && allowEmpty { return workspaceURL }
        guard !normalized.isEmpty, !normalized.split(separator: "/").contains(where: { $0 == ".." }) else {
            throw ArchiveEditorError.invalidPath
        }
        let url = workspaceURL.appendingPathComponent(normalized).standardizedFileURL
        guard url.path.hasPrefix(workspaceURL.standardizedFileURL.path + "/") else { throw ArchiveEditorError.invalidPath }
        return url
    }

    private func relativePath(of url: URL) -> String {
        let rootPath = workspaceURL.resolvingSymlinksInPath().path
        let itemPath = url.resolvingSymlinksInPath().path
        guard itemPath.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(itemPath.dropFirst(rootPath.count + 1))
    }

    private func replaceItemAtomically(at destination: URL, with source: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".zwz-edit-replace-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: source, to: temporary)
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: temporary,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func extractZip(archiveURL: URL, to destinationURL: URL, password: String?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        var arguments = ["-oq"]
        if let password, !password.isEmpty { arguments += ["-P", password] }
        arguments += [archiveURL.path, "-d", destinationURL.path]
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ZwzError.extractionFailed(details.isEmpty ? "Unable to extract ZIP archive" : details)
        }
    }
}
