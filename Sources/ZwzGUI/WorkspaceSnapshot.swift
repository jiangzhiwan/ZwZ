import Foundation

struct WorkspaceSnapshot: Codable, Equatable {
    static let currentVersion = 1
    let version: Int
    let tabs: [WorkspaceTabSnapshot]
    let selectedTabID: UUID
}

struct WorkspaceTabSnapshot: Codable, Equatable {
    let id: UUID
    let kind: WorkspaceTabKind
    let sourcePath: String?
    let wasRunning: Bool
}
