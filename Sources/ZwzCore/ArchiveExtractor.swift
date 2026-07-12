import Foundation
import ZIPFoundation
import SWCompression

/// 压缩包解压器
public class ArchiveExtractor {

    public init() {}

    /// 自动检测格式并解压
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

    @discardableResult
    public func extract(
        archivePath: String,
        destinationPath: String,
        password: String? = nil,
        keyProvider: ZwzPrivateKeyProvider?,
        progress: ProgressHandler? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws -> ZwzArchiveSecurityInfo? {
        try cancellationToken?.checkCancellation()
        let format = try detectFormat(archivePath: archivePath)
        var securityInfo: ZwzArchiveSecurityInfo?

        switch format {
        case .zip:
            try extractZip(archivePath: archivePath, destinationPath: destinationPath, password: password, progress: progress)
        case .zwz:
            let zwzExtractor = ZwzExtractor()
            securityInfo = try zwzExtractor.extract(
                archivePath: archivePath,
                destinationPath: destinationPath,
                password: password,
                keyProvider: keyProvider,
                progress: progress,
                cancellationToken: cancellationToken
            )
        case .tarGz, .tgz:
            try extractTarGz(archivePath: archivePath, destinationPath: destinationPath, progress: progress)
        case .gz:
            try extractGz(archivePath: archivePath, destinationPath: destinationPath, progress: progress)
        case .rar:
            try extractRar(archivePath: archivePath, destinationPath: destinationPath, password: password, progress: progress)
        case .sevenZip:
            try extract7z(archivePath: archivePath, destinationPath: destinationPath, password: password, progress: progress)
        }
        try cancellationToken?.checkCancellation()
        return securityInfo
    }

    // MARK: - Format Detection

    public func detectFormat(archivePath: String) throws -> ExtractionFormat {
        let url = URL(fileURLWithPath: archivePath)
        let ext = url.pathExtension.lowercased()
        let pathLower = archivePath.lowercased()

        if pathLower.hasSuffix(".tar.gz") { return .tarGz }
        if ext == "zip" { return .zip }
        if ext == "zwz" { return .zwz }
        // ZWZ 分卷: .zwz.001
        if pathLower.range(of: #"\.zwz\.\d{3}$"#, options: .regularExpression) != nil {
            return .zwz
        }
        if ext == "rar" { return .rar }
        if ext == "7z" { return .sevenZip }
        if ext == "tgz" { return .tgz }
        if ext == "gz" { return .gz }

        // 通过 magic bytes 判断
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            throw ZwzError.fileNotFound(archivePath)
        }
        defer { fileHandle.closeFile() }
        let magicData = fileHandle.readData(ofLength: 8)
        let magicBytes = [UInt8](magicData)

        if magicBytes.count >= 4 {
            // ZWZ v1/v2 magic and ZWZ v2 split-volume magic
            if Array(magicBytes.prefix(4)) == ZwzFormat.magic ||
               Array(magicBytes.prefix(4)) == ZwzV2Format.magic ||
               Array(magicBytes.prefix(4)) == ZwzV2Format.splitMagic {
                return .zwz
            }
            // ZWZ 分卷 magic: 5A 57 5A 5F 56 4F 4C
            if magicBytes.count >= 7 &&
               magicBytes[0] == 0x5A && magicBytes[1] == 0x57 && magicBytes[2] == 0x5A &&
               magicBytes[3] == 0x5F && magicBytes[4] == 0x56 && magicBytes[5] == 0x4F && magicBytes[6] == 0x4C {
                return .zwz
            }
            if magicBytes[0] == 0x50 && magicBytes[1] == 0x4B && magicBytes[2] == 0x03 && magicBytes[3] == 0x04 {
                return .zip
            }
            if magicBytes[0] == 0x52 && magicBytes[1] == 0x61 && magicBytes[2] == 0x72 && magicBytes[3] == 0x21 {
                return .rar
            }
            if magicBytes[0] == 0x37 && magicBytes[1] == 0x7A && magicBytes[2] == 0xBC && magicBytes[3] == 0xAF {
                return .sevenZip
            }
            if magicBytes[0] == 0x1F && magicBytes[1] == 0x8B {
                return pathLower.hasSuffix(".gz") && !pathLower.hasSuffix(".tar.gz") ? .gz : .tarGz
            }
        }
        throw ZwzError.invalidFormat("Unable to detect archive format for: \(archivePath)")
    }

    // MARK: - Single Entry Extraction (for drag-out)

    /// 将压缩包中的单个条目提取到临时文件，返回文件 URL
    /// - Parameters:
    ///   - archivePath: 压缩包路径
    ///   - entryPath: 条目在压缩包内的路径
    ///   - password: 密码（可选）
    /// - Returns: 提取后的临时文件 URL
    public func extractEntryToTemp(
        archivePath: String,
        entryPath: String,
        password: String? = nil,
        keyProvider: ZwzPrivateKeyProvider? = nil
    ) throws -> URL {
        let format = try detectFormat(archivePath: archivePath)

        // 创建临时目录
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zwz-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        switch format {
        case .zip:
            return try extractZipEntryToTemp(
                archivePath: archivePath,
                entryPath: entryPath,
                tempDir: tempDir,
                password: password
            )
        case .zwz:
            return try ZwzExtractor().extractEntryToTemp(
                archivePath: archivePath,
                entryPath: entryPath,
                password: password,
                keyProvider: keyProvider
            )
        case .tarGz, .tgz:
            return try extractTarGzEntryToTemp(
                archivePath: archivePath,
                entryPath: entryPath,
                tempDir: tempDir
            )
        case .gz:
            // GZ 只有一个文件，直接全解压到临时目录
            try extract(archivePath: archivePath, destinationPath: tempDir.path, password: password)
            if let file = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).first {
                return tempDir.appendingPathComponent(file)
            }
            throw ZwzError.extractionFailed("No file found in GZ archive")
        case .rar, .sevenZip:
            // RAR/7Z 整体解压到临时目录，然后找到对应文件
            try extract(archivePath: archivePath, destinationPath: tempDir.path, password: password)
            let fullPath = tempDir.appendingPathComponent(entryPath)
            if FileManager.default.fileExists(atPath: fullPath.path) {
                return fullPath
            }
            throw ZwzError.extractionFailed("Entry not found after extraction: \(entryPath)")
        }
    }

    private func extractZipEntryToTemp(
        archivePath: String,
        entryPath: String,
        tempDir: URL,
        password: String?
    ) throws -> URL {
        let archiveURL = URL(fileURLWithPath: archivePath)
        let gbkEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))

        let archive: ZIPFoundation.Archive
        do {
            archive = try ZIPFoundation.Archive(url: archiveURL, accessMode: .read, pathEncoding: gbkEncoding)
        } catch {
            archive = try ZIPFoundation.Archive(url: archiveURL, accessMode: .read)
        }

        // 查找匹配的 entry
        for entry in archive {
            // 智能解码路径
            var pathStr = entry.path
            let utf8Path = entry.path(using: .utf8)
            let gbkPath = entry.path(using: gbkEncoding)
            if !utf8Path.isEmpty && !containsReplacementChar(utf8Path) && !isLikelyGarbled(utf8Path) {
                pathStr = utf8Path
            } else if !gbkPath.isEmpty && !isLikelyGarbled(gbkPath) {
                pathStr = gbkPath
            }

            if pathStr == entryPath || pathStr.hasSuffix("/" + entryPath) {
                if pathStr.hasSuffix("/") {
                    // 目录
                    let dirURL = tempDir.appendingPathComponent(pathStr)
                    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                    return dirURL
                }

                let fileURL = tempDir.appendingPathComponent(pathStr)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                // 检查是否加密
                let archiveData = try Data(contentsOf: archiveURL)
                var isEncrypted = false
                do {
                    _ = try ZipContainer.info(container: archiveData)
                } catch let error as ZipError {
                    if case .encryptionNotSupported = error { isEncrypted = true }
                } catch { isEncrypted = true }

                if isEncrypted {
                    // 加密 ZIP 用系统 unzip 提取单个文件
                    guard let unzipPath = findSystemTool(["unzip"]) else {
                        throw ZwzError.unsupportedOperation("Encrypted ZIP requires unzip tool")
                    }
                    var args = ["-o"]
                    if let pwd = password, !pwd.isEmpty {
                        args.append("-P")
                        args.append(pwd)
                    } else {
                        throw ZwzError.passwordRequired("Password required")
                    }
                    args.append(archivePath)
                    args.append("-d")
                    args.append(tempDir.path)
                    try runProcess(executablePath: unzipPath, arguments: args, errorKeyword: "password")
                } else {
                    _ = try archive.extract(entry, to: fileURL)
                }

                return fileURL
            }
        }
        throw ZwzError.extractionFailed("Entry not found: \(entryPath)")
    }

    private func extractTarGzEntryToTemp(
        archivePath: String,
        entryPath: String,
        tempDir: URL
    ) throws -> URL {
        let archiveURL = URL(fileURLWithPath: archivePath)
        let archiveData = try Data(contentsOf: archiveURL)
        let decompressedData = try GzipArchive.unarchive(archive: archiveData)
        let entries = try TarContainer.open(container: decompressedData)

        for entry in entries {
            if entry.info.name == entryPath || entry.info.name.hasSuffix("/" + entryPath) {
                if entry.info.type == .directory {
                    let dirURL = tempDir.appendingPathComponent(entry.info.name)
                    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                    return dirURL
                }
                let fileURL = tempDir.appendingPathComponent(entry.info.name)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if let data = entry.data {
                    try data.write(to: fileURL)
                }
                return fileURL
            }
        }
        throw ZwzError.extractionFailed("Entry not found: \(entryPath)")
    }

    // MARK: - ZIP Extraction

    private func extractZip(
        archivePath: String,
        destinationPath: String,
        password: String?,
        progress: ProgressHandler?
    ) throws {
        let archiveURL = URL(fileURLWithPath: archivePath)
        let destURL = URL(fileURLWithPath: destinationPath)

        // 先读取数据用于后续检查
        let archiveData = try Data(contentsOf: archiveURL)

        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)

        // GBK/GB18030 编码（解决 Windows 下创建的 ZIP 中文乱码问题）
        let gbkEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))

        let archive: ZIPFoundation.Archive
        do {
            archive = try ZIPFoundation.Archive(url: archiveURL, accessMode: .read, pathEncoding: gbkEncoding)
        } catch {
            do {
                archive = try ZIPFoundation.Archive(url: archiveURL, accessMode: .read)
            } catch {
                throw ZwzError.extractionFailed("Failed to read ZIP archive: \(error.localizedDescription)")
            }
        }

        // 检查是否有加密条目
        // 直接解析 ZIP central directory 检查 general purpose bit flag bit 0 (encrypted)
        var hasEncryptedEntry = false
        do {
            let zipInfo = try ZipContainer.info(container: archiveData)
            // SWCompression 不直接暴露加密标志，但如果它抛出 encryptionNotSupported 错误
            // 说明 ZIP 是加密的
            _ = zipInfo
        } catch let error as ZipError {
            if case .encryptionNotSupported = error {
                hasEncryptedEntry = true
            }
        } catch {
            hasEncryptedEntry = true
        }

        if hasEncryptedEntry {
            // ZIPFoundation 不支持解压加密 ZIP，使用系统 unzip
            guard let unzipPath = findSystemTool(["unzip"]) else {
                throw ZwzError.unsupportedOperation(
                    "Encrypted ZIP requires 'unzip' tool. macOS has it built-in."
                )
            }

            var arguments = ["-o"]  // overwrite
            if let pwd = password, !pwd.isEmpty {
                arguments.append("-P")
                arguments.append(pwd)
            } else {
                throw ZwzError.passwordRequired("This ZIP archive is password-protected")
            }
            arguments.append(archivePath)
            arguments.append("-d")
            arguments.append(destinationPath)

            try runProcess(executablePath: unzipPath, arguments: arguments, errorKeyword: "password")
            progress?(1.0)
            return
        }

        // 非加密 ZIP，用 ZIPFoundation 解压
        let totalEntries = archive.filter { !$0.path.hasSuffix("/") }.count
        var processedEntries = 0

        for entry in archive {
            // 智能检测文件名编码，解决中文乱码
            var pathStr = entry.path
            let utf8Path = entry.path(using: .utf8)
            let gbkPath = entry.path(using: gbkEncoding)

            if !utf8Path.isEmpty && !containsReplacementChar(utf8Path) && !isLikelyGarbled(utf8Path) {
                pathStr = utf8Path
            } else if !gbkPath.isEmpty && !isLikelyGarbled(gbkPath) {
                pathStr = gbkPath
            }

            if pathStr.hasSuffix("/") {
                let dirPath = destURL.appendingPathComponent(pathStr)
                try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)
                continue
            }

            let entryURL = destURL.appendingPathComponent(pathStr)
            try FileManager.default.createDirectory(
                at: entryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            _ = try archive.extract(entry, to: entryURL)

            processedEntries += 1
            let progressValue = totalEntries > 0 ? Double(processedEntries) / Double(totalEntries) : 1.0
            progress?(min(progressValue, 1.0))
        }

        progress?(1.0)
    }

    // MARK: - TAR.GZ / TGZ Extraction

    private func extractTarGz(
        archivePath: String,
        destinationPath: String,
        progress: ProgressHandler?
    ) throws {
        let archiveURL = URL(fileURLWithPath: archivePath)
        let destURL = URL(fileURLWithPath: destinationPath)
        let archiveData = try Data(contentsOf: archiveURL)

        // 先 gzip 解压
        let decompressedData = try GzipArchive.unarchive(archive: archiveData)
        // 再 tar 解压
        try extractTar(data: decompressedData, destinationURL: destURL, progress: progress)
    }

    // MARK: - GZ Extraction

    private func extractGz(
        archivePath: String,
        destinationPath: String,
        progress: ProgressHandler?
    ) throws {
        let archiveURL = URL(fileURLWithPath: archivePath)
        let destURL = URL(fileURLWithPath: destinationPath)
        let archiveData = try Data(contentsOf: archiveURL)
        let decompressedData = try GzipArchive.unarchive(archive: archiveData)

        let originalName = archiveURL.lastPathComponent
        let outputName = originalName.hasSuffix(".gz")
            ? String(originalName.dropLast(3))
            : originalName + ".decompressed"

        let outputFileURL = destURL.appendingPathComponent(outputName)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try decompressedData.write(to: outputFileURL)
        progress?(1.0)
    }

    // MARK: - TAR Extraction

    private func extractTar(
        data: Data,
        destinationURL: URL,
        progress: ProgressHandler?
    ) throws {
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let entries = try TarContainer.open(container: data)
        let totalEntries = entries.count
        var processedEntries = 0

        for entry in entries {
            let entryURL = destinationURL.appendingPathComponent(entry.info.name)

            switch entry.info.type {
            case .directory:
                try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
            case .regular, .contiguous:
                try FileManager.default.createDirectory(
                    at: entryURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if let fileData = entry.data {
                    try fileData.write(to: entryURL)
                }
            default:
                break
            }

            if let permissions = entry.info.permissions {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: permissions.rawValue],
                    ofItemAtPath: entryURL.path
                )
            }

            processedEntries += 1
            let progressValue = totalEntries > 0 ? Double(processedEntries) / Double(totalEntries) : 1.0
            progress?(min(progressValue, 1.0))
        }

        progress?(1.0)
    }

    // MARK: - RAR Extraction

    private func extractRar(
        archivePath: String,
        destinationPath: String,
        password: String?,
        progress: ProgressHandler?
    ) throws {
        guard let toolPath = findSystemTool(["unrar", "unar"]) else {
            throw ZwzError.unsupportedOperation(
                "RAR extraction requires 'unrar' or 'unar'. Install via: brew install unrar"
            )
        }

        try FileManager.default.createDirectory(atPath: destinationPath, withIntermediateDirectories: true)

        let toolName = (toolPath as NSString).lastPathComponent
        var arguments: [String] = []

        if toolName == "unrar" {
            arguments = ["x", "-o+"]
            if let pwd = password, !pwd.isEmpty {
                arguments.append("-p\(pwd)")
            } else {
                arguments.append("-p-")
            }
            arguments.append(archivePath)
            arguments.append(destinationPath + "/")
        } else {
            arguments = ["-f"]
            if let pwd = password, !pwd.isEmpty {
                arguments.append("-p")
                arguments.append(pwd)
            }
            arguments.append(archivePath)
            arguments.append("-o")
            arguments.append(destinationPath)
        }

        try runProcess(executablePath: toolPath, arguments: arguments, errorKeyword: "password")
        progress?(1.0)
    }

    // MARK: - 7Z Extraction

    private func extract7z(
        archivePath: String,
        destinationPath: String,
        password: String?,
        progress: ProgressHandler?
    ) throws {
        // 先尝试用 SWCompression（纯 Swift）
        let archiveURL = URL(fileURLWithPath: archivePath)
        let destURL = URL(fileURLWithPath: destinationPath)

        do {
            let archiveData = try Data(contentsOf: archiveURL)
            let entries = try SevenZipContainer.open(container: archiveData)
            try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)

            let totalEntries = entries.count
            var processedEntries = 0

            for entry in entries {
                let entryURL = destURL.appendingPathComponent(entry.info.name)

                switch entry.info.type {
                case .directory:
                    try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
                case .regular, .contiguous:
                    try FileManager.default.createDirectory(
                        at: entryURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if let fileData = entry.data {
                        try fileData.write(to: entryURL)
                    }
                default:
                    break
                }

                processedEntries += 1
                let progressValue = totalEntries > 0 ? Double(processedEntries) / Double(totalEntries) : 1.0
                progress?(min(progressValue, 1.0))
            }

            progress?(1.0)
        } catch {
            // SWCompression 失败，尝试系统 7z
            guard let toolPath = findSystemTool(["7z", "7za", "7zr"]) else {
                throw ZwzError.unsupportedOperation(
                    "7z extraction failed and no system 7z found. Install via: brew install p7zip"
                )
            }

            try FileManager.default.createDirectory(atPath: destinationPath, withIntermediateDirectories: true)

            var arguments = ["x", "-y", "-o" + destinationPath]
            if let pwd = password, !pwd.isEmpty {
                arguments.append("-p\(pwd)")
            } else {
                arguments.append("-p")
            }
            arguments.append(archivePath)

            try runProcess(executablePath: toolPath, arguments: arguments, errorKeyword: "password")
            progress?(1.0)
        }
    }

    // MARK: - Helpers

    private func runProcess(executablePath: String, arguments: [String], errorKeyword: String) throws {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            if output.lowercased().contains(errorKeyword) || output.lowercased().contains("encrypted") {
                throw ZwzError.wrongPassword("Wrong password or password required")
            }
            throw ZwzError.extractionFailed("Process failed: \(output)")
        }
    }

    private func findSystemTool(_ names: [String]) -> String? {
        for name in names {
            for dir in ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"] {
                let path = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    /// 检测字符串是否包含 replacement 字符
    private func containsReplacementChar(_ str: String) -> Bool {
        return str.contains("\u{FFFD}")
    }

    /// 检测字符串是否可能是乱码
    private func isLikelyGarbled(_ str: String) -> Bool {
        let garbledChars: Set<Character> = ["Σ", "µ", "σ", "Φ", "τ", "¢", "§", "¿", "¡", "«", "»", "Â", "Ã", "Ä", "Å", "Æ", "Ç", "È", "É", "Ê", "Ë", "Ì", "Í", "Î", "Ï", "Ð", "Ñ", "Ò", "Ó", "Ô", "Õ", "Ö", "Ø", "Ù", "Ú", "Û", "Ü", "Ý", "Þ", "ß", "à", "á", "â", "ã", "ä", "å", "æ", "ç", "è", "é", "ê", "ë", "ì", "í", "î", "ï", "ð", "ñ", "ò", "ó", "ô", "õ", "ö", "ø", "ù", "ú", "û", "ü", "ý", "þ", "ÿ"]
        var garbledCount = 0
        for ch in str {
            if garbledChars.contains(ch) {
                garbledCount += 1
            }
        }
        return garbledCount > 0 && Double(garbledCount) / Double(max(str.count, 1)) > 0.1
    }
}
