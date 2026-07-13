import Foundation
import ZwzCore

struct RenameArguments: Equatable {
    var archive: String
    var rule: BatchRenameRule
    var includeExtension: Bool
    var password: String?
    var dryRun: Bool
    var filter: String?

    static func parse(_ arguments: [String]) throws -> Self {
        var positionals: [String] = []
        var rule: BatchRenameRule?
        var includeExtension = false
        var password: String?
        var dryRun = false
        var filter: String?
        // Rule-specific params
        var findText = ""
        var replaceText = ""
        var prefixText = ""
        var suffixText = ""
        var numberingStart = 1
        var numberingStep = 1
        var numberingDigits = 3
        var numberingPrefix = ""
        var numberingTemplate = ""
        var regexPattern = ""
        var regexTemplate = ""
        var caseMode: CaseMode = .upper
        var numberingTemplateMode = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value() throws -> String {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
                    throw CLIParseError.invalid("\(argument) requires a value")
                }
                return arguments[index + 1]
            }
            switch argument {
            case "--archive":
                positionals.insert(try value(), at: 0); index += 1
            case "--rule":
                let raw = try value().lowercased()
                switch raw {
                case "find-replace": rule = .findReplace(find: "", replace: "")
                case "prefix-suffix": rule = .prefixSuffix(prefix: "", suffix: "")
                case "numbering": rule = .numbering(mode: .simple(start: 1, step: 1, digits: 3, prefix: ""))
                case "regex-replace": rule = .regexReplace(pattern: "", template: "")
                case "case-conversion": rule = .caseConversion(mode: .upper)
                default: throw CLIParseError.invalid("Unknown rule '\(raw)'. Valid: find-replace, prefix-suffix, numbering, regex-replace, case-conversion")
                }
                index += 1
            case "--find":
                findText = try value(); index += 1
            case "--replace":
                replaceText = try value(); index += 1
            case "--prefix":
                prefixText = try value(); index += 1
            case "--suffix":
                suffixText = try value(); index += 1
            case "--start":
                guard let v = Int(try value()), v >= 0 else { throw CLIParseError.invalid("--start requires a non-negative integer") }
                numberingStart = v; index += 1
            case "--step":
                guard let v = Int(try value()), v > 0 else { throw CLIParseError.invalid("--step requires a positive integer") }
                numberingStep = v; index += 1
            case "--digits":
                guard let v = Int(try value()), v >= 0 else { throw CLIParseError.invalid("--digits requires a non-negative integer") }
                numberingDigits = v; index += 1
            case "--numbering-prefix":
                numberingPrefix = try value(); index += 1
            case "--numbering-template":
                numberingTemplate = try value(); numberingTemplateMode = true; index += 1
            case "--pattern":
                regexPattern = try value(); index += 1
            case "--template":
                regexTemplate = try value(); index += 1
            case "--case-mode":
                let raw = try value().lowercased()
                switch raw {
                case "upper": caseMode = .upper
                case "lower": caseMode = .lower
                case "title": caseMode = .titleCase
                case "camel": caseMode = .camelCase
                case "snake": caseMode = .snakeCase
                default: throw CLIParseError.invalid("Unknown case mode '\(raw)'. Valid: upper, lower, title, camel, snake")
                }
                index += 1
            case "--include-extension":
                includeExtension = true
            case "-p", "--password":
                guard password == nil else { throw CLIParseError.invalid("Password may only be specified once") }
                password = try value(); index += 1
            case "--dry-run":
                dryRun = true
            case "--filter":
                filter = try value(); index += 1
            case "-h", "--help":
                throw CLIParseError.invalid("Use 'zwz help' for help")
            default:
                guard !argument.hasPrefix("-") else {
                    throw CLIParseError.invalid("Unknown option '\(argument)'")
                }
                positionals.append(argument)
            }
            index += 1
        }

        guard let resolvedRule = rule else {
            throw CLIParseError.invalid("--rule is required. Valid: find-replace, prefix-suffix, numbering, regex-replace, case-conversion")
        }

        // Fill in rule parameters
        let finalRule: BatchRenameRule
        switch resolvedRule {
        case .findReplace:
            finalRule = .findReplace(find: findText, replace: replaceText)
        case .prefixSuffix:
            finalRule = .prefixSuffix(prefix: prefixText, suffix: suffixText)
        case .numbering:
            if numberingTemplateMode {
                finalRule = .numbering(mode: .template(template: numberingTemplate, start: numberingStart, step: numberingStep))
            } else {
                finalRule = .numbering(mode: .simple(start: numberingStart, step: numberingStep, digits: numberingDigits, prefix: numberingPrefix))
            }
        case .regexReplace:
            finalRule = .regexReplace(pattern: regexPattern, template: regexTemplate)
        case .caseConversion:
            finalRule = .caseConversion(mode: caseMode)
        }

        // Find archive path: either from --archive or first positional
        let archivePath: String
        if let explicit = positionals.first(where: { $0.hasSuffix(".zip") || $0.hasSuffix(".zwz") }) {
            archivePath = explicit
        } else if !positionals.isEmpty {
            archivePath = positionals[0]
        } else {
            throw CLIParseError.invalid("Archive path is required (use --archive or pass as positional argument)")
        }

        return Self(
            archive: archivePath,
            rule: finalRule,
            includeExtension: includeExtension,
            password: password,
            dryRun: dryRun,
            filter: filter
        )
    }
}
