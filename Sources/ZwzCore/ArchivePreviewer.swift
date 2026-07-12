import Foundation
import ZIPFoundation
import SWCompression

/// 压缩包内容预览器
public class ArchivePreviewer {

    public init() {}

    /// 预览压缩包内容（不解压）
    public func preview(
        archivePath: String,
        password: String? = nil,
        keyProvider: ZwzPrivateKeyProvider? = nil
    ) throws -> [ArchiveEntry] {
        let extractor = ArchiveExtractor()
        let format = try extractor.detectFormat(archivePath: archivePath)

        switch format {
        case .zip:
            return try previewZip(archivePath: archivePath)
        case .zwz:
            return try previewZwz(archivePath: archivePath, password: password, keyProvider: keyProvider)
        case .tarGz, .tgz:
            return try previewTarGz(archivePath: archivePath)
        case .gz:
            return try previewGz(archivePath: archivePath)
        case .rar:
            return try previewRar(archivePath: archivePath)
        case .sevenZip:
            return try preview7z(archivePath: archivePath)
        }
    }

    // MARK: - ZIP Preview

    private func previewZip(archivePath: String) throws -> [ArchiveEntry] {
        let archiveURL = URL(fileURLWithPath: archivePath)

        // GBK/GB18030 编码（解决 Windows 下创建的 ZIP 中文乱码问题）
        let gbkEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))

        // 先尝试 GBK 编码打开
        let archive: ZIPFoundation.Archive
        do {
            archive = try ZIPFoundation.Archive(url: archiveURL, accessMode: .read, pathEncoding: gbkEncoding)
        } catch {
            archive = try ZIPFoundation.Archive(url: archiveURL, accessMode: .read)
        }

        var entries: [ArchiveEntry] = []
        for entry in archive {
            // 智能检测文件名编码：
            // 1. 先用 UTF-8 解码（很多工具用 UTF-8 但不设标志位）
            // 2. 如果 UTF-8 解码失败或结果乱码，用 GBK/GB18030 解码
            var pathStr = entry.path  // 默认（CP437 或 UTF-8，取决于标志位）

            // 尝试用 UTF-8 重新解码
            let utf8Path = entry.path(using: .utf8)
            // 尝试用 GBK 重新解码
            let gbkPath = entry.path(using: gbkEncoding)

            // 选择最"干净"的结果
            if !utf8Path.isEmpty && !isLikelyGarbled(utf8Path) && !containsReplacementChar(utf8Path) {
                pathStr = utf8Path
            } else if !gbkPath.isEmpty && !isLikelyGarbled(gbkPath) {
                pathStr = gbkPath
            }

            let isDir = pathStr.hasSuffix("/")
            let name = (pathStr as NSString).lastPathComponent
            entries.append(ArchiveEntry(
                name: name,
                path: pathStr,
                size: isDir ? 0 : Int64(entry.uncompressedSize),
                isDirectory: isDir,
                modifiedDate: entry.fileAttributes[.modificationDate] as? Date
            ))
        }
        return entries
    }

    /// 检测字符串是否包含 replacement 字符（UTF-8 解码失败的标志）
    private func containsReplacementChar(_ str: String) -> Bool {
        return str.contains("\u{FFFD}")
    }

    // MARK: - ZWZ Preview

    private func previewZwz(
        archivePath: String,
        password: String?,
        keyProvider: ZwzPrivateKeyProvider?
    ) throws -> [ArchiveEntry] {
        let zwzExtractor = ZwzExtractor()
        return try zwzExtractor.listEntries(
            archivePath: archivePath,
            password: password,
            keyProvider: keyProvider
        ).entries
    }

    /// 检测字符串是否可能是乱码
    private func isLikelyGarbled(_ str: String) -> Bool {
        // CP437 乱码特征：包含大量拉丁扩展字符（如 Σ, µ, σ, Φ 等）
        let garbledChars: Set<Character> = ["Σ", "µ", "σ", "Φ", "τ", "¢", "§", "¿", "¡", "«", "»", "Â", "Ã", "Ä", "Å", "Æ", "Ç", "È", "É", "Ê", "Ë", "Ì", "Í", "Î", "Ï", "Ð", "Ñ", "Ò", "Ó", "Ô", "Õ", "Ö", "Ø", "Ù", "Ú", "Û", "Ü", "Ý", "Þ", "ß", "à", "á", "â", "ã", "ä", "å", "æ", "ç", "è", "é", "ê", "ë", "ì", "í", "î", "ï", "ð", "ñ", "ò", "ó", "ô", "õ", "ö", "ø", "ù", "ú", "û", "ü", "ý", "þ", "ÿ"]
        var garbledCount = 0
        for ch in str {
            if garbledChars.contains(ch) {
                garbledCount += 1
            }
        }
        // 如果超过 10% 的字符是乱码特征字符，判定为乱码
        return garbledCount > 0 && Double(garbledCount) / Double(max(str.count, 1)) > 0.1
    }

    // MARK: - TAR.GZ Preview

    private func previewTarGz(archivePath: String) throws -> [ArchiveEntry] {
        let archiveURL = URL(fileURLWithPath: archivePath)
        let archiveData = try Data(contentsOf: archiveURL)
        let decompressedData = try GzipArchive.unarchive(archive: archiveData)
        let entries = try TarContainer.info(container: decompressedData)

        return entries.map { info in
            ArchiveEntry(
                name: (info.name as NSString).lastPathComponent,
                path: info.name,
                size: Int64(info.size ?? 0),
                isDirectory: info.type == .directory,
                modifiedDate: info.modificationTime
            )
        }
    }

    // MARK: - GZ Preview

    private func previewGz(archivePath: String) throws -> [ArchiveEntry] {
        let archiveURL = URL(fileURLWithPath: archivePath)
        let archiveData = try Data(contentsOf: archiveURL)
        let decompressedData = try GzipArchive.unarchive(archive: archiveData)

        let originalName = archiveURL.lastPathComponent
        let outputName = originalName.hasSuffix(".gz")
            ? String(originalName.dropLast(3))
            : originalName + ".decompressed"

        return [ArchiveEntry(
            name: outputName,
            path: outputName,
            size: Int64(decompressedData.count),
            isDirectory: false,
            modifiedDate: nil
        )]
    }

    // MARK: - RAR Preview

    private func previewRar(archivePath: String) throws -> [ArchiveEntry] {
        guard let lsarPath = findTool(["lsar"]) else {
            return try previewRarWithBSDTar(archivePath: archivePath)
        }

        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: lsarPath)
        process.arguments = ["-j", archivePath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
              let lsarContents = json["lsarContents"] as? [[String: Any]] else {
            return [ArchiveEntry(
                name: URL(fileURLWithPath: archivePath).lastPathComponent,
                path: "",
                size: 0,
                isDirectory: false,
                modifiedDate: nil
            )]
        }

        var entries: [ArchiveEntry] = []
        for item in lsarContents {
            let name = item["XADFileName"] as? String ?? "unknown"
            let size = item["XADFileSize"] as? Int64 ?? 0
            let isDir = item["XADIsDirectory"] as? Bool ?? false
            entries.append(ArchiveEntry(
                name: (name as NSString).lastPathComponent,
                path: name,
                size: size,
                isDirectory: isDir,
                modifiedDate: nil
            ))
        }
        return entries
    }

    private func previewRarWithBSDTar(archivePath: String) throws -> [ArchiveEntry] {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-tvf", archivePath]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "Unable to read RAR archive"
            throw NSError(
                domain: "ZwzCore.RAR",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 8, whereSeparator: { $0.isWhitespace })
            guard fields.count == 9, let size = Int64(fields[4]) else { return nil }
            let path = String(fields[8])
            let isDirectory = fields[0].first == "d"
            return ArchiveEntry(
                name: (path as NSString).lastPathComponent,
                path: path,
                size: isDirectory ? 0 : size,
                isDirectory: isDirectory,
                modifiedDate: nil
            )
        }
    }

    // MARK: - 7Z Preview

    private func preview7z(archivePath: String) throws -> [ArchiveEntry] {
        // 先尝试用 SWCompression
        let archiveURL = URL(fileURLWithPath: archivePath)
        let archiveData = try Data(contentsOf: archiveURL)

        // 用 SWCompression 获取信息
        let infos = try SevenZipContainer.info(container: archiveData)
        return infos.map { info in
            ArchiveEntry(
                name: (info.name as NSString).lastPathComponent,
                path: info.name,
                size: Int64(info.size ?? 0),
                isDirectory: info.type == .directory,
                modifiedDate: info.modificationTime
            )
        }
    }

    // MARK: - Helpers

    private func findTool(_ names: [String]) -> String? {
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
}
