import Foundation
import XCTest
import ZwzCore
@testable import ZwzGUI

@MainActor
final class PublicKeyArchiveWorkflowTests: XCTestCase {
    func testCompressionCompletionCallbackRunsAfterSuccessfulHistoryEntry() async throws {
        let fixture = try await ArchiveViewModelTestSupport.fixture()
        let model = fixture.model
        model.sourcePath = "/tmp/compression-success-source"
        var historyCountWhenNotified: Int?
        model.onCompressionSucceeded = {
            historyCountWhenNotified = model.history.count
        }

        model.performCompress()
        try await ArchiveViewModelTestSupport.waitUntil { !model.isProcessing }

        XCTAssertEqual(historyCountWhenNotified, 1)
        XCTAssertEqual(model.history.last?.isSuccess, true)
    }

    func testCompressionFailureRetainsSourceAndDoesNotNotifySuccess() async throws {
        let fixture = try await ArchiveViewModelTestSupport.fixture()
        let model = fixture.model
        let sourcePath = "/tmp/compression-failure-source"
        fixture.archive.enqueueCompression(.failure(PublicKeyArchiveWorkflowTestError.stoppedAfterRecording))
        model.sourcePath = sourcePath
        var successNotificationCount = 0
        model.onCompressionSucceeded = {
            successNotificationCount += 1
        }

        model.performCompress()
        try await ArchiveViewModelTestSupport.waitUntil { !model.isProcessing }

        XCTAssertEqual(successNotificationCount, 0)
        XCTAssertEqual(model.sourcePath, sourcePath)
        XCTAssertEqual(model.history.last?.isSuccess, false)
    }

    func testPublicKeyModeRequiresAtLeastOneRecipient() async throws {
        let fixture = try await ArchiveViewModelTestSupport.fixture()
        let model = fixture.model
        model.selectEncryptionMode(.publicKey)

        XCTAssertFalse(model.canStartCompression)

        model.selectedRecipientFingerprints.insert(String(repeating: "ff", count: 32))
        XCTAssertFalse(model.canStartCompression, "An unknown fingerprint is not a valid recipient")

        model.selectedRecipientFingerprints = [fixture.recipients[0].fingerprint]
        XCTAssertTrue(model.canStartCompression)

        model.compressFormat = .zip
        XCTAssertEqual(model.encryptionModeSelection, .none)
        XCTAssertTrue(model.selectedRecipientFingerprints.isEmpty)
        XCTAssertNil(model.selectedSignerFingerprint)
        XCTAssertTrue(model.canStartCompression, "ZIP should remain available after leaving public-key mode")
    }

    func testChangingToPasswordClearsRecipientsAndSigner() async throws {
        let fixture = try await ArchiveViewModelTestSupport.fixture()
        let model = fixture.model
        selectPublicKeyConfiguration(in: fixture)

        model.selectEncryptionMode(.password)

        XCTAssertEqual(model.encryptionModeSelection, .password)
        XCTAssertTrue(model.selectedRecipientFingerprints.isEmpty)
        XCTAssertNil(model.selectedSignerFingerprint)
    }

    func testChangingToNoneOrZIPClearsPublicKeyStateWithoutReinterpretingIt() async throws {
        let fixture = try await ArchiveViewModelTestSupport.fixture()
        let model = fixture.model
        selectPublicKeyConfiguration(in: fixture)

        model.selectEncryptionMode(.none)
        XCTAssertEqual(model.encryptionModeSelection, .none)
        XCTAssertTrue(model.selectedRecipientFingerprints.isEmpty)
        XCTAssertNil(model.selectedSignerFingerprint)

        selectPublicKeyConfiguration(in: fixture)
        model.password = "must not become active"
        model.compressFormat = .zip

        XCTAssertEqual(model.encryptionModeSelection, .none)
        XCTAssertTrue(model.selectedRecipientFingerprints.isEmpty)
        XCTAssertNil(model.selectedSignerFingerprint)
    }

    func testCompressionPassesSortedRecipientsLocalSignerAndExactStore() async throws {
        let fixture = try await ArchiveViewModelTestSupport.fixture()
        let model = fixture.model
        model.selectEncryptionMode(.publicKey)
        model.selectedRecipientFingerprints = Set(fixture.recipients.map(\.fingerprint))

        model.selectedSignerFingerprint = fixture.recipients[0].fingerprint
        XCTAssertFalse(model.canStartCompression, "A public contact cannot be used as a signer")

        model.selectedSignerFingerprint = fixture.signer.fingerprint
        XCTAssertTrue(model.canStartCompression)
        model.sourcePath = "/tmp/public-key-source"
        model.performCompress()
        try await ArchiveViewModelTestSupport.waitUntil {
            fixture.archive.count(.compress) == 1 && !model.isProcessing
        }

        let record = try XCTUnwrap(fixture.archive.compressionRecords.first)
        XCTAssertEqual(record.storeID, fixture.storeID)
        guard case .publicKey(let recipients, let signer) = record.options.encryption else {
            return XCTFail("Compression was silently downgraded from public-key mode")
        }
        XCTAssertEqual(
            recipients.map(\.fingerprint),
            fixture.recipients.map(\.fingerprint).sorted()
        )
        XCTAssertEqual(signer?.fingerprint, fixture.signer.fingerprint)
        XCTAssertEqual(signer?.signingPublicKey, fixture.signer.signingPublicKey)
    }

    func testPreviewListExtractSmartEntryEditAndMountReceiveExactStore() async throws {
        let preview = try await ArchiveViewModelTestSupport.fixture()
        try await ArchiveViewModelTestSupport.preparePreview(preview)
        assertOnlyStore(preview.storeID, wasPassedTo: preview.archive.storeIDs(for: .inspect))
        assertOnlyStore(preview.storeID, wasPassedTo: preview.archive.storeIDs(for: .list))

        let extraction = try await ArchiveViewModelTestSupport.fixture()
        try await ArchiveViewModelTestSupport.preparePreview(extraction)
        extraction.model.performExtract()
        try await ArchiveViewModelTestSupport.waitUntil {
            extraction.archive.count(.extract) == 1 && !extraction.model.isProcessing
        }
        assertOnlyStore(extraction.storeID, wasPassedTo: extraction.archive.storeIDs(for: .extract))

        let smartRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PublicKeySmartExtract-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: smartRoot) }
        try FileManager.default.createDirectory(at: smartRoot, withIntermediateDirectories: true)
        let smart = try await ArchiveViewModelTestSupport.fixture()
        smart.model.sourcePath = smartRoot.appendingPathComponent("smart.zwz").path
        try await ArchiveViewModelTestSupport.preparePreview(smart)
        smart.archive.enqueueExtract(.failure(PublicKeyArchiveWorkflowTestError.stoppedAfterRecording))
        smart.model.performSmartExtract()
        try await ArchiveViewModelTestSupport.waitUntil {
            smart.archive.count(.extract) == 1 && !smart.model.isProcessing
        }
        assertOnlyStore(smart.storeID, wasPassedTo: smart.archive.storeIDs(for: .extract))

        let entry = try await ArchiveViewModelTestSupport.fixture()
        try await ArchiveViewModelTestSupport.preparePreview(entry)
        _ = entry.model.extractEntryForDrag(entry: ArchiveViewModelTestSupport.entries[0])
        assertOnlyStore(entry.storeID, wasPassedTo: entry.archive.storeIDs(for: .entry))

        let editing = try await ArchiveViewModelTestSupport.fixture()
        try await ArchiveViewModelTestSupport.preparePreview(editing)
        editing.model.beginArchiveEditing()
        try await ArchiveViewModelTestSupport.waitUntil { editing.editor.openCount == 1 }
        assertOnlyStore(editing.storeID, wasPassedTo: editing.editor.openStoreIDs)

        let mounting = try await ArchiveViewModelTestSupport.fixture()
        try await ArchiveViewModelTestSupport.preparePreview(mounting)
        await mounting.model.mountArchive(capacityMB: 256)
        XCTAssertEqual(mounting.mounter.mountCount, 1)
        assertOnlyStore(mounting.storeID, wasPassedTo: mounting.mounter.mountStoreIDs)
    }

    func testMissingPrivateKeyOffersRestoreAndRetriesOnce() async throws {
        let retryCount = try await ArchiveViewModelTestSupport.restoreAndRetryCount()
        XCTAssertEqual(retryCount, 1)
    }

    func testMissingPrivateKeyPromptShowsUntrustedPublicRecipientLabels() async throws {
        let fixture = try await ArchiveViewModelTestSupport.fixture()
        fixture.archive.inspectionResult = .success(ArchiveViewModelTestSupport.inspection(
            signature: .unsigned,
            recipients: fixture.recipients
        ))
        fixture.archive.enqueueList(.failure(ZwzV3Error.noMatchingPrivateKey(
            fixture.recipients.map(\.fingerprint)
        )))

        fixture.model.performPreview(path: fixture.model.sourcePath!)
        try await ArchiveViewModelTestSupport.waitUntil {
            fixture.model.showMissingPrivateKeyPrompt
        }

        XCTAssertEqual(
            fixture.model.missingPrivateKeyRecipients,
            fixture.recipients.map {
                ZwzRecipientInfo(name: $0.name, fingerprint: $0.fingerprint)
            }
        )
        XCTAssertNil(fixture.model.errorMessage)
    }

    func testSecondMissingKeyFailureCannotCreateAutomaticRetryLoop() async throws {
        let fixture = try await ArchiveViewModelTestSupport.fixture()
        fixture.archive.inspectionResult = .success(ArchiveViewModelTestSupport.inspection(
            signature: .unsigned,
            recipients: fixture.recipients
        ))
        let missing = ZwzV3Error.noMatchingPrivateKey(fixture.recipients.map(\.fingerprint))
        fixture.archive.enqueueList(.failure(missing))
        fixture.archive.enqueueList(.failure(missing))

        fixture.model.performPreview(path: fixture.model.sourcePath!)
        try await ArchiveViewModelTestSupport.waitUntil {
            fixture.model.showMissingPrivateKeyPrompt && fixture.archive.count(.list) == 1
        }
        fixture.model.resumePendingPrivateKeyOperationAfterRestore()
        try await ArchiveViewModelTestSupport.waitUntil {
            fixture.archive.count(.list) == 2 && !fixture.model.isProcessing
        }

        fixture.model.resumePendingPrivateKeyOperationAfterRestore()
        await Task.yield()
        XCTAssertEqual(fixture.archive.count(.list), 2)
    }

    func testDismissingRecoveryClearsPendingOperation() async throws {
        let fixture = try await ArchiveViewModelTestSupport.fixture()
        fixture.archive.inspectionResult = .success(ArchiveViewModelTestSupport.inspection(
            signature: .unsigned,
            recipients: fixture.recipients
        ))
        fixture.archive.enqueueList(.failure(ZwzV3Error.noMatchingPrivateKey(
            fixture.recipients.map(\.fingerprint)
        )))

        fixture.model.performPreview(path: fixture.model.sourcePath!)
        try await ArchiveViewModelTestSupport.waitUntil {
            fixture.model.showMissingPrivateKeyPrompt
        }
        fixture.model.dismissMissingPrivateKeyPrompt()
        fixture.model.resumePendingPrivateKeyOperationAfterRestore()
        await Task.yield()

        XCTAssertFalse(fixture.model.showMissingPrivateKeyPrompt)
        XCTAssertTrue(fixture.model.missingPrivateKeyRecipients.isEmpty)
        XCTAssertEqual(fixture.archive.count(.list), 1)
    }

    func testAuthenticationCancellationAndKeychainFailureDoNotOpenRestoreFlow() async throws {
        let errors: [ZwzV3Error] = [
            .userAuthenticationCancelled,
            .keychainFailure(-50)
        ]
        for error in errors {
            let fixture = try await ArchiveViewModelTestSupport.fixture()
            fixture.archive.inspectionResult = .success(ArchiveViewModelTestSupport.inspection(
                signature: .unsigned,
                recipients: fixture.recipients
            ))
            fixture.archive.enqueueList(.failure(error))

            fixture.model.performPreview(path: fixture.model.sourcePath!)
            try await ArchiveViewModelTestSupport.waitUntil {
                fixture.archive.count(.list) == 1 && !fixture.model.isProcessing
            }

            XCTAssertFalse(fixture.model.showMissingPrivateKeyPrompt, "\(error)")
            XCTAssertTrue(fixture.model.missingPrivateKeyRecipients.isEmpty, "\(error)")
            XCTAssertNotNil(fixture.model.errorMessage, "\(error)")
        }
    }

    func testAllFourSignatureBadgesMapFromStructuredSecurityInfo() async throws {
        let signerFingerprint = ArchiveViewModelTestSupport.identity(name: "Signer", seed: 9).fingerprint
        let statuses: [ZwzSignatureVerification] = [
            .unsigned,
            .validKnownSigner(name: "Known", fingerprint: signerFingerprint),
            .validUnknownSigner(name: "Unknown", fingerprint: signerFingerprint),
            .invalid
        ]

        for status in statuses {
            let fixture = try await ArchiveViewModelTestSupport.fixture()
            fixture.archive.inspectionResult = .success(ArchiveViewModelTestSupport.inspection(
                signature: status,
                recipients: fixture.recipients
            ))
            if status != .invalid {
                fixture.archive.enqueueList(.success(ArchiveViewModelTestSupport.listing(
                    signature: status,
                    recipients: fixture.recipients
                )))
            }

            fixture.model.performPreview(path: fixture.model.sourcePath!)
            try await ArchiveViewModelTestSupport.waitUntil {
                fixture.archive.count(.inspect) == 1 && !fixture.model.isProcessing
            }

            XCTAssertEqual(fixture.model.signatureBadge, status)
            XCTAssertEqual(fixture.model.archiveSecurityInfo?.signature, status)
        }
    }

    func testInvalidSignatureBlocksPreviewExtractAndMount() async throws {
        let blockedCount = try await ArchiveViewModelTestSupport.blockedActionCount(for: .invalid)
        XCTAssertEqual(blockedCount, 3)
    }

    func testInvalidSignatureAlsoBlocksSmartEntryAndEditAtMethodBoundary() async throws {
        let fixture = try await ArchiveViewModelTestSupport.fixture()
        fixture.archive.inspectionResult = .success(ArchiveViewModelTestSupport.inspection(
            signature: .invalid,
            recipients: fixture.recipients
        ))
        fixture.model.performPreview(path: fixture.model.sourcePath!)
        try await ArchiveViewModelTestSupport.waitUntil {
            fixture.archive.count(.inspect) == 1 && !fixture.model.isProcessing
        }

        fixture.model.performSmartExtract()
        _ = fixture.model.extractEntryForDrag(entry: ArchiveViewModelTestSupport.entries[0])
        fixture.model.openEntry(entry: ArchiveViewModelTestSupport.entries[0])
        fixture.model.beginArchiveEditing()
        await Task.yield()

        XCTAssertEqual(fixture.archive.count(.extract), 0)
        XCTAssertEqual(fixture.archive.count(.entry), 0)
        XCTAssertEqual(fixture.editor.openCount, 0)
    }

    func testEditAndVirtualDiskSavePreserveEveryRecipientAndLocalSignature() async throws {
        let fixture = try await ArchiveViewModelTestSupport.fixture()
        let security = ZwzSignatureVerification.validKnownSigner(
            name: fixture.signer.name,
            fingerprint: fixture.signer.fingerprint
        )
        try await ArchiveViewModelTestSupport.preparePreview(fixture, signature: security)

        fixture.model.beginArchiveEditing()
        try await ArchiveViewModelTestSupport.waitUntil { fixture.editor.openCount == 1 }
        fixture.model.saveArchiveEdits()
        try await ArchiveViewModelTestSupport.waitUntil {
            fixture.editor.saveRecords.count == 1
                && !fixture.model.isSavingEdits
                && !fixture.model.isProcessing
        }

        await fixture.model.mountArchive(capacityMB: 256)
        await fixture.model.saveMountedArchive()
        XCTAssertEqual(fixture.mounter.saveRecords.count, 1)

        let expectedRecipients = fixture.recipients.map(\.fingerprint).sorted()
        try assertPublicKeySave(
            fixture.editor.saveRecords[0].encryption,
            expectedRecipients: expectedRecipients,
            expectedSigner: fixture.signer.fingerprint
        )
        try assertPublicKeySave(
            fixture.mounter.saveRecords[0].encryption,
            expectedRecipients: expectedRecipients,
            expectedSigner: fixture.signer.fingerprint
        )
        XCTAssertEqual(fixture.editor.saveRecords[0].storeID, fixture.storeID)
        XCTAssertEqual(fixture.mounter.saveRecords[0].storeID, fixture.storeID)
    }

    func testPublicKeySaveRefusesMissingRecipientInsteadOfDowngrading() async throws {
        let allRecipients = [
            ArchiveViewModelTestSupport.contact(name: "Present", seed: 2),
            ArchiveViewModelTestSupport.contact(name: "Missing", seed: 4)
        ]
        let fixture = try await ArchiveViewModelTestSupport.fixture(contacts: [allRecipients[0]])
        fixture.archive.inspectionResult = .success(ArchiveViewModelTestSupport.inspection(
            signature: .unsigned,
            recipients: allRecipients
        ))
        fixture.archive.enqueueList(.success(ArchiveViewModelTestSupport.listing(
            signature: .unsigned,
            recipients: allRecipients
        )))
        fixture.model.performPreview(path: fixture.model.sourcePath!)
        try await ArchiveViewModelTestSupport.waitUntil {
            fixture.archive.count(.list) == 1 && !fixture.model.isProcessing
        }

        fixture.model.beginArchiveEditing()
        try await ArchiveViewModelTestSupport.waitUntil { fixture.editor.openCount == 1 }
        fixture.model.saveArchiveEdits()
        try await ArchiveViewModelTestSupport.waitUntil {
            fixture.model.editErrorMessage != nil || fixture.model.errorMessage != nil
        }

        await fixture.model.mountArchive(capacityMB: 256)
        await fixture.model.saveMountedArchive()

        XCTAssertTrue(fixture.editor.saveRecords.isEmpty)
        XCTAssertTrue(fixture.mounter.saveRecords.isEmpty)
        XCTAssertNotNil(fixture.model.editErrorMessage ?? fixture.model.errorMessage)
    }

    func testPublicKeySaveRefusesUnavailableOriginalSignerInsteadOfRemovingSignature() async throws {
        let fixture = try await ArchiveViewModelTestSupport.fixture(identities: [])
        let signed = ZwzSignatureVerification.validKnownSigner(
            name: fixture.signer.name,
            fingerprint: fixture.signer.fingerprint
        )
        try await ArchiveViewModelTestSupport.preparePreview(fixture, signature: signed)

        fixture.model.beginArchiveEditing()
        try await ArchiveViewModelTestSupport.waitUntil { fixture.editor.openCount == 1 }
        fixture.model.saveArchiveEdits()
        try await ArchiveViewModelTestSupport.waitUntil {
            fixture.model.editErrorMessage != nil || fixture.model.errorMessage != nil
        }

        await fixture.model.mountArchive(capacityMB: 256)
        await fixture.model.saveMountedArchive()

        XCTAssertTrue(fixture.editor.saveRecords.isEmpty)
        XCTAssertTrue(fixture.mounter.saveRecords.isEmpty)
        XCTAssertNotNil(fixture.model.editErrorMessage ?? fixture.model.errorMessage)
    }

    func testPersistedVirtualDiskSessionContainsNoPrivateOrAuthenticationState() throws {
        let session = VirtualDiskSession(
            archivePath: "archive.zwz",
            imagePath: "workspace.sparsebundle",
            mountPath: "Mount",
            capacityMB: 256,
            baselineFingerprint: "baseline",
            splitVolumeBytes: nil,
            isMounted: true
        )
        let encoded = try JSONEncoder().encode(session)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(text.localizedCaseInsensitiveContains("privateKey"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("restorePassword"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("authenticationContext"))
        XCTAssertFalse(text.contains("correct horse battery staple"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("password"))
    }

    func testSaveUsesOpenedProtectionInsteadOfCurrentMutablePassword() async throws {
        let fixture = try await ArchiveViewModelTestSupport.fixture()
        let signed = ZwzSignatureVerification.validKnownSigner(
            name: fixture.signer.name,
            fingerprint: fixture.signer.fingerprint
        )
        try await ArchiveViewModelTestSupport.preparePreview(fixture, signature: signed)
        fixture.model.beginArchiveEditing()
        try await ArchiveViewModelTestSupport.waitUntil { fixture.editor.openCount == 1 }
        await fixture.model.mountArchive(capacityMB: 256)

        fixture.model.password = "different tab password"
        fixture.model.saveArchiveEdits()
        try await ArchiveViewModelTestSupport.waitUntil { fixture.editor.saveRecords.count == 1 }
        await fixture.model.saveMountedArchive()

        XCTAssertEqual(fixture.editor.saveRecords.count, 1)
        XCTAssertEqual(fixture.mounter.saveRecords.count, 1)
        try assertPublicKeySave(
            fixture.editor.saveRecords[0].encryption,
            expectedRecipients: fixture.recipients.map(\.fingerprint).sorted(),
            expectedSigner: fixture.signer.fingerprint
        )
        try assertPublicKeySave(
            fixture.mounter.saveRecords[0].encryption,
            expectedRecipients: fixture.recipients.map(\.fingerprint).sorted(),
            expectedSigner: fixture.signer.fingerprint
        )
    }

    func testSaveRejectsSignerFingerprintWithDifferentArchiveSigningKey() async throws {
        let fixture = try await ArchiveViewModelTestSupport.fixture()
        let signature = ZwzSignatureVerification.validUnknownSigner(
            name: "Claimed signer",
            fingerprint: fixture.signer.fingerprint
        )
        let inspection = ArchiveViewModelTestSupport.inspection(
            signature: signature,
            recipients: fixture.recipients,
            signerSigningPublicKey: Data(repeating: 0xEE, count: 32)
        )
        fixture.archive.inspectionResult = .success(inspection)
        fixture.archive.enqueueList(.success(ZwzArchiveListing(
            entries: ArchiveViewModelTestSupport.entries,
            version: 3,
            securityInfo: inspection.securityInfo
        )))
        fixture.model.performPreview(path: fixture.model.sourcePath!)
        try await ArchiveViewModelTestSupport.waitUntil { fixture.archive.count(.list) == 1 }

        fixture.model.beginArchiveEditing()
        try await ArchiveViewModelTestSupport.waitUntil { fixture.editor.openCount == 1 }
        fixture.model.saveArchiveEdits()
        try await ArchiveViewModelTestSupport.waitUntil { fixture.model.editErrorMessage != nil }
        await fixture.model.mountArchive(capacityMB: 256)
        await fixture.model.saveMountedArchive()

        XCTAssertTrue(fixture.editor.saveRecords.isEmpty)
        XCTAssertTrue(fixture.mounter.saveRecords.isEmpty)
    }

    func testSourceChangeRejectsLateArchiveEditorOpenCallback() async throws {
        let fixture = try await ArchiveViewModelTestSupport.fixture()
        try await ArchiveViewModelTestSupport.preparePreview(fixture)
        fixture.editor.openDelay = 0.08

        fixture.model.beginArchiveEditing()
        fixture.model.sourcePath = "/tmp/different-archive.zwz"
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(fixture.editor.openCount, 1)
        XCTAssertFalse(fixture.model.showArchiveEditor)
        XCTAssertTrue(fixture.model.editEntries.isEmpty)
    }

    private func selectPublicKeyConfiguration(in fixture: ArchiveViewModelTestSupport.Fixture) {
        fixture.model.compressFormat = .zwz
        fixture.model.selectEncryptionMode(.publicKey)
        fixture.model.selectedRecipientFingerprints = Set(fixture.recipients.map(\.fingerprint))
        fixture.model.selectedSignerFingerprint = fixture.signer.fingerprint
    }

    private func assertOnlyStore(
        _ expected: ObjectIdentifier,
        wasPassedTo identifiers: [ObjectIdentifier],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(identifiers.isEmpty, file: file, line: line)
        XCTAssertTrue(identifiers.allSatisfy { $0 == expected }, file: file, line: line)
    }

    private func assertPublicKeySave(
        _ encryption: ZwzEncryptionMode,
        expectedRecipients: [String],
        expectedSigner: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case .publicKey(let recipients, let signer) = encryption else {
            return XCTFail("Save was downgraded from public-key encryption", file: file, line: line)
        }
        XCTAssertEqual(recipients.map(\.fingerprint), expectedRecipients, file: file, line: line)
        XCTAssertEqual(signer?.fingerprint, expectedSigner, file: file, line: line)
    }
}
