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
               Array(magicBytes.prefix(4)) == [0x5A, 0x57, 0x5A, 0x33] ||
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
        keyProvider: ZwzPrivateKeyProvider? = nil,
        maximumBytes: Int64? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws -> URL {
        try cancellationToken?.checkCancellation()
        if let maximumBytes, maximumBytes < 0 {
            throw ZwzError.extractionFailed("Invalid single-entry extraction byte limit")
        }
        let format = try detectFormat(archivePath: archivePath)

        // 创建临时目录
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zwz-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        do {
            switch format {
            case .zip:
                return try extractZipEntryToTemp(
                    archivePath: archivePath,
                    entryPath: entryPath,
                    tempDir: tempDir,
                    password: password,
                    maximumBytes: maximumBytes,
                    cancellationToken: cancellationToken
                )
            case .zwz:
                // ZWZ owns a separate temporary directory.
                try? FileManager.default.removeItem(at: tempDir)
                return try ZwzExtractor().extractEntryToTemp(
                    archivePath: archivePath,
                    entryPath: entryPath,
                    password: password,
                    keyProvider: keyProvider,
                    maximumBytes: maximumBytes,
                    cancellationToken: cancellationToken
                )
            case .tarGz, .tgz:
                return try extractTarGzEntryToTemp(
                    archivePath: archivePath,
                    entryPath: entryPath,
                    tempDir: tempDir,
                    maximumBytes: maximumBytes,
                    cancellationToken: cancellationToken
                )
            case .gz:
                return try extractGzEntryToTemp(
                    archivePath: archivePath,
                    entryPath: entryPath,
                    tempDir: tempDir,
                    maximumBytes: maximumBytes,
                    cancellationToken: cancellationToken
                )
            case .rar:
                return try extractRarEntryToTemp(
                    archivePath: archivePath,
                    entryPath: entryPath,
                    tempDir: tempDir,
                    password: password,
                    maximumBytes: maximumBytes,
                    cancellationToken: cancellationToken
                )
            case .sevenZip:
                return try extract7zEntryToTemp(
                    archivePath: archivePath,
                    entryPath: entryPath,
                    tempDir: tempDir,
                    password: password,
                    maximumBytes: maximumBytes,
                    cancellationToken: cancellationToken
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }

    private func extractZipEntryToTemp(
        archivePath: String,
        entryPath: String,
        tempDir: URL,
        password: String?,
        maximumBytes: Int64?,
        cancellationToken: CancellationToken?
    ) throws -> URL {
        let fileURL = try validatedSingleEntryURL(entryPath, in: tempDir)
        try cancellationToken?.checkCancellation()
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

        let matches = archive.filter { decodedZipPath($0, gbkEncoding: gbkEncoding) == entryPath }
        if matches.count > 1 {
            throw ZwzError.extractionFailed("Duplicate archive entry: \(entryPath)")
        }
        if let entry = matches.first {
            guard entry.type != .symlink else {
                throw ZwzError.extractionFailed("Symbolic links cannot be extracted for preview")
            }
            if entry.type == .directory {
                try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
                return fileURL
            }
            try enforceByteLimit(entry.uncompressedSize, maximumBytes: maximumBytes)
            try streamZipEntry(
                entry,
                from: archive,
                to: fileURL,
                maximumBytes: maximumBytes,
                cancellationToken: cancellationToken
            )
            return try verifySingleEntryOutput(fileURL, in: tempDir, maximumBytes: maximumBytes)
        }

        // ZIPFoundation intentionally omits encrypted entries. List with the
        // system tool, require one exact name, then stream only that entry.
        guard let unzipPath = findSystemTool(["unzip"]) else {
            throw ZwzError.extractionFailed("Entry not found: \(entryPath)")
        }
        guard !entryPath.hasPrefix("-"),
              !entryPath.contains(where: \.isNewline) else {
            throw ZwzError.unsupportedOperation("This encrypted ZIP entry name cannot be previewed safely")
        }
        let names = try runProcessCapturing(
            executablePath: unzipPath,
            arguments: ["-Z1", archivePath],
            errorKeyword: "password",
            cancellationToken: cancellationToken
        ).split(whereSeparator: \.isNewline).map(String.init)
        guard names.filter({ $0 == entryPath }).count == 1 else {
            throw ZwzError.extractionFailed("Entry is missing or duplicated: \(entryPath)")
        }
        guard let password, !password.isEmpty else {
            throw ZwzError.passwordRequired("Password required")
        }
        let escapedEntry = escapedUnzipPattern(entryPath)
        let listing = try runProcessCapturing(
            executablePath: unzipPath,
            arguments: ["-Z", "-l", archivePath, escapedEntry],
            errorKeyword: "password",
            cancellationToken: cancellationToken
        )
        guard !listing.split(whereSeparator: \.isNewline).contains(where: { $0.first == "l" }) else {
            throw ZwzError.extractionFailed("Symbolic links cannot be extracted for preview")
        }
        try runProcessStreamingOutput(
            executablePath: unzipPath,
            arguments: ["-p", "-P", password, archivePath, escapedEntry],
            outputURL: fileURL,
            maximumBytes: maximumBytes,
            cancellationToken: cancellationToken,
            errorKeyword: "password"
        )
        return try verifySingleEntryOutput(fileURL, in: tempDir, maximumBytes: maximumBytes)
    }

    private func extractTarGzEntryToTemp(
        archivePath: String,
        entryPath: String,
        tempDir: URL,
        maximumBytes: Int64?,
        cancellationToken: CancellationToken?
    ) throws -> URL {
        let outputURL = try validatedSingleEntryURL(entryPath, in: tempDir)
        guard !entryPath.hasPrefix("-"),
              !entryPath.contains(where: \.isNewline) else {
            throw ZwzError.unsupportedOperation("This TAR entry name cannot be previewed safely")
        }
        guard let tarPath = findSystemTool(["tar"]) else {
            throw ZwzError.unsupportedOperation("Safe single-entry TAR preview requires the system tar tool")
        }
        let names = try runProcessCapturing(
            executablePath: tarPath,
            arguments: ["-tzf", archivePath],
            errorKeyword: "password",
            cancellationToken: cancellationToken
        ).split(whereSeparator: \.isNewline).map(String.init)
        guard names.filter({ $0 == entryPath }).count == 1 else {
            throw ZwzError.extractionFailed("Entry is missing or duplicated: \(entryPath)")
        }
        let verboseListing = try runProcessCapturing(
            executablePath: tarPath,
            arguments: ["-tvzf", archivePath, entryPath],
            errorKeyword: "password",
            cancellationToken: cancellationToken
        )
        guard let type = verboseListing.first, type == "-" else {
            throw ZwzError.extractionFailed("Archive links and special files cannot be extracted for preview")
        }
        try runProcessStreamingOutput(
            executablePath: tarPath,
            arguments: ["-xOzf", archivePath, entryPath],
            outputURL: outputURL,
            maximumBytes: maximumBytes,
            cancellationToken: cancellationToken,
            errorKeyword: "password"
        )
        return try verifySingleEntryOutput(outputURL, in: tempDir, maximumBytes: maximumBytes)
    }

    private func extractGzEntryToTemp(
        archivePath: String,
        entryPath: String,
        tempDir: URL,
        maximumBytes: Int64?,
        cancellationToken: CancellationToken?
    ) throws -> URL {
        guard let gzipPath = findSystemTool(["gzip"]) else {
            throw ZwzError.unsupportedOperation("Safe GZIP preview requires the system gzip tool")
        }
        let outputURL = try validatedSingleEntryURL(entryPath, in: tempDir)
        try runProcessStreamingOutput(
            executablePath: gzipPath,
            arguments: ["-dc", archivePath],
            outputURL: outputURL,
            maximumBytes: maximumBytes,
            cancellationToken: cancellationToken,
            errorKeyword: "password"
        )
        return try verifySingleEntryOutput(outputURL, in: tempDir, maximumBytes: maximumBytes)
    }

    private func extractRarEntryToTemp(
        archivePath: String,
        entryPath: String,
        tempDir: URL,
        password: String?,
        maximumBytes: Int64?,
        cancellationToken: CancellationToken?
    ) throws -> URL {
        guard !entryPath.hasPrefix("-"),
              !entryPath.contains(where: { "*?[".contains($0) || $0.isNewline }) else {
            throw ZwzError.unsupportedOperation("This RAR entry name cannot be previewed safely")
        }
        guard let toolPath = findSystemTool(["unrar"]) else {
            throw ZwzError.unsupportedOperation("Safe single-entry RAR preview requires unrar")
        }
        let passwordArgument = password.flatMap { $0.isEmpty ? nil : "-p\($0)" } ?? "-p-"
        let listing = try runProcessCapturing(
            executablePath: toolPath,
            arguments: ["lb", passwordArgument, archivePath],
            errorKeyword: "password",
            cancellationToken: cancellationToken
        )
        let names = listing.split(whereSeparator: \.isNewline).map(String.init)
        guard names.filter({ $0 == entryPath }).count == 1 else {
            throw ZwzError.extractionFailed("Entry is missing or duplicated: \(entryPath)")
        }
        let technicalListing = try runProcessCapturing(
            executablePath: toolPath,
            arguments: ["lt", "-idq", passwordArgument, archivePath, entryPath],
            errorKeyword: "password",
            cancellationToken: cancellationToken
        ).lowercased()
        guard !technicalListing.contains("symbolic link"),
              !technicalListing.contains("hard link") else {
            throw ZwzError.extractionFailed("Archive links cannot be extracted for preview")
        }

        let outputURL = try validatedSingleEntryURL(entryPath, in: tempDir)
        try runProcessStreamingOutput(
            executablePath: toolPath,
            arguments: ["p", "-inul", passwordArgument, archivePath, entryPath],
            outputURL: outputURL,
            maximumBytes: maximumBytes,
            cancellationToken: cancellationToken,
            errorKeyword: "password"
        )
        return try verifySingleEntryOutput(outputURL, in: tempDir, maximumBytes: maximumBytes)
    }

    private func extract7zEntryToTemp(
        archivePath: String,
        entryPath: String,
        tempDir: URL,
        password: String?,
        maximumBytes: Int64?,
        cancellationToken: CancellationToken?
    ) throws -> URL {
        guard !entryPath.hasPrefix("-"),
              !entryPath.contains(where: \.isNewline) else {
            throw ZwzError.unsupportedOperation("This 7Z entry name cannot be previewed safely")
        }
        guard let toolPath = findSystemTool(["7z", "7za", "7zr"]) else {
            throw ZwzError.unsupportedOperation("Safe single-entry 7Z preview requires 7z")
        }
        var passwordArguments: [String] = []
        if let password, !password.isEmpty { passwordArguments = ["-p\(password)"] }
        let listing = try runProcessCapturing(
            executablePath: toolPath,
            arguments: ["l", "-slt", "-ba"] + passwordArguments + [archivePath],
            errorKeyword: "password",
            cancellationToken: cancellationToken
        )
        let names = listing.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let prefix = "Path = "
            return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
        }
        guard names.filter({ $0 == entryPath }).count == 1 else {
            throw ZwzError.extractionFailed("Entry is missing or duplicated: \(entryPath)")
        }
        let selectedBlock = listing.components(separatedBy: "\n\n").first(where: {
            $0.components(separatedBy: .newlines).contains("Path = \(entryPath)")
        }) ?? ""
        guard !selectedBlock.contains("Symbolic Link ="),
              !selectedBlock.contains("Hard Link =") else {
            throw ZwzError.extractionFailed("Archive links cannot be extracted for preview")
        }

        let outputURL = try validatedSingleEntryURL(entryPath, in: tempDir)
        try runProcessStreamingOutput(
            executablePath: toolPath,
            arguments: ["x", "-so", "-y", "-spd", "-bd"] + passwordArguments + [archivePath, entryPath],
            outputURL: outputURL,
            maximumBytes: maximumBytes,
            cancellationToken: cancellationToken,
            errorKeyword: "password"
        )
        return try verifySingleEntryOutput(outputURL, in: tempDir, maximumBytes: maximumBytes)
    }

    private func decodedZipPath(
        _ entry: ZIPFoundation.Entry,
        gbkEncoding: String.Encoding
    ) -> String {
        let utf8Path = entry.path(using: .utf8)
        if !utf8Path.isEmpty,
           !containsReplacementChar(utf8Path),
           !isLikelyGarbled(utf8Path) {
            return utf8Path
        }
        let gbkPath = entry.path(using: gbkEncoding)
        if !gbkPath.isEmpty, !isLikelyGarbled(gbkPath) { return gbkPath }
        return entry.path
    }

    private func streamZipEntry(
        _ entry: ZIPFoundation.Entry,
        from archive: ZIPFoundation.Archive,
        to outputURL: URL,
        maximumBytes: Int64?,
        cancellationToken: CancellationToken?
    ) throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw ZwzError.extractionFailed("Could not create single-entry output")
        }
        do {
            let handle = try FileHandle(forWritingTo: outputURL)
            defer { try? handle.close() }
            var written: UInt64 = 0
            _ = try archive.extract(entry) { chunk in
                try cancellationToken?.checkCancellation()
                let result = written.addingReportingOverflow(UInt64(chunk.count))
                guard !result.overflow else {
                    throw ZwzError.extractionFailed("Single-entry extraction size overflow")
                }
                try enforceByteLimit(result.partialValue, maximumBytes: maximumBytes)
                try handle.write(contentsOf: chunk)
                written = result.partialValue
            }
            try cancellationToken?.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private func validatedSingleEntryURL(_ entryPath: String, in tempDir: URL) throws -> URL {
        let root = tempDir.standardizedFileURL
        let output = try ZwzV2PathValidator.validateExtractionPath(entryPath, destination: root)
        guard output.pathComponents.starts(with: root.pathComponents),
              output.pathComponents.count > root.pathComponents.count else {
            throw ZwzV2Error.unsafePath(entryPath)
        }

        var current = root
        for component in output.pathComponents.dropFirst(root.pathComponents.count) {
            current.appendPathComponent(component)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw ZwzV2Error.unsafePath(entryPath)
            }
        }
        return output
    }

    @discardableResult
    private func verifySingleEntryOutput(
        _ outputURL: URL,
        in tempDir: URL,
        maximumBytes: Int64?
    ) throws -> URL {
        let root = tempDir.standardizedFileURL
        let output = outputURL.standardizedFileURL
        guard output.pathComponents.starts(with: root.pathComponents),
              output.pathComponents.count > root.pathComponents.count else {
            throw ZwzV2Error.unsafePath(outputURL.path)
        }
        let values = try output.resourceValues(forKeys: [
            .fileSizeKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        if values.isDirectory == true { return output }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ZwzV2Error.unsafePath(outputURL.path)
        }
        try enforceByteLimit(UInt64(values.fileSize ?? 0), maximumBytes: maximumBytes)
        return output
    }

    private func enforceByteLimit(_ size: UInt64, maximumBytes: Int64?) throws {
        guard let maximumBytes else { return }
        guard size <= UInt64(maximumBytes) else {
            throw ZwzError.extractionFailed("Archive entry exceeds the extraction byte limit")
        }
    }

    private func escapedUnzipPattern(_ path: String) -> String {
        var result = ""
        for character in path {
            if "*?[]\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    private func runProcessCapturing(
        executablePath: String,
        arguments: [String],
        errorKeyword: String,
        cancellationToken: CancellationToken?
    ) throws -> String {
        try cancellationToken?.checkCancellation()
        let captureLimit = 16 * 1024 * 1024
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(".zwz-command-output-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: captureURL.path, contents: nil) else {
            throw ZwzError.extractionFailed("Could not create command output file")
        }
        defer { try? FileManager.default.removeItem(at: captureURL) }
        let captureHandle = try FileHandle(forWritingTo: captureURL)
        defer { try? captureHandle.close() }

        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = captureHandle
        process.standardError = captureHandle
        try process.run()
        var interruptedError: Error?
        while process.isRunning {
            if cancellationToken?.isCancelled == true {
                interruptedError = ZwzError.operationCancelled
                process.terminate()
                break
            }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: captureURL.path),
               let number = attributes[.size] as? NSNumber,
               number.intValue > captureLimit {
                interruptedError = ZwzError.extractionFailed("Archive listing exceeds the safe output limit")
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        process.waitUntilExit()
        if let interruptedError { throw interruptedError }
        try cancellationToken?.checkCancellation()
        try captureHandle.synchronize()
        let readHandle = try FileHandle(forReadingFrom: captureURL)
        defer { try? readHandle.close() }
        let data = try readHandle.read(upToCount: captureLimit + 1) ?? Data()
        guard data.count <= captureLimit else {
            throw ZwzError.extractionFailed("Archive listing exceeds the safe output limit")
        }
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            if output.lowercased().contains(errorKeyword) || output.lowercased().contains("encrypted") {
                throw ZwzError.wrongPassword("Wrong password or password required")
            }
            throw ZwzError.extractionFailed("Process failed: \(output)")
        }
        return output
    }

    private func runProcessStreamingOutput(
        executablePath: String,
        arguments: [String],
        outputURL: URL,
        maximumBytes: Int64?,
        cancellationToken: CancellationToken?,
        errorKeyword: String
    ) throws {
        try cancellationToken?.checkCancellation()
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw ZwzError.extractionFailed("Could not create single-entry output")
        }

        let errorURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".zwz-process-error-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorURL) }

        do {
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            defer {
                try? outputHandle.close()
                try? errorHandle.close()
            }
            let process = Foundation.Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputHandle
            process.standardError = errorHandle
            try process.run()

            var interruptedError: Error?
            while process.isRunning {
                if cancellationToken?.isCancelled == true {
                    interruptedError = ZwzError.operationCancelled
                    process.terminate()
                    break
                }
                if let maximumBytes,
                   let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
                   let number = attributes[.size] as? NSNumber,
                   number.int64Value > maximumBytes {
                    interruptedError = ZwzError.extractionFailed("Archive entry exceeds the extraction byte limit")
                    process.terminate()
                    break
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            process.waitUntilExit()
            if let interruptedError { throw interruptedError }
            try cancellationToken?.checkCancellation()
            if process.terminationStatus != 0 {
                try? errorHandle.synchronize()
                let readHandle = try FileHandle(forReadingFrom: errorURL)
                defer { try? readHandle.close() }
                let errorData = try readHandle.read(upToCount: 64 * 1024) ?? Data()
                let output = String(data: errorData, encoding: .utf8) ?? ""
                if output.lowercased().contains(errorKeyword) || output.lowercased().contains("encrypted") {
                    throw ZwzError.wrongPassword("Wrong password or password required")
                }
                throw ZwzError.extractionFailed("Process failed: \(output)")
            }
            try enforceByteLimit(
                UInt64((try outputURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0),
                maximumBytes: maximumBytes
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
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
