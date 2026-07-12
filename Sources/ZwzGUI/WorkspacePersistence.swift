import Foundation

enum WorkspacePersistenceError: Error {
    case unsupportedVersion(Int)
}

struct WorkspacePersistence {
    let url: URL

    init(url: URL = Self.defaultURL) { self.url = url }

    func load() throws -> WorkspaceSnapshot {
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == WorkspaceSnapshot.currentVersion else {
            throw WorkspacePersistenceError.unsupportedVersion(snapshot.version)
        }
        return snapshot
    }

    func save(_ snapshot: WorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    private static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ZwZ/workspace-v1.json")
    }
}
