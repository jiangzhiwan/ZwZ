import Foundation

/// 统一的 zwz API 入口 —— 将压缩、解压、预览整合在一个接口中。
///
/// 用法:
/// ```swift
/// let api = ZwzAPI()
/// try api.compress(sourcePath: "/path/to/file", destinationPath: "/output.zip")
/// try api.extract(archivePath: "/path/to/archive.zip", destinationPath: "/output")
/// let entries = try api.list(archivePath: "/path/to/archive.zip")
/// ```
public final class ZwzAPI {
    private let zipCompressor = ZipCompressor()
    private let zwzCompressor = ZwzCompressor()
    private let extractor = ArchiveExtractor()
    private let previewer = ArchivePreviewer()

    public init() {}

    // MARK: - Compress

    /// 压缩文件或文件夹
    /// - Parameters:
    ///   - sourcePath: 源文件/文件夹路径
    ///   - destinationPath: 输出路径（可选，默认同目录同名 .zip/.zwz）
    ///   - options: 压缩选项（包含格式、压缩等级、密码、多线程等）
    ///   - progress: 进度回调 (0.0–1.0)
    public func compress(
        sourcePath: String,
        destinationPath: String? = nil,
        options: CompressionOptions = CompressionOptions(),
        progress: ProgressHandler? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws -> String {
        try compress(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            options: options,
            keyProvider: nil,
            progress: progress,
            cancellationToken: cancellationToken
        )
    }

    public func compress(
        sourcePath: String,
        destinationPath: String? = nil,
        options: CompressionOptions = CompressionOptions(),
        keyProvider: ZwzPrivateKeyProvider?,
        progress: ProgressHandler? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws -> String {
        let srcURL = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw ZwzError.fileNotFound(sourcePath)
        }

        // 确定输出路径
        let ext = options.format.fileExtension
        let destPath: String
        if let outPath = destinationPath {
            destPath = outPath
        } else {
            destPath = srcURL.deletingPathExtension().path + "." + ext
        }

        // 如果输出路径是目录，在目录内创建压缩包
        var finalDestPath = destPath
        if FileManager.default.fileExists(atPath: destPath) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: destPath, isDirectory: &isDir)
            if isDir.boolValue {
                let name = srcURL.lastPathComponent.replacingOccurrences(
                    of: srcURL.pathExtension.isEmpty ? "" : "." + srcURL.pathExtension,
                    with: ""
                ) + "." + ext
                finalDestPath = (destPath as NSString).appendingPathComponent(name)
            }
        }

        // 密码强度检查
        if let pwd = options.password, !pwd.isEmpty {
            let strength = PasswordStrength.evaluate(pwd)
            if strength.score <= 1 {
                FileHandle.standardError.write("⚠️  警告: 密码强度弱 (\(strength.displayName))\n".data(using: .utf8)!)
            }
        }

        // 根据格式选择压缩器
        switch options.format {
        case .zip:
            try zipCompressor.compress(
                sourcePath: sourcePath,
                destinationPath: finalDestPath,
                options: options,
                progress: progress,
                cancellationToken: cancellationToken
            )
        case .zwz:
            try zwzCompressor.compress(
                sourcePath: sourcePath,
                destinationPath: finalDestPath,
                options: options,
                keyProvider: keyProvider,
                progress: progress,
                cancellationToken: cancellationToken
            )
        }

        return finalDestPath
    }

    // MARK: - Extract

    /// 解压压缩包
    /// - Parameters:
    ///   - archivePath: 压缩包路径
    ///   - destinationPath: 解压目标路径（可选，默认同目录同名文件夹）
    ///   - password: 解压密码（可选）
    ///   - progress: 进度回调 (0.0–1.0)
    public func extract(
        archivePath: String,
        destinationPath: String? = nil,
        password: String? = nil,
        progress: ProgressHandler? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws -> String {
        try extract(
            archivePath: archivePath,
            destinationPath: destinationPath,
            password: password,
            keyProvider: nil,
            progress: progress,
            cancellationToken: cancellationToken
        ).destinationPath
    }

    public func extract(
        archivePath: String,
        destinationPath: String? = nil,
        password: String? = nil,
        keyProvider: ZwzPrivateKeyProvider?,
        progress: ProgressHandler? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws -> ZwzExtractionResult {
        guard FileManager.default.fileExists(atPath: archivePath) else {
            throw ZwzError.fileNotFound(archivePath)
        }

        let archURL = URL(fileURLWithPath: archivePath)
        let destPath: String
        if let dest = destinationPath {
            destPath = dest
        } else {
            let baseName = archURL.deletingPathExtension().lastPathComponent
            destPath = archURL.deletingLastPathComponent()
                .appendingPathComponent(baseName).path
        }

        let securityInfo = try extractor.extract(
            archivePath: archivePath,
            destinationPath: destPath,
            password: password,
            keyProvider: keyProvider,
            progress: progress,
            cancellationToken: cancellationToken
        )
        let version: UInt16? = try extractor.detectFormat(archivePath: archivePath) == .zwz ?
            (securityInfo?.encryption == .publicKey ? 3 : 2) : nil
        return ZwzExtractionResult(
            destinationPath: destPath,
            version: version,
            securityInfo: securityInfo
        )
    }

    // MARK: - List / Preview

    /// 列出压缩包内容（不解压）
    /// - Parameter archivePath: 压缩包路径
    /// - Returns: 条目列表
    public func list(archivePath: String) throws -> [ArchiveEntry] {
        guard FileManager.default.fileExists(atPath: archivePath) else {
            throw ZwzError.fileNotFound(archivePath)
        }
        return try previewer.preview(archivePath: archivePath)
    }

    public func list(
        archivePath: String,
        password: String? = nil,
        keyProvider: ZwzPrivateKeyProvider?
    ) throws -> ZwzArchiveListing {
        guard FileManager.default.fileExists(atPath: archivePath) else {
            throw ZwzError.fileNotFound(archivePath)
        }
        guard try extractor.detectFormat(archivePath: archivePath) == .zwz else {
            return ZwzArchiveListing(
                entries: try previewer.preview(archivePath: archivePath, password: password),
                version: nil,
                securityInfo: nil
            )
        }
        return try ZwzExtractor().listEntries(
            archivePath: archivePath,
            password: password,
            keyProvider: keyProvider
        )
    }

    // MARK: - Detect Format

    /// 检测压缩包格式
    /// - Parameter archivePath: 压缩包路径
    /// - Returns: 检测到的格式
    public func detectFormat(archivePath: String) throws -> ExtractionFormat {
        guard FileManager.default.fileExists(atPath: archivePath) else {
            throw ZwzError.fileNotFound(archivePath)
        }
        return try extractor.detectFormat(archivePath: archivePath)
    }

    // MARK: - Extract Single Entry

    /// 将压缩包中的单个条目提取到临时文件
    /// - Parameters:
    ///   - archivePath: 压缩包路径
    ///   - entryPath: 条目路径
    ///   - password: 密码（可选）
    /// - Returns: 提取后的临时文件 URL
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
        guard FileManager.default.fileExists(atPath: archivePath) else {
            throw ZwzError.fileNotFound(archivePath)
        }
        return try extractor.extractEntryToTemp(
            archivePath: archivePath,
            entryPath: entryPath,
            password: password,
            keyProvider: keyProvider
        )
    }
}

// MARK: - Format Helpers

public extension ZwzAPI {
    /// 判断路径是否是支持的压缩包格式
    static func isArchivePath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["zip", "zwz", "rar", "7z", "gz", "tgz"].contains(ext) || path.hasSuffix(".tar.gz")
    }
}
