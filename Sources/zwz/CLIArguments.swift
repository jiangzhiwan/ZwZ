import Darwin
import Foundation
import ZwzCore

enum CLIParseError: LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        guard case .invalid(let message) = self else { return nil }
        return message
    }
}

enum CLIArguments: Equatable {
    case help
    case compress(CompressArguments)
    case extract(ExtractArguments)
    case list(ListArguments)
    case key(KeyArguments)
    case rename(RenameArguments)

    static func parse(_ arguments: [String]) throws -> CLIArguments {
        guard let first = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())
        if ["c", "compress", "x", "extract", "l", "list", "rename"].contains(first.lowercased()),
           rest == ["-h"] || rest == ["--help"] {
            return .help
        }
        switch first.lowercased() {
        case "h", "help", "-h", "--help":
            guard rest.isEmpty else { throw CLIParseError.invalid("help accepts no arguments") }
            return .help
        case "c", "compress": return .compress(try CompressArguments.parse(rest))
        case "x", "extract": return .extract(try ExtractArguments.parse(rest))
        case "l", "list": return .list(try ListArguments.parse(rest))
        case "key": return .key(try KeyArguments.parse(rest))
        case "rename": return .rename(try RenameArguments.parse(rest))
        default: throw CLIParseError.invalid("Unknown command '\(first)'")
        }
    }
}

struct CompressArguments: Equatable {
    var source: String
    var output: String?
    var level: CompressionLevel
    var password: String?
    var aes256: Bool
    var splitVolume: SplitVolume?
    var format: CompressionFormat
    var threadCount: Int
    var recipients: [String]
    var signer: String?

    fileprivate static func parse(_ arguments: [String]) throws -> Self {
        var positionals: [String] = []
        var level: CompressionLevel = .normal
        var password: String?
        var aes256 = true
        var splitVolume: SplitVolume?
        var format: CompressionFormat = .zip
        var threadCount = 0
        var recipients: [String] = []
        var signer: String?
        var seen = Set<String>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value() throws -> String {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
                    throw CLIParseError.invalid("\(argument) requires a value")
                }
                return arguments[index + 1]
            }
            func singleton(_ name: String) throws {
                guard seen.insert(name).inserted else {
                    throw CLIParseError.invalid("\(argument) may only be specified once")
                }
            }
            switch argument {
            case "-f", "--format":
                try singleton("format")
                let raw = try value().lowercased()
                guard let parsed = CompressionFormat(rawValue: raw) else {
                    throw CLIParseError.invalid("Unknown format '\(raw)'")
                }
                format = parsed; index += 1
            case "-l", "--level":
                try singleton("level")
                switch try value().lowercased() {
                case "none": level = .none
                case "fastest": level = .fastest
                case "normal": level = .normal
                case "max": level = .max
                default: throw CLIParseError.invalid("Unknown compression level")
                }
                index += 1
            case "-p", "--password":
                try singleton("password"); password = try value(); index += 1
            case "--no-aes":
                try singleton("aes"); aes256 = false
            case "-s", "--split":
                try singleton("split")
                guard let parsed = parseSplitSize(try value()) else {
                    throw CLIParseError.invalid("Invalid split size. Use a positive value such as 100MB or 500KB")
                }
                splitVolume = parsed; index += 1
            case "-t", "--threads":
                try singleton("threads")
                guard let parsed = Int(try value()), parsed >= 0 else {
                    throw CLIParseError.invalid("Invalid thread count. Use a non-negative integer")
                }
                threadCount = parsed; index += 1
            case "--recipient":
                recipients.append(try value()); index += 1
            case "--sign":
                try singleton("sign"); signer = try value(); index += 1
            case "-h", "--help": throw CLIParseError.invalid("Use 'zwz help' for help")
            default:
                guard !argument.hasPrefix("-") else {
                    throw CLIParseError.invalid("Unknown option '\(argument)'")
                }
                positionals.append(argument)
            }
            index += 1
        }
        guard (1...2).contains(positionals.count) else {
            throw CLIParseError.invalid(positionals.isEmpty ? "No source path specified" : "Too many positional arguments")
        }
        if password != nil && (!recipients.isEmpty || signer != nil) {
            throw CLIParseError.invalid("Password and public-key encryption are mutually exclusive")
        }
        if signer != nil && recipients.isEmpty {
            throw CLIParseError.invalid("--sign requires at least one --recipient")
        }
        if !recipients.isEmpty || signer != nil {
            guard format == .zwz else {
                throw CLIParseError.invalid("--recipient and --sign require -f zwz")
            }
        }
        return Self(
            source: positionals[0], output: positionals.count == 2 ? positionals[1] : nil,
            level: level, password: password, aes256: aes256, splitVolume: splitVolume,
            format: format, threadCount: threadCount, recipients: recipients, signer: signer
        )
    }
}

struct ExtractArguments: Equatable {
    var archive: String
    var output: String?
    var password: String?

    fileprivate static func parse(_ arguments: [String]) throws -> Self {
        var positionals: [String] = []
        let password = try parseArchiveArguments(arguments, positionals: &positionals)
        guard (1...2).contains(positionals.count) else {
            throw CLIParseError.invalid(positionals.isEmpty ? "No archive path specified" : "Too many positional arguments")
        }
        return Self(archive: positionals[0], output: positionals.count == 2 ? positionals[1] : nil, password: password)
    }
}

struct ListArguments: Equatable {
    var archive: String
    var password: String?

    fileprivate static func parse(_ arguments: [String]) throws -> Self {
        var positionals: [String] = []
        let password = try parseArchiveArguments(arguments, positionals: &positionals)
        guard positionals.count == 1 else {
            throw CLIParseError.invalid(positionals.isEmpty ? "No archive path specified" : "Too many positional arguments")
        }
        return Self(archive: positionals[0], password: password)
    }
}

private func parseArchiveArguments(_ arguments: [String], positionals: inout [String]) throws -> String? {
    var password: String?
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-p", "--password":
            guard password == nil else { throw CLIParseError.invalid("Password may only be specified once") }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
                throw CLIParseError.invalid("\(argument) requires a value")
            }
            password = arguments[index + 1]; index += 1
        default:
            guard !argument.hasPrefix("-") else { throw CLIParseError.invalid("Unknown option '\(argument)'") }
            positionals.append(argument)
        }
        index += 1
    }
    return password
}

enum KeyArguments: Equatable {
    case create(name: String)
    case list
    case rename(identity: String, newName: String)
    case delete(identity: String, confirmed: Bool)
    case exportPublic(identity: String, output: String)
    case importPublic(input: String, replace: Bool)
    case backup(identity: String, output: String)
    case restore(input: String, replace: Bool)

    fileprivate static func parse(_ arguments: [String]) throws -> Self {
        guard let operation = arguments.first else { throw CLIParseError.invalid("Missing key command") }
        let rest = Array(arguments.dropFirst())
        switch operation {
        case "create": guard validPositionals(rest, count: 1) else { throw arity(operation) }; return .create(name: rest[0])
        case "list": guard rest.isEmpty else { throw arity(operation) }; return .list
        case "rename": guard validPositionals(rest, count: 2) else { throw arity(operation) }; return .rename(identity: rest[0], newName: rest[1])
        case "export-public": guard validPositionals(rest, count: 2) else { throw arity(operation) }; return .exportPublic(identity: rest[0], output: rest[1])
        case "backup":
            guard rest.count == 2, !rest.contains(where: { $0.hasPrefix("-") }) else { throw arity(operation) }
            return .backup(identity: rest[0], output: rest[1])
        case "delete":
            let parsed = try flag("--yes", in: rest)
            guard parsed.values.count == 1 else { throw arity(operation) }
            return .delete(identity: parsed.values[0], confirmed: parsed.present)
        case "import-public":
            let parsed = try flag("--replace", in: rest)
            guard parsed.values.count == 1 else { throw arity(operation) }
            return .importPublic(input: parsed.values[0], replace: parsed.present)
        case "restore":
            let parsed = try flag("--replace", in: rest)
            guard parsed.values.count == 1 else { throw arity(operation) }
            return .restore(input: parsed.values[0], replace: parsed.present)
        default: throw CLIParseError.invalid("Unknown key command '\(operation)'")
        }
    }

    private static func flag(_ flag: String, in arguments: [String]) throws -> (present: Bool, values: [String]) {
        var present = false
        var values: [String] = []
        for argument in arguments {
            if argument == flag {
                guard !present else { throw CLIParseError.invalid("\(flag) may only be specified once") }
                present = true
            } else {
                guard !argument.hasPrefix("-") else { throw CLIParseError.invalid("Unknown option '\(argument)'") }
                values.append(argument)
            }
        }
        return (present, values)
    }

    private static func arity(_ operation: String) -> CLIParseError {
        .invalid("Invalid arguments for key \(operation)")
    }

    private static func validPositionals(_ arguments: [String], count: Int) -> Bool {
        arguments.count == count && !arguments.contains(where: { $0.hasPrefix("-") })
    }
}

func parseSplitSize(_ value: String) -> SplitVolume? {
    let upper = value.uppercased()
    let suffix: String
    let multiplier: Int64
    if upper.hasSuffix("MB") {
        suffix = "MB"; multiplier = 1_024 * 1_024
    } else if upper.hasSuffix("KB") {
        suffix = "KB"; multiplier = 1_024
    } else {
        return nil
    }
    guard let amount = Int(upper.dropLast(suffix.count)), amount > 0,
          let amount64 = Int64(exactly: amount),
          !amount64.multipliedReportingOverflow(by: multiplier).overflow else {
        return nil
    }
    if suffix == "MB" { return .megaBytes(amount) }
    if suffix == "KB" { return .kiloBytes(amount) }
    return nil
}

protocol ZwzCLIArchiveOperations {
    func compress(source: String, destination: String?, options: CompressionOptions, keyProvider: ZwzPrivateKeyProvider?) throws -> String
    func extract(archive: String, destination: String?, password: String?, keyProvider: ZwzPrivateKeyProvider?) throws -> ZwzExtractionResult
    func list(archive: String, password: String?, keyProvider: ZwzPrivateKeyProvider?) throws -> ZwzArchiveListing
    func recipientInfo(archive: String) throws -> [ZwzRecipientInfo]
}

struct ZwzAPIArchiveOperations: ZwzCLIArchiveOperations {
    private let api = ZwzAPI()

    func compress(source: String, destination: String?, options: CompressionOptions, keyProvider: ZwzPrivateKeyProvider?) throws -> String {
        try api.compress(sourcePath: source, destinationPath: destination, options: options, keyProvider: keyProvider)
    }

    func extract(archive: String, destination: String?, password: String?, keyProvider: ZwzPrivateKeyProvider?) throws -> ZwzExtractionResult {
        try api.extract(archivePath: archive, destinationPath: destination, password: password, keyProvider: keyProvider)
    }

    func list(archive: String, password: String?, keyProvider: ZwzPrivateKeyProvider?) throws -> ZwzArchiveListing {
        try api.list(archivePath: archive, password: password, keyProvider: keyProvider)
    }

    func recipientInfo(archive: String) throws -> [ZwzRecipientInfo] {
        try ZwzV3Extractor().recipientInfo(archivePath: archive)
    }
}

struct ZwzCLIDependencies {
    var output: (String) -> Void
    var error: (String) -> Void
    var passwordReader: (_ prompt: String) throws -> String
    var confirmationReader: (_ prompt: String) -> String?
    var identityStore: any ZwzIdentityStore
    var archives: any ZwzCLIArchiveOperations
    var fileManager: FileManager

    static func production() -> Self {
        let terminal = TerminalSecretReader(
            session: DarwinTerminalSession(),
            output: { FileHandle.standardError.write(Data($0.utf8)) }
        )
        return Self(
            output: { print($0) },
            error: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
            passwordReader: { try terminal.read(prompt: $0) },
            confirmationReader: { prompt in
                FileHandle.standardError.write(Data(prompt.utf8))
                return readLine()
            },
            identityStore: MacKeychainIdentityStore(),
            archives: ZwzAPIArchiveOperations(),
            fileManager: .default
        )
    }
}

protocol TerminalSession: AnyObject {
    func disableEcho() throws -> () -> Void
    func readLine() -> String?
    var isTerminal: Bool { get }
}

final class DarwinTerminalSession: TerminalSession {
    var isTerminal: Bool { isatty(STDIN_FILENO) == 1 }

    func disableEcho() throws -> () -> Void {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw CLIParseError.invalid("Unable to read terminal state")
        }
        var hidden = original
        hidden.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else {
            throw CLIParseError.invalid("Unable to disable terminal echo")
        }
        return {
            var restored = original
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &restored)
        }
    }

    func readLine() -> String? { Swift.readLine() }
}

final class TerminalSecretReader {
    private let session: any TerminalSession
    private let output: (String) -> Void

    init(session: any TerminalSession, output: @escaping (String) -> Void) {
        self.session = session
        self.output = output
    }

    func read(prompt: String) throws -> String {
        output(prompt)
        if session.isTerminal {
            let restore = try session.disableEcho()
            defer {
                restore()
                output("\n")
            }
            return session.readLine() ?? ""
        }
        return session.readLine() ?? ""
    }
}

enum ZwzCLI {
    static func run(arguments: [String], dependencies: ZwzCLIDependencies) -> Int32 {
        do {
            let command = try CLIArguments.parse(arguments)
            try execute(command, dependencies: dependencies)
            return 0
        } catch {
            report(error, dependencies: dependencies, archive: archivePath(from: arguments))
            return 1
        }
    }

    private static func execute(_ command: CLIArguments, dependencies: ZwzCLIDependencies) throws {
        switch command {
        case .help:
            dependencies.output(usage)
        case .key(let command):
            try executeKey(command, dependencies: dependencies)
        case .compress(let arguments):
            try executeCompress(arguments, dependencies: dependencies)
        case .extract(let arguments):
            let result = try dependencies.archives.extract(
                archive: arguments.archive, destination: arguments.output,
                password: arguments.password, keyProvider: dependencies.identityStore
            )
            dependencies.output("Extracted to: \(result.destinationPath)")
            printSignature(result.securityInfo?.signature, output: dependencies.output)
        case .list(let arguments):
            let listing = try dependencies.archives.list(
                archive: arguments.archive, password: arguments.password,
                keyProvider: dependencies.identityStore
            )
            for entry in listing.entries {
                dependencies.output("\(entry.isDirectory ? "directory" : "file")\t\(entry.size)\t\(entry.path)")
            }
            dependencies.output("Total: \(listing.entries.count)")
            printSignature(listing.securityInfo?.signature, output: dependencies.output)
        case .rename(let arguments):
            try executeRename(arguments, dependencies: dependencies)
        }
    }

    private static func executeRename(_ arguments: RenameArguments, dependencies: ZwzCLIDependencies) throws {
        // 1. List archive contents
        let listing = try dependencies.archives.list(
            archive: arguments.archive, password: arguments.password,
            keyProvider: dependencies.identityStore
        )

        // 2. Filter entries (only top-level items, or apply filter)
        var entries = listing.entries.filter { entry in
            // Only rename top-level items (no "/" in path after root)
            let path = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return !path.contains("/")
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if let filterPattern = arguments.filter {
            let filter = globRegex(pattern: filterPattern)
            entries = entries.filter { entry in
                matchesGlob(entry.name, regex: filter)
            }
        }

        guard !entries.isEmpty else {
            dependencies.output("No items to rename.")
            return
        }

        // 3. Compute batch rename results
        let config = BatchRenameConfig(rule: arguments.rule, includeExtension: arguments.includeExtension)
        let inputEntries = entries.map { (name: $0.name, isDirectory: $0.isDirectory) }
        let results = try BatchRenameEngine.compute(entries: inputEntries, config: config)

        // 4. Print preview
        dependencies.output("Batch rename preview (\(results.count) items):")
        for (index, item) in results.enumerated() {
            let original = entries[index].path
            if item.originalName == item.finalName {
                dependencies.output("  \(original)  →  \(item.finalName)  (no change)")
            } else if item.hasConflict {
                dependencies.output("  \(original)  →  \(item.finalName)  (conflict auto-numbered)")
            } else {
                dependencies.output("  \(original)  →  \(item.finalName)")
            }
        }

        if arguments.dryRun {
            dependencies.output("\nDry run — no changes made.")
            return
        }

        // 5. Extract to temp, rename files, repack
        let tempDir = dependencies.fileManager.temporaryDirectory
            .appendingPathComponent("zwz-rename-\(UUID().uuidString)", isDirectory: true)
        try dependencies.fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? dependencies.fileManager.removeItem(at: tempDir) }

        // Extract
        _ = try dependencies.archives.extract(
            archive: arguments.archive, destination: tempDir.path,
            password: arguments.password, keyProvider: dependencies.identityStore
        )

        let renames = zip(entries, results).compactMap { entry, item -> (source: URL, destination: URL)? in
            guard item.originalName != item.finalName else { return nil }
            let source = tempDir.appendingPathComponent(entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            return (source, source.deletingLastPathComponent().appendingPathComponent(item.finalName))
        }
        try applyFileRenames(renames, fileManager: dependencies.fileManager)

        // 6. Repack - detect format and compress back
        let archiveURL = URL(fileURLWithPath: arguments.archive)
        let ext = archiveURL.pathExtension.lowercased()
        let format: CompressionFormat = ext == "zwz" ? .zwz : .zip
        let encryption = try renameEncryption(
            securityInfo: listing.securityInfo,
            password: arguments.password,
            identityStore: dependencies.identityStore
        )
        let options = CompressionOptions(level: .normal, encryption: encryption, aes256: true, format: format)
        _ = try dependencies.archives.compress(
            source: tempDir.path, destination: arguments.archive,
            options: options, keyProvider: dependencies.identityStore
        )

        dependencies.output("\nApplied \(results.filter { $0.originalName != $0.finalName }.count) renames to \(archiveURL.lastPathComponent).")
    }

    private static func renameEncryption(
        securityInfo: ZwzArchiveSecurityInfo?,
        password: String?,
        identityStore: any ZwzIdentityStore
    ) throws -> ZwzEncryptionMode {
        guard let securityInfo else {
            return password.map(ZwzEncryptionMode.password) ?? .none
        }
        switch securityInfo.encryption {
        case .none:
            return .none
        case .password:
            guard let password, !password.isEmpty else {
                throw CLIParseError.invalid("The original archive password is required to preserve encryption")
            }
            return .password(password)
        case .publicKey:
            let recipients = try securityInfo.recipientFingerprints.map { fingerprint in
                let identity = try resolveAny(fingerprint, store: identityStore)
                return ZwzRecipient(
                    name: identity.name,
                    fingerprint: identity.fingerprint,
                    agreementPublicKey: identity.agreementPublicKey
                )
            }
            let signerFingerprint: String?
            switch securityInfo.signature {
            case .unsigned:
                signerFingerprint = nil
            case .validKnownSigner(_, let fingerprint), .validUnknownSigner(_, let fingerprint):
                signerFingerprint = fingerprint
            case .invalid:
                throw ZwzV3Error.invalidSignature
            }
            let signer: ZwzSigningIdentity?
            if let signerFingerprint {
                let identity = try resolveLocal(signerFingerprint, store: identityStore)
                signer = ZwzSigningIdentity(
                    name: identity.name,
                    fingerprint: identity.fingerprint,
                    agreementPublicKey: identity.agreementPublicKey,
                    signingPublicKey: identity.signingPublicKey
                )
            } else {
                signer = nil
            }
            return .publicKey(recipients: recipients, signer: signer)
        }
    }

    private static func applyFileRenames(
        _ renames: [(source: URL, destination: URL)],
        fileManager: FileManager
    ) throws {
        let staged = renames.map { item in
            (
                source: item.source,
                temporary: item.source.deletingLastPathComponent()
                    .appendingPathComponent(".zwz-batch-rename-\(UUID().uuidString)"),
                destination: item.destination
            )
        }
        var stagedCount = 0
        do {
            for item in staged {
                try fileManager.moveItem(at: item.source, to: item.temporary)
                stagedCount += 1
            }
        } catch {
            for item in staged.prefix(stagedCount).reversed() {
                try? fileManager.moveItem(at: item.temporary, to: item.source)
            }
            throw error
        }

        var completedCount = 0
        do {
            for item in staged {
                try fileManager.moveItem(at: item.temporary, to: item.destination)
                completedCount += 1
            }
        } catch {
            for item in staged.prefix(completedCount).reversed() {
                try? fileManager.moveItem(at: item.destination, to: item.source)
            }
            for item in staged.dropFirst(completedCount).reversed() {
                try? fileManager.moveItem(at: item.temporary, to: item.source)
            }
            throw error
        }
    }

    private static func globRegex(pattern: String) -> NSRegularExpression? {
        // Simple glob: * matches any, ? matches single char
        let expression = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "?", with: ".")
        return try? NSRegularExpression(pattern: "^\(expression)$")
    }

    private static func matchesGlob(_ name: String, regex: NSRegularExpression?) -> Bool {
        guard let regex else { return false }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    private static func executeCompress(_ arguments: CompressArguments, dependencies: ZwzCLIDependencies) throws {
        let encryption: ZwzEncryptionMode
        if !arguments.recipients.isEmpty {
            let resolved = try resolveRecipients(arguments.recipients, store: dependencies.identityStore)
            let recipients = resolved.map {
                ZwzRecipient(name: $0.name, fingerprint: $0.fingerprint, agreementPublicKey: $0.agreementPublicKey)
            }
            let signer: ZwzSigningIdentity?
            if let requested = arguments.signer {
                let identity = try resolveLocal(requested, store: dependencies.identityStore)
                signer = ZwzSigningIdentity(
                    name: identity.name, fingerprint: identity.fingerprint,
                    agreementPublicKey: identity.agreementPublicKey,
                    signingPublicKey: identity.signingPublicKey
                )
            } else {
                signer = nil
            }
            encryption = .publicKey(recipients: recipients, signer: signer)
        } else if let password = arguments.password {
            encryption = .password(password)
        } else {
            encryption = .none
        }
        let options = CompressionOptions(
            level: arguments.level, encryption: encryption, aes256: arguments.aes256,
            splitVolume: arguments.splitVolume, format: arguments.format,
            threadCount: arguments.threadCount
        )
        let output = try dependencies.archives.compress(
            source: arguments.source, destination: arguments.output,
            options: options, keyProvider: dependencies.identityStore
        )
        dependencies.output("Created: \(output)")
    }

    private static func executeKey(_ command: KeyArguments, dependencies: ZwzCLIDependencies) throws {
        let store = dependencies.identityStore
        switch command {
        case .create(let name):
            let identity = try store.createIdentity(named: name)
            dependencies.output("Created identity: \(identity.name) \(identity.fingerprint)")
        case .list:
            for identity in try store.identities() {
                dependencies.output("local\t\(identity.name)\t\(identity.fingerprint)")
            }
            for contact in try store.contacts() {
                dependencies.output("contact\t\(contact.name)\t\(contact.fingerprint)")
            }
        case .rename(let requested, let name):
            let identity = try resolveAny(requested, store: store)
            try store.rename(fingerprint: identity.fingerprint, to: name)
            dependencies.output("Renamed: \(identity.fingerprint)")
        case .delete(let requested, let confirmed):
            let identity = try resolveAny(requested, store: store)
            dependencies.error("Warning: deleting '\(identity.name)' permanently removes any associated private keys.")
            if !confirmed {
                let answer = dependencies.confirmationReader(
                    "Permanently delete '\(identity.name)' and any private keys? [y/N] "
                )?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard answer == "y" || answer == "yes" else {
                    throw CLIParseError.invalid("Deletion cancelled")
                }
            }
            try store.delete(fingerprint: identity.fingerprint)
            dependencies.output("Deleted: \(identity.fingerprint)")
        case .exportPublic(let requested, let output):
            try requireNewOutput(output, dependencies: dependencies)
            let identity = try resolveAny(requested, store: store)
            let data = try store.exportPublicIdentity(fingerprint: identity.fingerprint)
            try writeNewFileAtomically(data, path: output, dependencies: dependencies)
            dependencies.output("Exported public identity: \(output)")
        case .importPublic(let input, let replace):
            let data = try Data(contentsOf: URL(fileURLWithPath: input))
            let identity = try store.importPublicIdentity(
                data, conflict: replace ? .replaceExisting : .requireConfirmation
            )
            dependencies.output("Imported public identity: \(identity.name) \(identity.fingerprint)")
        case .backup(let requested, let output):
            try requireNewOutput(output, dependencies: dependencies)
            let identity = try resolveLocal(requested, store: store)
            let password = try readNonemptyPassword("Backup password: ", dependencies: dependencies)
            let confirmation = try readNonemptyPassword("Confirm backup password: ", dependencies: dependencies)
            guard password == confirmation else { throw CLIParseError.invalid("Backup passwords do not match") }
            let data = try store.exportPrivateBackup(fingerprint: identity.fingerprint, password: password)
            try writeNewFileAtomically(data, path: output, dependencies: dependencies)
            dependencies.output("Created encrypted backup: \(output)")
        case .restore(let input, let replace):
            let password = try readNonemptyPassword("Backup password: ", dependencies: dependencies)
            let data = try Data(contentsOf: URL(fileURLWithPath: input))
            let identity = try store.importPrivateBackup(
                data, password: password,
                conflict: replace ? .replaceExisting : .requireConfirmation
            )
            dependencies.output("Restored identity: \(identity.name) \(identity.fingerprint)")
        }
    }

    private static func readNonemptyPassword(_ prompt: String, dependencies: ZwzCLIDependencies) throws -> String {
        let password = try dependencies.passwordReader(prompt)
        guard !password.isEmpty else { throw CLIParseError.invalid("Password must not be empty") }
        return password
    }

    private static func writeNewFileAtomically(_ data: Data, path: String, dependencies: ZwzCLIDependencies) throws {
        let output = URL(fileURLWithPath: path)
        try requireNewOutput(path, dependencies: dependencies)
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? dependencies.fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try dependencies.fileManager.moveItem(at: temporary, to: output)
    }

    private static func requireNewOutput(_ path: String, dependencies: ZwzCLIDependencies) throws {
        guard !dependencies.fileManager.fileExists(atPath: path) else {
            throw CLIParseError.invalid("Output already exists: \(path)")
        }
    }

    private static func resolveRecipients(_ requests: [String], store: any ZwzIdentityStore) throws -> [ZwzPublicIdentity] {
        var result: [ZwzPublicIdentity] = []
        var seen = Set<String>()
        for request in requests {
            let identity = try resolveAny(request, store: store)
            if seen.insert(identity.fingerprint).inserted { result.append(identity) }
        }
        return result
    }

    private static func resolveLocal(_ request: String, store: any ZwzIdentityStore) throws -> ZwzPublicIdentity {
        try resolve(request, candidates: try store.identities().map(\.publicIdentity))
    }

    private static func resolveAny(_ request: String, store: any ZwzIdentityStore) throws -> ZwzPublicIdentity {
        try resolve(request, candidates: try store.identities().map(\.publicIdentity) + store.contacts())
    }

    private static func resolve(_ request: String, candidates: [ZwzPublicIdentity]) throws -> ZwzPublicIdentity {
        if request.count == 64,
           request.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) }) {
            guard let exact = candidates.first(where: { $0.fingerprint == request }) else {
                throw CLIResolutionError.notFound(request)
            }
            return exact
        }
        let matches = candidates.filter { $0.name.caseInsensitiveCompare(request) == .orderedSame }
        guard !matches.isEmpty else { throw CLIResolutionError.notFound(request) }
        guard matches.count == 1 else { throw CLIResolutionError.ambiguous(request, matches.map(\.fingerprint)) }
        return matches[0]
    }

    private static func printSignature(_ signature: ZwzSignatureVerification?, output: (String) -> Void) {
        guard let signature else { return }
        switch signature {
        case .unsigned: output("Signature: unsigned")
        case .validKnownSigner(let name, let fingerprint): output("Signature: valid known signer \(name) \(fingerprint)")
        case .validUnknownSigner(let name, let fingerprint): output("Signature: valid unknown signer \(name) \(fingerprint)")
        case .invalid: output("Signature: invalid")
        }
    }

    private static func report(_ error: Error, dependencies: ZwzCLIDependencies, archive: String?) {
        if case CLIResolutionError.ambiguous(let name, let fingerprints) = error {
            dependencies.error("Ambiguous identity '\(name)'. Matching fingerprints:")
            fingerprints.forEach(dependencies.error)
            return
        }
        if case ZwzV3Error.noMatchingPrivateKey(let fingerprints) = error {
            dependencies.error("No matching private key is available. Archive recipients:")
            let info = archive.flatMap { try? dependencies.archives.recipientInfo(archive: $0) } ?? []
            if info.isEmpty {
                fingerprints.forEach(dependencies.error)
            } else {
                info.forEach { dependencies.error("\($0.name) \($0.fingerprint)") }
            }
            dependencies.error("zwz key restore <backup.zwzkey>")
            return
        }
        dependencies.error(error.localizedDescription)
    }

    private static func archivePath(from arguments: [String]) -> String? {
        guard let command = arguments.first?.lowercased(), ["x", "extract", "l", "list"].contains(command) else { return nil }
        var index = 1
        while index < arguments.count {
            if ["-p", "--password"].contains(arguments[index]) { index += 2; continue }
            if !arguments[index].hasPrefix("-") { return arguments[index] }
            index += 1
        }
        return nil
    }

    static let usage = """
    zwz - archive and public-key identity tool
    Usage:
      zwz compress [options] <source-path> [output-path]
      zwz extract [options] <archive-path> [output-directory]
      zwz list [options] <archive-path>
      zwz rename [options] <archive-path>
      zwz key <operation> [options]

    Commands:
      c, compress    Create an archive
      x, extract     Extract an archive
      l, list        List archive contents
      rename         Batch rename archive entries
      h, help        Show this help

    Compression options:
      -f, --format <zip|zwz>                    Archive format (default: zip)
      -l, --level <none|fastest|normal|max>     Compression level (default: normal)
      -p, --password <password>                 Password encryption
      --no-aes                                  Disable AES-256 for supported legacy formats
      -s, --split <positive-size>               Split size in MB or KB, for example 100MB
      -t, --threads <nonnegative-count>         Worker count; 0 selects automatically
      --recipient <name-or-fingerprint>         Repeat for multiple recipients; requires -f zwz
      --sign <local-identity-or-fingerprint>    Requires -f zwz and at least one --recipient

    Password encryption and --recipient/--sign public-key encryption are mutually exclusive.

    Extract and list options:
      -p, --password <password>                 Password for a password-encrypted archive

    Batch rename options:
      --rule <find-replace|prefix-suffix|numbering|regex-replace|case-conversion>
                                                Rename rule (required)
      --find <text> --replace <text>             Find-and-replace parameters
      --prefix <text> --suffix <text>            Prefix/suffix parameters
      --start <n> --step <n> --digits <n>        Numbering parameters
      --numbering-prefix <text>                  Prefix for simple numbering
      --numbering-template <template>            Numbering template, such as {seq:3}_photo
      --pattern <regex> --template <template>    Regular-expression parameters
      --case-mode <upper|lower|title|camel|snake>
      --include-extension                        Include the extension in rule matching
      --filter <glob>                            Rename matching top-level entries only
      --dry-run                                  Preview without modifying the archive
      -p, --password <password>                  Password for a password-encrypted archive

    Key commands:
      key create <name>
      key list
      key rename <identity-or-fingerprint> <new-name>
      key delete [--yes] <identity-or-fingerprint>
      key export-public <identity-or-fingerprint> <output.zwzpub>
      key import-public [--replace] <input.zwzpub>
      key backup <identity-or-fingerprint> <output.zwzkey>
      key restore [--replace] <input.zwzkey>

    Backup and restore passwords are read from stdin. On a TTY, input is hidden; backup asks
    for confirmation. Backup passwords are never accepted as command arguments or environment options.

    Examples:
      zwz c -f zip -l max Documents documents.zip
      zwz c -f zwz -s 100MB Source source.zwz
      zwz c -f zwz --recipient Alice --recipient Bob --sign Me Source shared.zwz
      zwz x -p secret archive.zwz extracted
      zwz l archive.zwz
      zwz key export-public Alice alice.zwzpub
      zwz key backup Me me.zwzkey
      zwz key restore me.zwzkey
    """
}

private enum CLIResolutionError: LocalizedError {
    case notFound(String)
    case ambiguous(String, [String])

    var errorDescription: String? {
        switch self {
        case .notFound(let value): return "No identity matches '\(value)'"
        case .ambiguous(let value, _): return "Multiple identities match '\(value)'"
        }
    }
}
