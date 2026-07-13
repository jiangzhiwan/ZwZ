import XCTest
@testable import ZwzCore

final class ZwzV2TypesTests: XCTestCase {
    func testDefaultOptionsAreBoundedAndStrict() {
        let options = ZwzV2Options()
        XCTAssertEqual(options.blockSize, ZwzV2Format.defaultBlockSize)
        XCTAssertEqual(options.compressionLevel, .normal)
        XCTAssertEqual(options.recoveryPolicy, .strict)
        XCTAssertGreaterThanOrEqual(options.threadCount, 1)
        XCTAssertLessThanOrEqual(options.maxInFlightBlocks, max(2, options.threadCount * 2))
    }

    func testUnsupportedVersionErrorMessageIsClear() {
        let error = ZwzV2Error.unsupportedVersion(1)
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("unsupported"))
        XCTAssertTrue(error.localizedDescription.contains("1"))
    }
}
