import Foundation
import ZIPFoundation
import Compression

/// ZIP 压缩器 — 支持多线程压缩
public class ZipCompressor {

    public init() {}

    /// 创建 ZIP 压缩包
    public func compress(
        sourcePath: String,
        destinationPath: String,
        options: CompressionOptions = CompressionOptions(),
        progress: ProgressHandler? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destinationURL = URL(fileURLWithPath: destinationPath)

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try cancellationToken?.checkCancellation()
        let destinationExisted = FileManager.default.fileExists(atPath: destinationPath)
        if destinationExisted {
            try FileManager.default.removeItem(at: destinationURL)
        }
        do {

        // 收集所有文件
        let files = try collectFiles(from: sourceURL)
        let totalFiles = max(files.count, 1)

        let threads = resolveThreadCount(options.threadCount)
        let useMultithreading = threads > 1 && files.count > 1

        if useMultithreading {
            try compressMultithreaded(
                files: files,
                destinationURL: destinationURL,
                options: options,
                threads: threads,
                totalFiles: totalFiles,
                progress: progress,
                cancellationToken: cancellationToken
            )
        } else {
            try compressSingleThreaded(
                sourceURL: sourceURL,
                files: files,
                destinationURL: destinationURL,
                options: options,
                totalFiles: totalFiles,
                progress: progress,
                cancellationToken: cancellationToken
            )
        }

        try cancellationToken?.checkCancellation()

        // 处理分卷
        if let splitVolume = options.splitVolume {
            try splitArchive(at: destinationURL, volumeSize: splitVolume.bytes)
        }
        } catch {
            if !destinationExisted { try? FileManager.default.removeItem(at: destinationURL) }
            throw error
        }
    }

    // MARK: - Multi-threaded Compression

    private struct CompressedEntry: Sendable {
        let relativePath: String
        let isDirectory: Bool
        let data: Data
    }

    private final class ConcurrentCompressionResults: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [CompressedEntry?]
        private var errors: [Error?]

        init(count: Int) {
            entries = Array(repeating: nil, count: count)
            errors = Array(repeating: nil, count: count)
        }

        func store(_ entry: CompressedEntry, at index: Int) {
            lock.withLock { entries[index] = entry }
        }

        func store(_ error: Error, at index: Int) {
            lock.withLock { errors[index] = error }
        }

        func snapshot() -> (entries: [CompressedEntry?], errors: [Error?]) {
            lock.withLock { (entries, errors) }
        }
    }

    private func compressMultithreaded(
        files: [(url: URL, relativePath: String, isDirectory: Bool)],
        destinationURL: URL,
        options: CompressionOptions,
        threads: Int,
        totalFiles: Int,
        progress: ProgressHandler?,
        cancellationToken: CancellationToken?
    ) throws {
        let compressionMethod: CompressionMethod = options.level == .none ? .none : .deflate

        // 并行压缩各文件到内存（仅预计算 CRC 和原始大小，实际压缩由 ZIPFoundation 在组装时完成）
        let concurrentResults = ConcurrentCompressionResults(count: files.count)

        DispatchQueue.concurrentPerform(iterations: files.count) { idx in
            let file = files[idx]
            do {
                if file.isDirectory {
                    concurrentResults.store(CompressedEntry(
                        relativePath: file.relativePath + "/",
                        isDirectory: true,
                        data: Data()
                    ), at: idx)
                } else {
                    let fileData = try Data(contentsOf: file.url)
                    concurrentResults.store(CompressedEntry(
                        relativePath: file.relativePath,
                        isDirectory: false,
                        data: fileData
                    ), at: idx)
                }
            } catch {
                concurrentResults.store(error, at: idx)
            }
        }

        let results = concurrentResults.snapshot()

        // 检查错误
        for (idx, err) in results.errors.enumerated() {
            if let err = err {
                throw ZwzError.compressionFailed("File \(files[idx].relativePath): \(err.localizedDescription)")
            }
        }

        // 单线程快速组装 ZIP 结构 — 使用临时文件方式让 ZIPFoundation 压缩
        let archive = try ZIPFoundation.Archive(url: destinationURL, accessMode: .create)
        for (idx, result) in results.entries.enumerated() {
            try cancellationToken?.checkCancellation()
            guard let entry = result else { continue }
            if entry.isDirectory {
                // 跳过目录条目
            } else {
                // 写临时文件让 ZIPFoundation 压缩
                let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("zwz-\(UUID().uuidString)")
                try entry.data.write(to: tempFile)
                defer { try? FileManager.default.removeItem(at: tempFile) }
                _ = try archive.addEntry(with: entry.relativePath, fileURL: tempFile, compressionMethod: compressionMethod)
            }
            let prog = Double(idx + 1) / Double(totalFiles)
            progress?(min(prog, 1.0))
        }

        progress?(1.0)
    }

    // MARK: - Single-threaded Compression (original, also for single file)

    private func compressSingleThreaded(
        sourceURL: URL,
        files: [(url: URL, relativePath: String, isDirectory: Bool)],
        destinationURL: URL,
        options: CompressionOptions,
        totalFiles: Int,
        progress: ProgressHandler?,
        cancellationToken: CancellationToken?
    ) throws {
        let archive = try ZIPFoundation.Archive(url: destinationURL, accessMode: .create)
        let compressionMethod: CompressionMethod = options.level == .none ? .none : .deflate

        var processedFiles = 0
        let isDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

        if isDirectory {
            for file in files {
                try cancellationToken?.checkCancellation()
                if file.isDirectory {
                    // 跳过目录条目（ZIPFoundation 会自动创建目录路径）
                } else {
                    try addFileToArchive(
                        fileURL: file.url,
                        relativePath: file.relativePath,
                        archive: archive,
                        compressionMethod: compressionMethod,
                        options: options
                    )
                }
                processedFiles += 1
                let progressValue = Double(processedFiles) / Double(totalFiles)
                progress?(min(progressValue, 1.0))
            }
        } else {
            try cancellationToken?.checkCancellation()
            try addFileToArchive(
                fileURL: sourceURL,
                relativePath: sourceURL.lastPathComponent,
                archive: archive,
                compressionMethod: compressionMethod,
                options: options
            )
            processedFiles = 1
            progress?(1.0)
        }
    }

    // MARK: - Helpers

    private func compressBytes(_ data: Data, method: CompressionMethod) -> Data {
        if method == .none { return data }
        // 使用 ZIPFoundation 的 streaming compress
        var result = Data()
        do {
            _ = try Data.compress(
                size: Int64(data.count),
                bufferSize: 4096,
                provider: { pos, size in
                    let start = Int(pos)
                    let end = min(start + size, data.count)
                    return data.subdata(in: start..<end)
                },
                consumer: { chunk in
                    result.append(chunk)
                }
            )
        } catch {
            return data
        }
        return result
    }

    private func addFileToArchive(
        fileURL: URL,
        relativePath: String,
        archive: ZIPFoundation.Archive,
        compressionMethod: CompressionMethod,
        options: CompressionOptions
    ) throws {
        try archive.addEntry(
            with: relativePath,
            fileURL: fileURL,
            compressionMethod: compressionMethod
        )
    }

    // MARK: - File Collection

    private func collectFiles(from sourceURL: URL) throws -> [(url: URL, relativePath: String, isDirectory: Bool)] {
        let fm = FileManager.default
        var files: [(url: URL, relativePath: String, isDirectory: Bool)] = []
        let isDir = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

        if isDir {
            if let enumerator = fm.enumerator(
                at: sourceURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) {
                for case let fileURL as URL in enumerator {
                    let rv = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
                    let isDir = rv.isDirectory ?? false
                    let relPath = relativePath(of: fileURL, from: sourceURL)
                    files.append((url: fileURL, relativePath: relPath, isDirectory: isDir))
                }
            }
        } else {
            files.append((url: sourceURL, relativePath: sourceURL.lastPathComponent, isDirectory: false))
        }
        return files
    }

    private func relativePath(of fileURL: URL, from rootURL: URL) -> String {
        let rootPath = rootURL.resolvingSymlinksInPath().path
        let filePath = fileURL.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(rootPath + "/") else { return fileURL.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    // MARK: - Split Volume

    private func splitArchive(at archiveURL: URL, volumeSize: Int64) throws {
        let archiveData = try Data(contentsOf: archiveURL)
        let totalSize = archiveData.count
        let volumeCount = Int((Int64(totalSize) + volumeSize - 1) / volumeSize)

        for i in 0..<volumeCount {
            let start = Int(volumeSize) * i
            let end = min(start + Int(volumeSize), totalSize)
            let chunk = archiveData.subdata(in: start..<end)
            let suffix = String(format: ".z%02d", i + 1)
            let volumeURL = archiveURL.deletingPathExtension().appendingPathExtension(
                archiveURL.pathExtension + suffix
            )
            try chunk.write(to: volumeURL)
        }

        try FileManager.default.removeItem(at: archiveURL)
    }

    private func countFiles(in url: URL) -> Int {
        let fm = FileManager.default
        var count = 0
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            while enumerator.nextObject() != nil { count += 1 }
        }
        return max(count, 1)
    }
}
