import Foundation

public enum ZwzV2PathValidator {
    public static func normalizedArchivePath(root: URL, item: URL) throws -> String {
        let normalizedRoot = root.standardizedFileURL
        let normalizedItem = item.standardizedFileURL
        let rootComponents = normalizedRoot.pathComponents
        let itemComponents = normalizedItem.pathComponents

        guard itemComponents.starts(with: rootComponents), itemComponents.count > rootComponents.count else {
            throw ZwzV2Error.unsafePath(item.path)
        }

        return try archivePath(from: Array(itemComponents.dropFirst(rootComponents.count)))
    }

    public static func validateExtractionPath(_ archivePath: String, destination: URL) throws -> URL {
        let components = try archivePathComponents(archivePath)
        let normalizedDestination = destination.standardizedFileURL
        let extractionURL = components.reduce(normalizedDestination) { partialResult, component in
            partialResult.appendingPathComponent(component)
        }.standardizedFileURL

        guard extractionURL.pathComponents.starts(with: normalizedDestination.pathComponents) else {
            throw ZwzV2Error.unsafePath(archivePath)
        }

        return extractionURL
    }

    public static func validateNoDuplicatePaths(_ entries: [ZwzV2Entry]) throws {
        var paths = Set<String>()
        var filePaths = Set<String>()

        for entry in entries {
            let normalizedPath = try archivePath(from: archivePathComponents(entry.path))
            let comparisonPath = comparisonPath(for: normalizedPath)

            guard paths.insert(comparisonPath).inserted else {
                throw ZwzV2Error.duplicatePath(entry.path)
            }

            let components = comparisonPath.split(separator: "/")
            let hasFileAncestor = components.dropLast().indices.contains { index in
                let ancestor = components[...index].joined(separator: "/")
                return filePaths.contains(ancestor)
            }

            guard !hasFileAncestor else {
                throw ZwzV2Error.duplicatePath(entry.path)
            }

            if entry.type == .file {
                let descendantPrefix = comparisonPath + "/"
                guard !paths.contains(where: { $0.hasPrefix(descendantPrefix) }) else {
                    throw ZwzV2Error.duplicatePath(entry.path)
                }
                filePaths.insert(comparisonPath)
            }
        }
    }

    private static func comparisonPath(for path: String) -> String {
        path.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func archivePath(from components: [String]) throws -> String {
        let archivePath = components.joined(separator: "/")
        _ = try archivePathComponents(archivePath)
        return archivePath
    }

    private static func archivePathComponents(_ archivePath: String) throws -> [String] {
        guard !archivePath.isEmpty,
              !archivePath.utf8.contains(0),
              !archivePath.hasPrefix("/"),
              !archivePath.hasPrefix("\\"),
              !hasWindowsDrivePrefix(archivePath) else {
            throw ZwzV2Error.unsafePath(archivePath)
        }

        let components = archivePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            throw ZwzV2Error.unsafePath(archivePath)
        }

        return components
    }

    private static func hasWindowsDrivePrefix(_ path: String) -> Bool {
        guard path.count >= 3 else {
            return false
        }

        let characters = Array(path)
        return characters[0].isASCII && characters[0].isLetter && characters[1] == ":" && (characters[2] == "/" || characters[2] == "\\")
    }
}
