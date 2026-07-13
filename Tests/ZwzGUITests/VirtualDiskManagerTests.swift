import XCTest
@testable import ZwzGUI

final class VirtualDiskManagerTests: XCTestCase {
    func testSessionOwnerRoundTripsAndOlderJSONDefaultsToNil() throws {
        let owner = UUID()
        let session = VirtualDiskSession(archivePath: "a.zwz", imagePath: "a", mountPath: "m", capacityMB: 256, baselineFingerprint: "x", splitVolumeBytes: nil, isMounted: true, ownerTabID: owner)
        XCTAssertEqual(try JSONDecoder().decode(VirtualDiskSession.self, from: JSONEncoder().encode(session)).ownerTabID, owner)

        let oldJSON = #"{"archivePath":"a.zwz","imagePath":"a","mountPath":"m","capacityMB":256,"baselineFingerprint":"x","isMounted":true}"#
        XCTAssertNil(try JSONDecoder().decode(VirtualDiskSession.self, from: Data(oldJSON.utf8)).ownerTabID)

        let legacyWithPassword = #"{"archivePath":"a.zwz","imagePath":"a","mountPath":"m","password":"legacy secret","capacityMB":256,"baselineFingerprint":"x","isMounted":true}"#
        let migrated = try JSONDecoder().decode(VirtualDiskSession.self, from: Data(legacyWithPassword.utf8))
        let migratedJSON = String(decoding: try JSONEncoder().encode(migrated), as: UTF8.self)
        XCTAssertEqual(migrated.protection?.securityInfo?.encryption, .password)
        XCTAssertFalse(migratedJSON.contains("legacy secret"))
        XCTAssertFalse(migratedJSON.localizedCaseInsensitiveContains("password"))
    }
    func testRecommendedCapacityAddsHeadroomAndRoundsTo256MB() {
        XCTAssertEqual(VirtualDiskManager.recommendedCapacityMB(uncompressedBytes: 0), 256)
        XCTAssertEqual(VirtualDiskManager.recommendedCapacityMB(uncompressedBytes: 1), 512)
        XCTAssertEqual(VirtualDiskManager.recommendedCapacityMB(uncompressedBytes: 256 * 1_048_576), 512)
        XCTAssertEqual(VirtualDiskManager.recommendedCapacityMB(uncompressedBytes: 257 * 1_048_576), 768)
    }

    func testSessionRoundTripsThroughJSON() throws {
        let session = VirtualDiskSession(
            archivePath: "/tmp/a.zwz",
            imagePath: "/tmp/a.sparsebundle",
            mountPath: "/tmp/mount",
            capacityMB: 512,
            baselineFingerprint: "fingerprint",
            splitVolumeBytes: 262_144,
            isMounted: true
        )
        let decoded = try JSONDecoder().decode(VirtualDiskSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded, session)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(session), as: UTF8.self).contains("password"))
    }
}
