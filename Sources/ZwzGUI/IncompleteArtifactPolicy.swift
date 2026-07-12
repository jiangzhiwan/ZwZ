import Foundation

enum IncompleteArtifactPolicy: String, CaseIterable, Codable {
    case delete
    case preservePartial
    case ask
}

enum WorkspaceSettings {
    static let restoreTabsKey = "zwz_restore_tabs"
    static let cancelledArtifactPolicyKey = "zwz_cancelled_artifact_policy"

    static func restoreTabs(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: restoreTabsKey) as? Bool ?? false
    }

    static func artifactPolicy(defaults: UserDefaults = .standard) -> IncompleteArtifactPolicy {
        defaults.string(forKey: cancelledArtifactPolicyKey).flatMap(IncompleteArtifactPolicy.init(rawValue:)) ?? .delete
    }
}
