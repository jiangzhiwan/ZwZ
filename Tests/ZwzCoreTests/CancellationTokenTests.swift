import XCTest
@testable import ZwzCore

final class CancellationTokenTests: XCTestCase {
    func testCancellationIsIdempotentAndObservableAcrossThreads() async {
        let token = CancellationToken()
        XCTAssertFalse(token.isCancelled)
        await Task.detached { token.cancel(); token.cancel() }.value
        XCTAssertTrue(token.isCancelled)
    }

    func testCheckCancellationThrowsDedicatedError() {
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try token.checkCancellation()) { error in
            guard case ZwzError.operationCancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
