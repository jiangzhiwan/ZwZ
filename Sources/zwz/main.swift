import Foundation
import ZwzCore

// MARK: - Usage

func printUsage() {
    print("""
    zwz - 统一压缩/解压工具
    用法: zwz <子命令> [选项] <路径> [输出路径]

    子命令:
      c, compress    压缩文件或文件夹
      x, extract     解压压缩包
      l, list        列出压缩包内容（不解压）
      h, help        显示帮助

    压缩选项 (compress):
      -f, --format <fmt>      输出格式: zip (默认) 或 zwz
      -l, --level <level>     压缩等级: none, fastest, normal (默认), max
      -p, --password <pwd>    设置密码
      --no-aes                不使用 AES-256 加密 (默认启用)
      -s, --split <size>      分卷大小, 如 100MB 或 500KB
      -t, --threads <n>       线程数 (0=自动检测CPU核心数, 默认0)

    解压选项 (extract):
      -p, --password <pwd>    解压密码

    通用选项:
      -h, --help              显示帮助

    示例:
      zwz c /path/to/folder
      zwz c -f zwz /path/to/folder
      zwz c /path/to/folder /output/archive.zip
      zwz c -l max /path/to/file.txt
      zwz c -p mypassword /path/to/folder
      zwz c -s 100MB /path/to/largefile
      zwz c -t 4 /path/to/folder
      zwz x /path/to/archive.zip
      zwz x /path/to/archive.zwz /output/folder
      zwz x -p mypassword /path/to/archive.zip
      zwz l /path/to/archive.rar
    """)
}

// MARK: - Helpers

func formatBytes(_ bytes: Int64) -> String {
    let b = Double(bytes)
    if b < 1024 { return "\(Int64(b)) B" }
    if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
    if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", b / (1024 * 1024)) }
    return String(format: "%.2f GB", b / (1024 * 1024 * 1024))
}

func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

func pad(_ str: String, to width: Int) -> String {
    let count = str.count
    if count >= width { return str }
    return str + String(repeating: " ", count: width - count)
}

func parseSplitSize(_ str: String) -> SplitVolume? {
    let s = str.uppercased()
    if s.hasSuffix("MB") {
        let value = Int(s.dropLast(2)) ?? 0
        return .megaBytes(value)
    } else if s.hasSuffix("KB") {
        let value = Int(s.dropLast(2)) ?? 0
        return .kiloBytes(value)
    }
    return nil
}

func printProgress(_ progress: Double) {
    let percent = Int(progress * 100)
    let bar = String(repeating: "█", count: percent / 2) + String(repeating: "░", count: 50 - percent / 2)
    FileHandle.standardError.write("\r\u{1B}[2K [\u{1B}[32m\(bar)\u{1B}[0m] \(percent)%".data(using: .utf8)!)
}

func errExit(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write("❌ \(msg)\n".data(using: .utf8)!)
    exit(code)
}

// MARK: - Main

let api = ZwzAPI()
let args = CommandLine.arguments

guard args.count >= 2 else {
    printUsage()
    exit(0)
}

let subcommand = args[1].lowercased()

switch subcommand {
case "h", "-h", "--help", "help":
    printUsage()
    exit(0)
case "c", "compress":
    runCompress(args: Array(args.dropFirst(2)))
case "x", "extract":
    runExtract(args: Array(args.dropFirst(2)))
case "l", "list":
    runList(args: Array(args.dropFirst(2)))
default:
    FileHandle.standardError.write("Error: Unknown command '\(subcommand)'\n".data(using: .utf8)!)
    printUsage()
    exit(1)
}

// MARK: - Compress

@MainActor func runCompress(args: [String]) {
    var sourcePath: String?
    var outputPath: String?
    var level: CompressionLevel = .normal
    var password: String?
    var aes256 = true
    var splitVolume: SplitVolume?
    var format: CompressionFormat = .zip
    var threadCount = 0

    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help":
            printUsage()
            exit(0)
        case "-f", "--format":
            guard i + 1 < args.count else { errExit("--format requires a value") }
            i += 1
            switch args[i].lowercased() {
            case "zip": format = .zip
            case "zwz": format = .zwz
            default: errExit("Unknown format '\(args[i])'. Use: zip, zwz")
            }
        case "-l", "--level":
            guard i + 1 < args.count else { errExit("--level requires a value") }
            i += 1
            switch args[i].lowercased() {
            case "none": level = .none
            case "fastest": level = .fastest
            case "normal": level = .normal
            case "max": level = .max
            default: errExit("Unknown compression level '\(args[i])'. Use: none, fastest, normal, max")
            }
        case "-p", "--password":
            guard i + 1 < args.count else { errExit("--password requires a value") }
            i += 1
            password = args[i]
        case "--no-aes":
            aes256 = false
        case "-s", "--split":
            guard i + 1 < args.count else { errExit("--split requires a value") }
            i += 1
            guard let vol = parseSplitSize(args[i]) else {
                errExit("Invalid split size. Use format like '100MB' or '500KB'")
            }
            splitVolume = vol
        case "-t", "--threads":
            guard i + 1 < args.count else { errExit("--threads requires a value") }
            i += 1
            guard let n = Int(args[i]), n >= 0 else {
                errExit("Invalid thread count. Use a non-negative integer (0=auto)")
            }
            threadCount = n
        default:
            if arg.hasPrefix("-") {
                errExit("Unknown option '\(arg)'")
            }
            if sourcePath == nil {
                sourcePath = arg
            } else if outputPath == nil {
                outputPath = arg
            }
        }
        i += 1
    }

    guard let srcPath = sourcePath else {
        errExit("No source path specified")
    }
    guard FileManager.default.fileExists(atPath: srcPath) else {
        errExit("Source path not found: \(srcPath)")
    }

    let options = CompressionOptions(
        level: level,
        password: password,
        aes256: aes256,
        splitVolume: splitVolume,
        format: format,
        threadCount: threadCount
    )

    let threads = resolveThreadCount(threadCount)
    print("📦 正在压缩: \(srcPath)")
    print("   格式: \(format.displayName), 线程数: \(threads)")
    if let pwd = password, !pwd.isEmpty {
        print("🔒 加密: AES-256-GCM")
    }
    if let split = splitVolume {
        print("📏 分卷: \(split.displayName)")
    }

    let startTime = Date()
    do {
        let finalDestPath = try api.compress(
            sourcePath: srcPath,
            destinationPath: outputPath,
            options: options
        ) { progress in
            printProgress(progress)
        }
        let elapsed = Date().timeIntervalSince(startTime)
        FileHandle.standardError.write("\n".data(using: .utf8)!)

        if let attrs = try? FileManager.default.attributesOfItem(atPath: finalDestPath),
           let size = attrs[.size] as? Int64 {
            let sizeStr = formatBytes(size)
            print("✅ 压缩完成! (\(sizeStr), 耗时 \(String(format: "%.2f", elapsed))s)")
            print("   输出: \(finalDestPath)")
        } else {
            print("✅ 压缩完成! (耗时 \(String(format: "%.2f", elapsed))s)")
        }

        // 如果有分卷，列出所有分卷
        if splitVolume != nil {
            let destURL = URL(fileURLWithPath: finalDestPath)
            let dirURL = destURL.deletingLastPathComponent()
            let baseName = destURL.deletingPathExtension().lastPathComponent
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dirURL.path) {
                let splitFiles = files.filter { $0.hasPrefix(baseName) }.sorted()
                print("   分卷文件:")
                for f in splitFiles {
                    print("     - \(dirURL.appendingPathComponent(f).path)")
                }
            }
        }
    } catch {
        FileHandle.standardError.write("\n".data(using: .utf8)!)
        errExit("压缩失败: \(error.localizedDescription)")
    }
}

// MARK: - Extract

@MainActor func runExtract(args: [String]) {
    var archivePath: String?
    var destinationPath: String?
    var password: String?

    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help":
            printUsage()
            exit(0)
        case "-p", "--password":
            guard i + 1 < args.count else { errExit("--password requires a value") }
            i += 1
            password = args[i]
        default:
            if arg.hasPrefix("-") {
                errExit("Unknown option '\(arg)'")
            }
            if archivePath == nil {
                archivePath = arg
            } else if destinationPath == nil {
                destinationPath = arg
            }
        }
        i += 1
    }

    guard let archPath = archivePath else {
        errExit("No archive path specified")
    }
    guard FileManager.default.fileExists(atPath: archPath) else {
        errExit("Archive not found: \(archPath)")
    }

    do {
        let format = try api.detectFormat(archivePath: archPath)
        print("📂 格式: \(format.displayName)")
        print("📂 正在解压: \(URL(fileURLWithPath: archPath).lastPathComponent)")

        let startTime = Date()
        let destPath = try api.extract(
            archivePath: archPath,
            destinationPath: destinationPath,
            password: password
        ) { progress in
            printProgress(progress)
        }
        let elapsed = Date().timeIntervalSince(startTime)
        FileHandle.standardError.write("\n".data(using: .utf8)!)

        print("✅ 解压完成! (耗时 \(String(format: "%.2f", elapsed))s)")
        print("   输出: \(destPath)")
    } catch let error as ZwzError {
        switch error {
        case .passwordRequired:
            errExit("此压缩包需要密码. 请使用 -p 参数提供密码.")
        case .wrongPassword:
            errExit("密码错误. 请检查密码后重试.")
        default:
            errExit("解压失败: \(error.localizedDescription)")
        }
    } catch {
        errExit("解压失败: \(error.localizedDescription)")
    }
}

// MARK: - List

@MainActor func runList(args: [String]) {
    var archivePath: String?

    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            if arg.hasPrefix("-") {
                errExit("Unknown option '\(arg)'")
            }
            if archivePath == nil {
                archivePath = arg
            }
        }
        i += 1
    }

    guard let archPath = archivePath else {
        errExit("No archive path specified")
    }
    guard FileManager.default.fileExists(atPath: archPath) else {
        errExit("Archive not found: \(archPath)")
    }

    print("📋 压缩包内容: \(URL(fileURLWithPath: archPath).lastPathComponent)")
    print(String(repeating: "─", count: 60))

    do {
        let entries = try api.list(archivePath: archPath)
        if entries.isEmpty {
            print("  (空)")
        } else {
            print("  \(pad("名称", to: 40)) \(pad("大小", to: 10))  修改日期")
            print(String(repeating: "─", count: 60))

            for entry in entries {
                let sizeStr = formatBytes(entry.size)
                let dateStr = entry.modifiedDate != nil
                    ? formatDate(entry.modifiedDate!)
                    : "-"
                let prefix = entry.isDirectory ? "📁" : "📄"
                print("  \(prefix) \(pad(entry.name, to: 38)) \(pad(sizeStr, to: 10))  \(dateStr)")
            }

            print(String(repeating: "─", count: 60))
            let totalSize = entries.reduce(Int64(0)) { $0 + $1.size }
            print("  共 \(entries.count) 个项目, 总大小: \(formatBytes(totalSize))")
        }
    } catch {
        errExit("读取失败: \(error.localizedDescription)")
    }
}
