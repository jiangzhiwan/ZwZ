import CryptoKit
import Foundation
@testable import ZwzCore

struct ZwzV3WrappedFixture {
    let archiveID: UUID
    let contentKey: SymmetricKey
    let recipientKey: Curve25519.KeyAgreement.PrivateKey
    let wrongKey: Curve25519.KeyAgreement.PrivateKey
    let envelopes: [ZwzV3RecipientEnvelope]
}

func makeWrappedFixture() throws -> ZwzV3WrappedFixture {
    let archiveID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
    let contentKey = SymmetricKey(size: .bits256)
    let recipientKey = Curve25519.KeyAgreement.PrivateKey()
    let wrongKey = Curve25519.KeyAgreement.PrivateKey()
    let recipient = ZwzRecipient(
        name: "Alice",
        fingerprint: ZwzV3Crypto.fingerprint(
            agreement: recipientKey.publicKey.rawRepresentation,
            signing: nil
        ),
        agreementPublicKey: recipientKey.publicKey.rawRepresentation
    )
    return ZwzV3WrappedFixture(
        archiveID: archiveID,
        contentKey: contentKey,
        recipientKey: recipientKey,
        wrongKey: wrongKey,
        envelopes: try ZwzV3Crypto.wrap(
            contentKey: contentKey,
            recipients: [recipient],
            archiveID: archiveID
        )
    )
}

extension SymmetricKey {
    var testBytes: Data { withUnsafeBytes { Data($0) } }
}
