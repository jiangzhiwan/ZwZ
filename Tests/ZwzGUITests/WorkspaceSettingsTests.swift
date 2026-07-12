import XCTest
@testable import ZwzGUI

final class WorkspaceSettingsTests: XCTestCase {
    func testDefaultsAndPolicyRoundTrip() throws {
        let suite = "WorkspaceSettingsTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(WorkspaceSettings.restoreTabs(defaults: defaults))
        XCTAssertEqual(WorkspaceSettings.artifactPolicy(defaults: defaults), .delete)
        for policy in IncompleteArtifactPolicy.allCases {
            defaults.set(policy.rawValue, forKey: WorkspaceSettings.cancelledArtifactPolicyKey)
            XCTAssertEqual(WorkspaceSettings.artifactPolicy(defaults: defaults), policy)
        }
    }
}
