import CoreFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ArchiveEntryPreviewSettings {
    static let sidebarEnabledKey = "zwz_preview_sidebar_enabled"
    static let triggerKey = "zwz_preview_sidebar_trigger"
    static let sidebarWidthKey = "zwz_archive_preview_sidebar_width"
    static let minimumSidebarWidth = 180.0
    static let maximumSidebarWidth = 260.0
    static let defaultSidebarWidth = 180.0
}

enum ArchiveEntryPreviewKind: Equatable, Sendable {
    case image
    case video
    case text
    case unsupported
}

struct ArchiveEntryTextPreviewResult: Equatable, Sendable {
    let text: String
    let encodingName: String
    let isTruncated: Bool
}

enum ArchiveEntryPreviewSupportError: LocalizedError, Equatable {
    case invalidMaximumBytes
    case unsupportedTextEncoding
    case extractionLimitExceeded
    case invalidExtractedFile
    case invalidImage
    case imageFrameLimitExceeded
    case imagePixelLimitExceeded

    var errorDescription: String? {
        switch self {
        case .invalidMaximumBytes:
            return "The text preview byte limit must be greater than zero."
        case .unsupportedTextEncoding:
            return "The file is not valid UTF-8, UTF-16, or GB18030 text."
        case .extractionLimitExceeded:
            return "The file is too large to preview safely."
        case .invalidExtractedFile:
            return "The extracted preview is not a regular file."
        case .invalidImage:
            return "The image metadata could not be read safely."
        case .imageFrameLimitExceeded:
            return "The image has too many frames to preview safely."
        case .imagePixelLimitExceeded:
            return "The image is too large to decode safely."
        }
    }
}

enum ArchiveEntryPreviewSupport {
    static let maximumTextBytes = 2 * 1024 * 1024
    static let maximumTextExtractionBytes: Int64 = 16 * 1024 * 1024
    static let maximumImageBytes: Int64 = 100 * 1024 * 1024
    static let maximumVideoBytes: Int64 = 512 * 1024 * 1024
    static let maximumImageFrameCount = 256
    static let maximumImageTotalPixels: UInt64 = 100_000_000

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp",
    ]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "json", "jsonl", "xml", "yaml", "yml", "csv", "tsv", "log",
        "swift", "js", "mjs", "cjs", "jsx", "ts", "tsx", "html", "htm", "css", "scss", "sass", "less",
        "py", "rb", "php", "java", "kt", "kts", "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "hxx",
        "m", "mm", "sh", "bash", "zsh", "fish", "go", "rs", "dart", "lua", "sql", "toml", "ini",
        "cfg", "conf", "properties", "gradle", "strings",
    ]
    private static let textFileNames: Set<String> = [
        ".editorconfig", ".env", ".gitattributes", ".gitignore", ".npmrc",
        "dockerfile", "gemfile", "makefile", "podfile", "rakefile",
    ]
    private static let extractionRootPrefixes = ["zwz-drag-", "zwz-entry-", "zwz-v3-entry-"]

    static func classify(fileName: String) -> ArchiveEntryPreviewKind {
        let lastPathComponent = (fileName as NSString).lastPathComponent.lowercased()
        let fileExtension = (lastPathComponent as NSString).pathExtension.lowercased()

        if imageExtensions.contains(fileExtension) { return .image }
        if videoExtensions.contains(fileExtension) { return .video }
        if textExtensions.contains(fileExtension) || textFileNames.contains(lastPathComponent) { return .text }

        guard !fileExtension.isEmpty,
              let type = UTType(filenameExtension: fileExtension) else {
            return .unsupported
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) { return .text }
        return .unsupported
    }

    static func readText(
        from url: URL,
        maximumBytes: Int = maximumTextBytes
    ) throws -> ArchiveEntryTextPreviewResult {
        guard maximumBytes > 0 else {
            throw ArchiveEntryPreviewSupportError.invalidMaximumBytes
        }

        let byteLimit = min(maximumBytes, maximumTextBytes)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let bytesToRead = Int(min(fileSize, UInt64(byteLimit)))
        let data = try handle.read(upToCount: bytesToRead) ?? Data()
        let isTruncated = fileSize > UInt64(bytesToRead)

        guard let decoded = decodeText(data, isTruncated: isTruncated) else {
            throw ArchiveEntryPreviewSupportError.unsupportedTextEncoding
        }
        return ArchiveEntryTextPreviewResult(
            text: decoded.text,
            encodingName: decoded.encodingName,
            isTruncated: isTruncated
        )
    }

    static func extractionByteLimit(for kind: ArchiveEntryPreviewKind) -> Int64? {
        switch kind {
        case .text: return maximumTextExtractionBytes
        case .image: return maximumImageBytes
        case .video: return maximumVideoBytes
        case .unsupported: return nil
        }
    }

    static func validateDeclaredSize(_ size: Int64, for kind: ArchiveEntryPreviewKind) throws {
        guard size >= 0,
              let limit = extractionByteLimit(for: kind),
              size <= limit else {
            throw ArchiveEntryPreviewSupportError.extractionLimitExceeded
        }
    }

    static func validateExtractedFile(at url: URL, for kind: ArchiveEntryPreviewKind) throws {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory != true,
              values.isSymbolicLink != true,
              values.isRegularFile == true else {
            throw ArchiveEntryPreviewSupportError.invalidExtractedFile
        }
        try validateDeclaredSize(Int64(values.fileSize ?? 0), for: kind)
    }

    static func validateImage(at url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ArchiveEntryPreviewSupportError.invalidImage
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { throw ArchiveEntryPreviewSupportError.invalidImage }
        guard frameCount <= maximumImageFrameCount else {
            throw ArchiveEntryPreviewSupportError.imageFrameLimitExceeded
        }

        var framePixelCounts: [UInt64] = []
        framePixelCounts.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = unsignedImageDimension(properties[kCGImagePropertyPixelWidth]),
                  let height = unsignedImageDimension(properties[kCGImagePropertyPixelHeight]),
                  width > 0,
                  height > 0,
                  !width.multipliedReportingOverflow(by: height).overflow else {
                throw ArchiveEntryPreviewSupportError.invalidImage
            }
            framePixelCounts.append(width * height)
        }
        try validateImageMetrics(framePixelCounts: framePixelCounts)
    }

    static func validateImageMetrics(framePixelCounts: [UInt64]) throws {
        guard !framePixelCounts.isEmpty else {
            throw ArchiveEntryPreviewSupportError.invalidImage
        }
        guard framePixelCounts.count <= maximumImageFrameCount else {
            throw ArchiveEntryPreviewSupportError.imageFrameLimitExceeded
        }
        var total: UInt64 = 0
        for pixels in framePixelCounts {
            let result = total.addingReportingOverflow(pixels)
            guard !result.overflow, result.partialValue <= maximumImageTotalPixels else {
                throw ArchiveEntryPreviewSupportError.imagePixelLimitExceeded
            }
            total = result.partialValue
        }
    }

    static func temporaryRoot(containing url: URL) -> URL? {
        guard url.isFileURL else { return nil }

        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        let candidate = url.standardizedFileURL
        let temporaryComponents = temporaryDirectory.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.starts(with: temporaryComponents),
              candidateComponents.count > temporaryComponents.count else { return nil }

        let directChildName = candidateComponents[temporaryComponents.count]
        guard extractionRootPrefixes.contains(where: {
            directChildName.hasPrefix($0) && directChildName.count > $0.count
        }) else { return nil }
        return temporaryDirectory.appendingPathComponent(directChildName, isDirectory: true)
    }

    static func isSafeArchiveEntryPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.contains("\0") else { return false }
        guard !path.hasPrefix("/"), !path.hasPrefix("\\") else { return false }
        guard !path.contains("\\") else { return false }

        let characters = Array(path)
        if characters.count >= 3,
           characters[0].isLetter,
           characters[1] == ":",
           characters[2] == "/" || characters[2] == "\\" {
            return false
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func decodeText(
        _ data: Data,
        isTruncated: Bool
    ) -> (text: String, encodingName: String)? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let payload = Data(data.dropFirst(3))
            return decode(payload, as: .utf8, trimmingIncompleteTail: isTruncated, maximumTailBytes: 3)
                .map { ($0, "UTF-8") }
        }

        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return decode(data, as: .utf16, trimmingIncompleteTail: isTruncated, maximumTailBytes: 3)
                .map { ($0, "UTF-16") }
        }

        if let byteOrder = likelyUTF16ByteOrder(in: data) {
            let encoding: String.Encoding = byteOrder == .littleEndian ? .utf16LittleEndian : .utf16BigEndian
            let name = byteOrder == .littleEndian ? "UTF-16 LE" : "UTF-16 BE"
            if let text = decode(data, as: encoding, trimmingIncompleteTail: isTruncated, maximumTailBytes: 3) {
                return (text, name)
            }
        }

        if let text = decode(data, as: .utf8, trimmingIncompleteTail: isTruncated, maximumTailBytes: 3) {
            return (text, "UTF-8")
        }

        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        if let text = decode(data, as: gb18030, trimmingIncompleteTail: isTruncated, maximumTailBytes: 3) {
            return (text, "GB18030")
        }
        return nil
    }

    private static func unsignedImageDimension(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        return nil
    }

    private enum UTF16ByteOrder {
        case littleEndian
        case bigEndian
    }

    private static func likelyUTF16ByteOrder(in data: Data) -> UTF16ByteOrder? {
        let sample = Array(data.prefix(512))
        let pairCount = sample.count / 2
        guard pairCount >= 2 else { return nil }

        var evenZeroCount = 0
        var oddZeroCount = 0
        for index in 0..<(pairCount * 2) where sample[index] == 0 {
            if index.isMultiple(of: 2) {
                evenZeroCount += 1
            } else {
                oddZeroCount += 1
            }
        }

        let threshold = max(1, pairCount / 3)
        if oddZeroCount >= threshold && oddZeroCount > evenZeroCount * 2 {
            return .littleEndian
        }
        if evenZeroCount >= threshold && evenZeroCount > oddZeroCount * 2 {
            return .bigEndian
        }
        return nil
    }

    private static func decode(
        _ data: Data,
        as encoding: String.Encoding,
        trimmingIncompleteTail: Bool,
        maximumTailBytes: Int
    ) -> String? {
        if let text = String(data: data, encoding: encoding) { return text }
        guard trimmingIncompleteTail, !data.isEmpty else { return nil }

        let maximumDrop = min(maximumTailBytes, data.count)
        for droppedByteCount in 1...maximumDrop {
            let prefix = Data(data.dropLast(droppedByteCount))
            if let text = String(data: prefix, encoding: encoding) { return text }
        }
        return nil
    }
}

struct ArchivePreviewWindowRestorationGate: Sendable {
    private(set) var currentToken = UUID()

    mutating func beginRestoration() -> UUID {
        currentToken = UUID()
        return currentToken
    }

    mutating func invalidateForPreviewOpen() {
        currentToken = UUID()
    }

    func accepts(_ token: UUID) -> Bool {
        token == currentToken
    }
}
