import Foundation
import ZwzCore

struct SmartExtractionPlan: Equatable {
    let extractionDirectory: URL
    let resultDirectory: URL
    let extractedTopLevelName: String?
}

enum SmartExtractionPlanner {
    static func makePlan(
        archiveURL: URL,
        entries: [ArchiveEntry],
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) -> SmartExtractionPlan {
        let parent = archiveURL.deletingLastPathComponent()
        let topLevelNames = Set(entries.compactMap { topLevelName(for: $0.path) })

        if topLevelNames.count == 1, let topLevelName = topLevelNames.first {
            let preferredResult = parent.appendingPathComponent(topLevelName, isDirectory: true)
            if !fileManager.fileExists(atPath: preferredResult.path) {
                return SmartExtractionPlan(
                    extractionDirectory: parent,
                    resultDirectory: preferredResult,
                    extractedTopLevelName: nil
                )
            }

            let uniqueResult = uniqueDirectoryURL(for: preferredResult, fileManager: fileManager)
            let stagingRoot = temporaryDirectory ?? fileManager.temporaryDirectory
            let stagingDirectory = stagingRoot.appendingPathComponent("zwz-smart-\(UUID().uuidString)", isDirectory: true)
            return SmartExtractionPlan(
                extractionDirectory: stagingDirectory,
                resultDirectory: uniqueResult,
                extractedTopLevelName: topLevelName
            )
        }

        let preferredResult = parent.appendingPathComponent(archiveBaseName(archiveURL), isDirectory: true)
        let result = uniqueDirectoryURL(for: preferredResult, fileManager: fileManager)
        return SmartExtractionPlan(
            extractionDirectory: result,
            resultDirectory: result,
            extractedTopLevelName: nil
        )
    }

    static func finalize(_ plan: SmartExtractionPlan, fileManager: FileManager = .default) throws {
        guard let topLevelName = plan.extractedTopLevelName else { return }
        let stagedResult = plan.extractionDirectory.appendingPathComponent(topLevelName, isDirectory: true)
        try fileManager.moveItem(at: stagedResult, to: plan.resultDirectory)
        try? fileManager.removeItem(at: plan.extractionDirectory)
    }

    private static func topLevelName(for path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init)
    }

    private static func archiveBaseName(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(".tar.gz") {
            return String(name.dropLast(7))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func uniqueDirectoryURL(for preferred: URL, fileManager: FileManager) -> URL {
        guard fileManager.fileExists(atPath: preferred.path) else { return preferred }
        var suffix = 2
        while true {
            let candidate = preferred
                .deletingLastPathComponent()
                .appendingPathComponent("\(preferred.lastPathComponent) \(suffix)", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }
}
