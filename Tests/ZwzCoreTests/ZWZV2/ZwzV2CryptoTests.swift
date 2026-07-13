import XCTest
@testable import ZwzCore

final class ZwzV2CryptoTests: XCTestCase {
    func testBlockEncryptionRoundTripsAndRejectsWrongPassword() throws {
        let archiveID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let salt = Data(repeating: 7, count: 16)
        let good = try ZwzV2Crypto.deriveContext(password: "secret", salt: salt, iterations: 1_000, archiveID: archiveID)
        let bad = try ZwzV2Crypto.deriveContext(password: "wrong", salt: salt, iterations: 1_000, archiveID: archiveID)
        let sealed = try ZwzV2Crypto.sealBlock(Data("hidden".utf8), sequence: 42, context: good)

        XCTAssertEqual(try ZwzV2Crypto.openBlock(sealed.ciphertext, tag: sealed.tag, sequence: 42, context: good), Data("hidden".utf8))
        XCTAssertThrowsError(try ZwzV2Crypto.openBlock(sealed.ciphertext, tag: sealed.tag, sequence: 42, context: bad)) { error in
            XCTAssertEqual(error as? ZwzV2Error, .wrongPasswordOrTamperedData)
        }
    }

    func testIndexUsesDifferentNonceDomainThanBlock() throws {
        let archiveID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let context = try ZwzV2Crypto.deriveContext(password: "secret", salt: Data(repeating: 8, count: 16), iterations: 1_000, archiveID: archiveID)
        let block = try ZwzV2Crypto.sealBlock(Data("payload".utf8), sequence: 0, context: context)
        let index = try ZwzV2Crypto.sealIndex(Data("payload".utf8), context: context)
        XCTAssertNotEqual(block.ciphertext + block.tag, index.ciphertext + index.tag)
    }
}
