import XCTest
@testable import ZwzCore

final class ZwzV3TypesTests: XCTestCase {
    func testCompressionOptionsMapsLegacyPassword() {
        XCTAssertEqual(
            CompressionOptions(password: "secret", format: .zwz).encryption,
            .password("secret")
        )
        XCTAssertEqual(CompressionOptions(format: .zwz).encryption, .none)
    }

    func testCompressionOptionsAcceptsExplicitEncryptionMode() {
        let recipient = ZwzRecipient(
            name: "Alice",
            fingerprint: "alice-fingerprint",
            agreementPublicKey: Data([1, 2, 3])
        )

        let options = CompressionOptions(
            encryption: .publicKey(recipients: [recipient], signer: nil),
            format: .zwz
        )

        XCTAssertEqual(
            options.encryption,
            .publicKey(recipients: [recipient], signer: nil)
        )
        XCTAssertNil(options.password)
    }

    func testExplicitPasswordEncryptionMapsLegacyPasswordProperty() {
        let options = CompressionOptions(encryption: .password("secret"), format: .zwz)

        XCTAssertEqual(options.password, "secret")
    }

    func testPublicKeyModeRequiresRecipient() {
        XCTAssertThrowsError(
            try ZwzEncryptionMode.publicKey(recipients: [], signer: nil).validated()
        ) {
            XCTAssertEqual($0 as? ZwzV3Error, .recipientRequired)
        }
    }

    func testArchiveSecurityInfoDefaultsToUnsignedWithNoRecipients() {
        let info = ZwzArchiveSecurityInfo(encryption: .none)

        XCTAssertEqual(info.encryption, .none)
        XCTAssertEqual(info.recipientFingerprints, [])
        XCTAssertEqual(info.signature, .unsigned)
    }
}
