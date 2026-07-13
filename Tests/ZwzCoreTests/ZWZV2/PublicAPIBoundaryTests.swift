import Foundation
import XCTest
import ZwzCore

final class PublicAPIBoundaryTests: XCTestCase {
    func testPublicV2ValueTypesCanBeConstructedAcrossPackageBoundary() {
        let block = ZwzV2BlockDescriptor(
            sequence: 1,
            fileOffset: 2,
            archiveOffset: 3,
            storedLength: 4,
            originalLength: 5,
            codec: .store,
            checksum: 6,
            authenticationTag: [7, 8]
        )
        let entry = ZwzV2Entry(
            path: "file.txt",
            type: .file,
            originalSize: 9,
            modificationTime: Date(timeIntervalSince1970: 10),
            isHidden: false,
            blocks: [block]
        )
        let index = ZwzV2Index(
            archiveID: UUID(),
            blockSize: 11,
            entries: [entry]
        )

        XCTAssertEqual(index.entries, [entry])
        XCTAssertEqual(index.entries[0].blocks, [block])
    }
}
