import Foundation
import ZIPFoundation
import SWCompression

/// 压缩等级
public enum CompressionLevel: Int, CaseIterable {
    case none = 0
    case fastest = 1
    case normal = 2
    case max = 3

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .fastest: return "Fastest"
        case .normal: return "Normal"
        case .max: return "Max"
        }
    }
}

/// 压缩格式（支持创建 ZIP 和 ZWZ）
public enum CompressionFormat: String, CaseIterable {
    case zip = "zip"
    case zwz = "zwz"

    public var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .zwz: return "ZWZ"
        }
    }

    public var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .zwz: return "zwz"
        }
    }
}

/// 支持的解压格式
public enum ExtractionFormat: String, CaseIterable {
    case zip = "zip"
    case zwz = "zwz"
    case rar = "rar"
    case sevenZip = "7z"
    case tarGz = "tar.gz"
    case tgz = "tgz"
    case gz = "gz"

    public var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .zwz: return "ZWZ"
        case .rar: return "RAR"
        case .sevenZip: return "7Z"
        case .tarGz: return "TAR.GZ"
        case .tgz: return "TGZ"
        case .gz: return "GZ"
        }
    }
}

/// ZWZ 格式内部使用的压缩方法
public enum ZwzCompressionMethod: UInt8, CaseIterable {
    case store = 0      // 不压缩
    case deflate = 1    // Deflate
    case lzma = 2       // LZMA

    public var displayName: String {
        switch self {
        case .store: return "Store"
        case .deflate: return "Deflate"
        case .lzma: return "LZMA"
        }
    }

    /// 根据压缩等级选择压缩方法
    public static func method(for level: CompressionLevel) -> ZwzCompressionMethod {
        switch level {
        case .none: return .store
        case .fastest, .normal: return .deflate
        case .max: return .lzma
        }
    }
}

/// 压缩选项
public struct CompressionOptions {
    public var level: CompressionLevel
    public var password: String?
    public var encryption: ZwzEncryptionMode
    public var aes256: Bool
    public var splitVolume: SplitVolume?
    public var format: CompressionFormat
    public var threadCount: Int  // 0 = 自动检测 CPU 核心数

    public init(
        level: CompressionLevel = .normal,
        password: String? = nil,
        aes256: Bool = true,
        splitVolume: SplitVolume? = nil,
        format: CompressionFormat = .zip,
        threadCount: Int = 0
    ) {
        self.level = level
        self.password = password
        self.encryption = password.map(ZwzEncryptionMode.password) ?? .none
        self.aes256 = aes256
        self.splitVolume = splitVolume
        self.format = format
        self.threadCount = threadCount
    }

    public init(
        level: CompressionLevel = .normal,
        encryption: ZwzEncryptionMode,
        aes256: Bool = true,
        splitVolume: SplitVolume? = nil,
        format: CompressionFormat = .zip,
        threadCount: Int = 0
    ) {
        self.level = level
        if case .password(let password) = encryption {
            self.password = password
        } else {
            self.password = nil
        }
        self.encryption = encryption
        self.aes256 = aes256
        self.splitVolume = splitVolume
        self.format = format
        self.threadCount = threadCount
    }
}

/// 大文件分块并行的阈值（字节）
public let kZwzBlockParallelThreshold: Int64 = 10 * 1024 * 1024  // 10 MB

/// 获取有效线程数（0 或负数 → CPU 核心数）
public func resolveThreadCount(_ requested: Int) -> Int {
    if requested > 0 { return requested }
    return ProcessInfo.processInfo.activeProcessorCount
}

/// 分卷压缩选项
public enum SplitVolume: Equatable {
    case megaBytes(Int)
    case kiloBytes(Int)

    public var bytes: Int64 {
        switch self {
        case .megaBytes(let mb): return Int64(mb) * 1024 * 1024
        case .kiloBytes(let kb): return Int64(kb) * 1024
        }
    }

    public var displayName: String {
        switch self {
        case .megaBytes(let mb): return "\(mb)MB"
        case .kiloBytes(let kb): return "\(kb)KB"
        }
    }
}

/// 密码强度评估
public enum PasswordStrength {
    case none, weak, medium, strong, veryStrong

    public var score: Int {
        switch self {
        case .none: return 0
        case .weak: return 1
        case .medium: return 2
        case .strong: return 3
        case .veryStrong: return 4
        }
    }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .weak: return "Weak"
        case .medium: return "Medium"
        case .strong: return "Strong"
        case .veryStrong: return "Very Strong"
        }
    }

    public static func evaluate(_ password: String) -> PasswordStrength {
        guard !password.isEmpty else { return .none }
        var score = 0
        let length = password.count
        if length >= 8 { score += 1 }
        if length >= 12 { score += 1 }
        if length >= 16 { score += 1 }
        let hasLower = password.contains { $0.isLowercase }
        let hasUpper = password.contains { $0.isUppercase }
        let hasDigit = password.contains { $0.isNumber }
        let hasSpecial = password.contains { "!@#$%^&*()_+-=[]{}|;:,.<>?/~`".contains($0) }
        let diversity = [hasLower, hasUpper, hasDigit, hasSpecial].filter { $0 }.count
        score += diversity - 1
        let commonPasswords = ["123456", "password", "12345678", "qwerty", "abc123", "111111", "123456789", "1234567890"]
        if commonPasswords.contains(password.lowercased()) { return .weak }
        switch score {
        case 0...1: return .weak
        case 2: return .medium
        case 3: return .strong
        default: return .veryStrong
        }
    }
}

public typealias ProgressHandler = (Double) -> Void

public enum ZwzError: LocalizedError {
    case operationCancelled
    case fileNotFound(String)
    case invalidFormat(String)
    case extractionFailed(String)
    case compressionFailed(String)
    case passwordRequired(String)
    case wrongPassword(String)
    case unsupportedOperation(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .operationCancelled: return "Operation cancelled"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .invalidFormat(let msg): return "Invalid format: \(msg)"
        case .extractionFailed(let msg): return "Extraction failed: \(msg)"
        case .compressionFailed(let msg): return "Compression failed: \(msg)"
        case .passwordRequired(let msg): return "Password required: \(msg)"
        case .wrongPassword(let msg): return "Wrong password: \(msg)"
        case .unsupportedOperation(let msg): return "Unsupported operation: \(msg)"
        case .ioError(let msg): return "IO error: \(msg)"
        }
    }
}

/// 压缩包内的文件条目（用于预览）
public struct ArchiveEntry: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let name: String
    public let path: String
    public let size: Int64
    public let isDirectory: Bool
    public let modifiedDate: Date?

    public init(name: String, path: String, size: Int64, isDirectory: Bool, modifiedDate: Date?) {
        self.name = name
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.modifiedDate = modifiedDate
    }

    public static func == (lhs: ArchiveEntry, rhs: ArchiveEntry) -> Bool {
        lhs.name == rhs.name &&
            lhs.path == rhs.path &&
            lhs.size == rhs.size &&
            lhs.isDirectory == rhs.isDirectory &&
            lhs.modifiedDate == rhs.modifiedDate
    }
}

public struct ZwzArchiveListing: Equatable, Sendable {
    public let entries: [ArchiveEntry]
    public let version: UInt16?
    public let securityInfo: ZwzArchiveSecurityInfo?

    public init(entries: [ArchiveEntry], version: UInt16?, securityInfo: ZwzArchiveSecurityInfo?) {
        self.entries = entries
        self.version = version
        self.securityInfo = securityInfo
    }
}

public struct ZwzExtractionResult: Equatable, Sendable {
    public let destinationPath: String
    public let version: UInt16?
    public let securityInfo: ZwzArchiveSecurityInfo?

    public init(destinationPath: String, version: UInt16?, securityInfo: ZwzArchiveSecurityInfo?) {
        self.destinationPath = destinationPath
        self.version = version
        self.securityInfo = securityInfo
    }
}
