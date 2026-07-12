import Foundation
import ZwzCore

enum ArchiveEntryHierarchy {
    struct BreadcrumbPart: Equatable, Hashable, Identifiable, Sendable {
        let name: String
        let path: String

        var id: String { path }
    }

    static func immediateChildren(
        of entries: [ArchiveEntry],
        in directoryPath: String,
        showHiddenFiles: Bool
    ) -> [ArchiveEntry] {
        let directoryPath = normalizedDirectoryPath(directoryPath)
        let explicitDirectories = entries.reduce(into: [String: ArchiveEntry]()) { result, entry in
            guard entry.isDirectory else { return }
            let path = normalizedDirectoryPath(entry.path)
            guard !path.isEmpty, result[path] == nil else { return }
            result[path] = entry
        }

        var seenNames = Set<String>()
        var children: [ArchiveEntry] = []

        for entry in entries {
            let path = normalizedPath(entry.path)
            guard !path.isEmpty else { continue }
            guard showHiddenFiles || !ArchiveEntryPresentation.isHidden(path: path) else { continue }
            guard directoryPath.isEmpty || path.hasPrefix(directoryPath) else { continue }

            let relativePath = String(path.dropFirst(directoryPath.count))
            let components = relativePath.split(separator: "/", maxSplits: 1)
            guard let firstComponent = components.first, !firstComponent.isEmpty else { continue }

            let name = String(firstComponent)
            guard seenNames.insert(name).inserted else { continue }

            if components.count > 1 || entry.isDirectory {
                let childPath = normalizedDirectoryPath(directoryPath + name)
                if let explicitDirectory = explicitDirectories[childPath] {
                    children.append(explicitDirectory)
                } else {
                    children.append(ArchiveEntry(
                        name: name,
                        path: childPath,
                        size: 0,
                        isDirectory: true,
                        modifiedDate: nil
                    ))
                }
            } else {
                children.append(entry)
            }
        }

        return children
    }

    static func normalizedDirectoryPath(_ path: String) -> String {
        let path = normalizedPath(path)
        return path.isEmpty ? "" : path + "/"
    }

    static func breadcrumbParts(
        for directoryPath: String,
        rootName: String = "根目录"
    ) -> [BreadcrumbPart] {
        var parts = [BreadcrumbPart(name: rootName, path: "")]
        var accumulatedPath = ""

        for component in normalizedPath(directoryPath).split(separator: "/") {
            accumulatedPath += String(component) + "/"
            parts.append(BreadcrumbPart(name: String(component), path: accumulatedPath))
        }

        return parts
    }

    private static func normalizedPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
            .joined(separator: "/")
    }
}
