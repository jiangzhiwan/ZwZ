import Foundation

public enum ZwzV3ArchiveCodec {
    public static func encode(
        recipients: [ZwzV3RecipientEnvelope],
        dataRegion: Data,
        encryptedIndex: Data,
        signer: ZwzV3SignerRecord?,
        archiveID: UUID,
        dataBlockCount: UInt64
    ) throws -> Data {
        guard !recipients.isEmpty,
              let recipientCount = UInt32(exactly: recipients.count),
              !encryptedIndex.isEmpty,
              !dataRegion.isEmpty || dataBlockCount == 0 else {
            throw ZwzV3Error.malformedArchive("invalid archive regions")
        }

        var recipientRegion = Data()
        for recipient in recipients {
            recipientRegion.append(try ZwzV3BinaryCodec.encodeRecipient(recipient))
        }

        let signerRegion = try signer.map(ZwzV3BinaryCodec.encodeSigner) ?? Data()
        let headerLength = UInt64(ZwzV3Header.encodedLength)
        let recipientOffset = headerLength
        let dataOffset = try checkedAdd(recipientOffset, UInt64(recipientRegion.count))
        let indexOffset = try checkedAdd(dataOffset, UInt64(dataRegion.count))
        let signerOffset = try checkedAdd(indexOffset, UInt64(encryptedIndex.count))
        let archiveLength = try checkedAdd(signerOffset, UInt64(signerRegion.count))

        let signatureOffset: UInt64
        if signer != nil {
            guard signerRegion.count >= 64 else {
                throw ZwzV3Error.malformedArchive("invalid signer region")
            }
            signatureOffset = archiveLength - 64
        } else {
            signatureOffset = 0
        }

        let header = ZwzV3Header(
            archiveID: archiveID,
            recipientCount: recipientCount,
            recipientRegionOffset: recipientOffset,
            recipientRegionLength: UInt64(recipientRegion.count),
            dataRegionOffset: dataOffset,
            dataRegionLength: UInt64(dataRegion.count),
            encryptedIndexOffset: indexOffset,
            encryptedIndexLength: UInt64(encryptedIndex.count),
            signerRegionOffset: signer == nil ? 0 : signerOffset,
            signerRegionLength: UInt64(signerRegion.count),
            signatureOffset: signatureOffset,
            signatureLength: signer == nil ? 0 : 64,
            dataBlockCount: dataBlockCount,
            signatureAlgorithm: signer == nil ? .none : .ed25519
        )

        var archive = try ZwzV3BinaryCodec.encodeHeader(header)
        guard let capacity = Int(exactly: archiveLength) else {
            throw ZwzV3Error.malformedArchive("archive too large")
        }
        archive.reserveCapacity(capacity)
        archive.append(recipientRegion)
        archive.append(dataRegion)
        archive.append(encryptedIndex)
        archive.append(signerRegion)
        return archive
    }

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw ZwzV3Error.malformedArchive("archive too large") }
        return result.partialValue
    }
}
