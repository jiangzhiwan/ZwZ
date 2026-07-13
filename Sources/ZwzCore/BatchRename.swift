import Foundation

// MARK: - Rule Types

/// 批量重命名规则
public enum BatchRenameRule: Sendable, Equatable {
    /// 查找和替换
    case findReplace(find: String, replace: String)
    /// 添加前后缀
    case prefixSuffix(prefix: String, suffix: String)
    /// 序号编号
    case numbering(mode: NumberingMode)
    /// 正则表达式替换
    case regexReplace(pattern: String, template: String)
    /// 大小写转换
    case caseConversion(mode: CaseMode)
}

/// 序号编号模式
public enum NumberingMode: Sendable, Equatable {
    /// 简单模式：起始序号 + 步长 + 位数 + 前缀
    case simple(start: Int, step: Int, digits: Int, prefix: String)
    /// 模板模式：支持 {seq:N} 占位符（N 位补零）或 {seq}（不补零）
    case template(template: String, start: Int, step: Int)
}

/// 大小写转换模式
public enum CaseMode: String, CaseIterable, Sendable, Equatable {
    case upper       // 全大写
    case lower       // 全小写
    case titleCase   // 首字母大写 (Title Case)
    case camelCase   // 驼峰命名
    case snakeCase   // 下划线命名
}

/// 批量重命名配置
public struct BatchRenameConfig: Sendable, Equatable {
    public var rule: BatchRenameRule
    /// 是否包含扩展名参与规则计算（默认 false，扩展名保留）
    public var includeExtension: Bool

    public init(rule: BatchRenameRule, includeExtension: Bool = false) {
        self.rule = rule
        self.includeExtension = includeExtension
    }
}

/// 批量重命名结果项
public struct BatchRenameItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// 原始完整文件名（含扩展名）
    public let originalName: String
    /// 规则计算后的名字（含扩展名）
    public let computedName: String
    /// 冲突处理后的最终名字（含扩展名）
    public let finalName: String
    /// 是否曾发生冲突并被自动编号
    public let hasConflict: Bool
    /// 是否为目录
    public let isDirectory: Bool

    public init(
        id: UUID = UUID(),
        originalName: String,
        computedName: String,
        finalName: String,
        hasConflict: Bool,
        isDirectory: Bool
    ) {
        self.id = id
        self.originalName = originalName
        self.computedName = computedName
        self.finalName = finalName
        self.hasConflict = hasConflict
        self.isDirectory = isDirectory
    }
}

/// 批量重命名错误
public enum BatchRenameError: LocalizedError, Equatable {
    case invalidRegex(String)
    case emptySelection

    public var errorDescription: String? {
        switch self {
        case .invalidRegex(let detail): return "Invalid regular expression: \(detail)"
        case .emptySelection: return "No items selected for batch rename."
        }
    }
}

// MARK: - Batch Rename Engine

/// 纯函数批量重命名引擎，无副作用，线程安全
public enum BatchRenameEngine {

    /// 已知的复合扩展名（整体保留）
    private static let knownDoubleExtensions: Set<String> = [
        "tar.gz", "tar.bz2", "tar.xz", "tar.zst"
    ]

    /// 对一组条目应用规则，返回重命名项列表（含冲突检测和自动编号）
    ///
    /// - Parameters:
    ///   - entries: 待重命名的条目列表 (name: 完整文件名, isDirectory: 是否目录)
    ///   - config: 重命名配置
    ///   - existingNames: 当前目录中不参与重命名但需避免冲突的名字集合（可选）
    /// - Returns: 重命名结果项列表，顺序与输入一致
    public static func compute(
        entries: [(name: String, isDirectory: Bool)],
        config: BatchRenameConfig,
        existingNames: Set<String> = []
    ) throws -> [BatchRenameItem] {
        guard !entries.isEmpty else { return [] }

        let preparedRegex: NSRegularExpression?
        if case .regexReplace(let pattern, _) = config.rule, !pattern.isEmpty {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                throw BatchRenameError.invalidRegex(pattern)
            }
            preparedRegex = regex
        } else {
            preparedRegex = nil
        }

        // 第一步：对每个条目应用规则，得到 computedName
        var computed: [(entry: (name: String, isDirectory: Bool), computedName: String)] = []
        for (index, entry) in entries.enumerated() {
            let computedName = try applyRule(
                to: entry.name,
                isDirectory: entry.isDirectory,
                rule: config.rule,
                includeExtension: config.includeExtension,
                index: index,
                preparedRegex: preparedRegex
            )
            computed.append((entry, computedName))
        }

        // 第二步：冲突检测和自动编号
        // 收集所有需要"占位"的名字：existingNames + 其他条目的 computedName
        // 对于每个条目，如果 computedName 与已有名字冲突，追加 _2, _3, ...
        var usedNames = Set<String>(existingNames)
        var results: [BatchRenameItem] = []

        for item in computed {
            let originalName = item.entry.name
            let computedName = item.computedName

            if !usedNames.contains(computedName) {
                // 无冲突
                usedNames.insert(computedName)
                results.append(BatchRenameItem(
                    originalName: originalName,
                    computedName: computedName,
                    finalName: computedName,
                    hasConflict: false,
                    isDirectory: item.entry.isDirectory
                ))
            } else {
                // 冲突：自动编号
                let (base, ext) = splitNameAndExtension(computedName)
                var suffix = 2
                var finalName: String
                repeat {
                    finalName = ext.isEmpty ? "\(base)_\(suffix)" : "\(base)_\(suffix).\(ext)"
                    suffix += 1
                } while usedNames.contains(finalName)
                usedNames.insert(finalName)
                results.append(BatchRenameItem(
                    originalName: originalName,
                    computedName: computedName,
                    finalName: finalName,
                    hasConflict: true,
                    isDirectory: item.entry.isDirectory
                ))
            }
        }

        return results
    }

    /// 对单个名字应用规则（不含冲突检测）
    ///
    /// - Parameters:
    ///   - name: 完整文件名（含扩展名）
    ///   - isDirectory: 是否目录
    ///   - rule: 重命名规则
    ///   - includeExtension: 是否包含扩展名
    ///   - index: 在输入列表中的序号（用于编号规则）
    /// - Returns: 规则计算后的名字（含扩展名）
    public static func applyRule(
        to name: String,
        isDirectory: Bool,
        rule: BatchRenameRule,
        includeExtension: Bool,
        index: Int
    ) throws -> String {
        try applyRule(
            to: name,
            isDirectory: isDirectory,
            rule: rule,
            includeExtension: includeExtension,
            index: index,
            preparedRegex: nil
        )
    }

    private static func applyRule(
        to name: String,
        isDirectory: Bool,
        rule: BatchRenameRule,
        includeExtension: Bool,
        index: Int,
        preparedRegex: NSRegularExpression?
    ) throws -> String {
        let (base, ext) = splitNameAndExtension(name)
        let target = includeExtension ? name : base

        let result: String
        switch rule {
        case .findReplace(let find, let replace):
            result = find.isEmpty ? target : target.replacingOccurrences(of: find, with: replace)

        case .prefixSuffix(let prefix, let suffix):
            result = prefix + target + suffix

        case .numbering(let mode):
            result = try applyNumbering(mode: mode, to: target, index: index)

        case .regexReplace(let pattern, let template):
            result = try applyRegex(
                pattern: pattern,
                template: template,
                to: target,
                preparedRegex: preparedRegex
            )

        case .caseConversion(let caseMode):
            result = applyCaseConversion(caseMode, to: target)
        }

        // 如果没包含扩展名，追加回扩展名
        if includeExtension {
            return result
        } else {
            return ext.isEmpty ? result : "\(result).\(ext)"
        }
    }

    // MARK: - Name/Extension Split

    /// 将文件名拆分为 (base, ext)
    /// - 已知双后缀（如 .tar.gz）整体作为扩展名
    /// - 无扩展名时 ext 为空字符串
    /// - 目录名的 ext 始终为空
    public static func splitNameAndExtension(_ name: String) -> (base: String, ext: String) {
        // 目录通常无扩展名概念，但以点结尾的隐藏目录等等仍按规则处理
        let lower = name.lowercased()

        // 检查已知的双后缀
        for doubleExt in knownDoubleExtensions {
            let suffix = "." + doubleExt
            if lower.hasSuffix(suffix), name.count > suffix.count {
                let base = String(name.dropLast(suffix.count))
                return (base, doubleExt)
            }
        }

        // 单后缀
        if let lastDot = name.lastIndex(of: ".") {
            let base = String(name[..<lastDot])
            let ext = String(name[name.index(after: lastDot)...])
            // 如果 base 为空（如 ".gitignore"），则整个名字为 base，无扩展名
            if base.isEmpty {
                return (name, "")
            }
            return (base, ext)
        }

        return (name, "")
    }

    // MARK: - Numbering

    private static func applyNumbering(mode: NumberingMode, to name: String, index: Int) throws -> String {
        switch mode {
        case .simple(let start, let step, let digits, let prefix):
            let number = start + index * step
            let formatted = digits > 0
                ? String(format: "%0\(digits)d", number)
                : String(number)
            return prefix + formatted

        case .template(let template, let start, let step):
            let number = start + index * step
            return try resolveSeqTemplate(template, number: number)
        }
    }

    /// 解析模板中的 {seq} 和 {seq:N} 占位符
    private static func resolveSeqTemplate(_ template: String, number: Int) throws -> String {
        var result = ""
        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{", let closeIdx = template[i...].firstIndex(of: "}") {
                let content = String(template[template.index(after: i)..<closeIdx])
                if content == "seq" {
                    result += String(number)
                } else if content.hasPrefix("seq:") {
                    let digitsStr = String(content.dropFirst(4))
                    if let digits = Int(digitsStr), digits > 0 {
                        result += String(format: "%0\(digits)d", number)
                    } else {
                        result += String(number)
                    }
                } else {
                    // 未知占位符，原样保留
                    result += "{\(content)}"
                }
                i = template.index(after: closeIdx)
            } else {
                result.append(template[i])
                i = template.index(after: i)
            }
        }
        return result
    }

    // MARK: - Regex

    private static func applyRegex(
        pattern: String,
        template: String,
        to name: String,
        preparedRegex: NSRegularExpression? = nil
    ) throws -> String {
        guard !pattern.isEmpty else { return name }
        guard let regex = preparedRegex ?? (try? NSRegularExpression(pattern: pattern, options: [])) else {
            throw BatchRenameError.invalidRegex(pattern)
        }
        let range = NSRange(name.startIndex..., in: name)
        return regex.stringByReplacingMatches(in: name, options: [], range: range, withTemplate: template)
    }

    // MARK: - Case Conversion

    private static func applyCaseConversion(_ mode: CaseMode, to name: String) -> String {
        switch mode {
        case .upper:
            return name.uppercased()

        case .lower:
            return name.lowercased()

        case .titleCase:
            // 按空格、下划线、连字符分词，每词首字母大写
            return titleCase(name)

        case .camelCase:
            let words = tokenize(name)
            guard let first = words.first else { return name }
            return first.lowercased() + words.dropFirst().map { capitalizeFirst($0) }.joined()

        case .snakeCase:
            let words = tokenizeForCaseConversion(name)
            return words.map { $0.lowercased() }.joined(separator: "_")
        }
    }

    /// Title Case：按非字母数字字符分词，每词首字母大写其余小写，用原分隔符连接
    private static func titleCase(_ name: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in name {
            if ch.isLetter || ch.isNumber {
                if capitalizeNext {
                    result += ch.uppercased()
                } else {
                    result += ch.lowercased()
                }
                capitalizeNext = false
            } else {
                result.append(ch)
                capitalizeNext = true
            }
        }
        return result
    }

    /// 分词：按非字母数字字符拆分，返回纯字母数字 token 列表
    private static func tokenize(_ name: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in name {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else {
                if !current.isEmpty { tokens.append(current); current = "" }
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// 分词（大小写转换专用）：按非字母数字字符 + 大写字母边界拆分
    /// 例如 "HelloWorld" → ["Hello", "World"]
    /// "hello_world" → ["hello", "world"]
    /// "hello-world" → ["hello", "world"]
    private static func tokenizeForCaseConversion(_ name: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in name {
            if ch.isLetter || ch.isNumber {
                // 大写字母开始新 token（但 not the first char in current）
                if ch.isUppercase && !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                current.append(ch)
            } else {
                if !current.isEmpty { tokens.append(current); current = "" }
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// 首字母大写
    private static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst().lowercased()
    }
}
