import Foundation
import XCTest
import ZwzCore
@testable import ZwzGUI

@MainActor
final class IdentityManagerViewModelTests: XCTestCase {
    func testSettingsSidebarIncludesKeysWithoutTouchingStoreOnConstruction() {
        let store = IdentityManagerControlledStore()
        let model = IdentityManagerViewModel(store: store)

        XCTAssertTrue(ZWZSettingsView.SettingsTab.allCases.contains(.keys))
        _ = IdentityManagerView(model: model)

        XCTAssertEqual(store.callCount(.identities), 0)
        XCTAssertEqual(store.callCount(.contacts), 0)
    }

    func testInitialRefreshManualNonblankCreateAndSeparation() async throws {
        let local = IdentityManagerTestSupport.identity(name: "Alice", seed: 1)
        let contact = IdentityManagerTestSupport.contact(name: "Bob", seed: 2)
        let store = IdentityManagerControlledStore(identities: [local], contacts: [contact])
        let model = IdentityManagerViewModel(store: store)

        try await model.refresh()

        XCTAssertEqual(model.identities, [local])
        XCTAssertEqual(model.contacts, [contact])
        XCTAssertNil(model.selection)

        let blankError = await IdentityManagerTestSupport.capturedError {
            try await model.createIdentity(named: "   \n")
        }
        XCTAssertEqual(blankError as? IdentityManagerViewModelError, .invalidName)
        XCTAssertEqual(store.callCount(.create), 0)

        try await model.createIdentity(named: "New Mac")

        XCTAssertEqual(model.identities.count, 2)
        XCTAssertEqual(model.contacts, [contact])
        XCTAssertEqual(model.selectedName, "New Mac")
        XCTAssertTrue(model.selectedIsLocalIdentity)
    }

    func testRenamePreservesFingerprintAndPublicKeys() async throws {
        let (model, _) = try await IdentityManagerTestSupport.modelWithIdentity()
        let original = try XCTUnwrap(model.identities.first)

        try await model.rename(fingerprint: original.fingerprint, to: "Work Mac")

        let renamed = try XCTUnwrap(model.identities.first)
        XCTAssertEqual(renamed.name, "Work Mac")
        XCTAssertEqual(renamed.fingerprint, original.fingerprint)
        XCTAssertEqual(renamed.agreementPublicKey, original.agreementPublicKey)
        XCTAssertEqual(renamed.signingPublicKey, original.signingPublicKey)
        XCTAssertEqual(renamed.creationDate, original.creationDate)
    }

    func testDeleteRequiresRequestAndConfirmationAndCanBeCancelled() async throws {
        let (model, store) = try await IdentityManagerTestSupport.modelWithIdentity()
        let identity = try XCTUnwrap(model.identities.first)

        model.requestDelete(identity)

        XCTAssertTrue(store.contains(fingerprint: identity.fingerprint))
        XCTAssertEqual(model.pendingDeletion?.kind, .localIdentity)
        XCTAssertTrue(model.pendingDeletion?.requiresPermanentLossWarning == true)

        model.cancelDelete()
        XCTAssertNil(model.pendingDeletion)
        XCTAssertTrue(store.contains(fingerprint: identity.fingerprint))

        let contact = IdentityManagerTestSupport.contact(name: "Bob", seed: 2)
        model.requestDelete(contact)
        XCTAssertEqual(model.pendingDeletion?.kind, .contact)
        XCTAssertFalse(model.pendingDeletion?.requiresPermanentLossWarning == true)
        model.cancelDelete()

        model.requestDelete(identity)
        try await model.confirmDelete()

        XCTAssertFalse(store.contains(fingerprint: identity.fingerprint))
        XCTAssertTrue(model.identities.isEmpty)
        XCTAssertNil(model.pendingDeletion)
    }

    func testPublicImportExportConflictAndExplicitReplacement() async throws {
        let contact = IdentityManagerTestSupport.contact(name: "Bob", seed: 2)
        let store = IdentityManagerControlledStore(contacts: [contact])
        let model = IdentityManagerViewModel(store: store)
        try await model.refresh()
        var renamed = contact
        renamed.name = "Bob Updated"
        let data = try ZwzKeyFileCodec.encodePublic(renamed)

        let conflictError = await IdentityManagerTestSupport.capturedError {
            try await model.importPublicIdentity(data)
        }

        XCTAssertEqual(
            conflictError as? ZwzV3Error,
            .identityConflict(contact.fingerprint)
        )
        XCTAssertEqual(
            model.pendingConflict,
            IdentityManagerConflict(kind: .publicImport, fingerprint: contact.fingerprint)
        )

        try await model.importPublicIdentity(data, conflict: .replaceExisting)

        XCTAssertNil(model.pendingConflict)
        XCTAssertEqual(model.contacts.first?.name, "Bob Updated")
        let exported = try await model.exportPublicIdentity(fingerprint: contact.fingerprint)
        XCTAssertEqual(try ZwzKeyFileCodec.decodePublic(exported), renamed)
    }

    func testBackupValidationPrecedesStoreAndOutputContainsNoRawPrivateKeys() async throws {
        let (model, store) = try await IdentityManagerTestSupport.modelWithIdentity()
        let fingerprint = try XCTUnwrap(model.identities.first?.fingerprint)

        let emptyError = await IdentityManagerTestSupport.capturedError {
            try await model.exportPrivateBackup(
                fingerprint: fingerprint,
                password: "",
                confirmation: ""
            )
        }
        XCTAssertEqual(emptyError as? IdentityManagerViewModelError, .emptyPassword)

        let mismatchError = await IdentityManagerTestSupport.capturedError {
            try await model.exportPrivateBackup(
                fingerprint: fingerprint,
                password: "one",
                confirmation: "two"
            )
        }
        XCTAssertEqual(
            mismatchError as? IdentityManagerViewModelError,
            .passwordConfirmationMismatch
        )
        XCTAssertEqual(store.callCount(.exportBackup), 0)

        let backup = try await model.exportPrivateBackup(
            fingerprint: fingerprint,
            password: "matching password",
            confirmation: "matching password"
        )

        XCTAssertNil(backup.range(of: store.rawAgreementPrivateKey))
        XCTAssertNil(backup.range(of: store.rawSigningPrivateKey))
        XCTAssertEqual(store.callCount(.exportBackup), 1)
        XCTAssertFalse(store.wasCalledOnMainThread(.exportBackup))
    }

    func testRestoreFailuresAndCancellationNeverResumePendingAction() async throws {
        var resumeCount = 0
        let restorable = IdentityManagerTestSupport.identity(name: "Restored Mac", seed: 12)
        let store = IdentityManagerControlledStore(
            identities: [restorable],
            restorableIdentity: restorable
        )
        let model = IdentityManagerViewModel(store: store) { resumeCount += 1 }

        let wrongPassword = await IdentityManagerTestSupport.capturedError {
            try await model.restorePrivateBackup(
                store.encryptedBackup,
                password: "wrong password"
            )
        }
        XCTAssertEqual(wrongPassword as? ZwzV3Error, .invalidBackup)
        XCTAssertEqual(resumeCount, 0)

        store.fail(.restoreBackup, with: .userAuthenticationCancelled)
        let cancellation = await IdentityManagerTestSupport.capturedError {
            try await model.restorePrivateBackup(
                store.encryptedBackup,
                password: "correct horse battery staple"
            )
        }
        XCTAssertEqual(cancellation as? ZwzV3Error, .userAuthenticationCancelled)
        XCTAssertEqual(resumeCount, 0)

        store.clearFailure(.restoreBackup)
        let conflict = await IdentityManagerTestSupport.capturedError {
            try await model.restorePrivateBackup(
                store.encryptedBackup,
                password: "correct horse battery staple"
            )
        }
        XCTAssertEqual(
            conflict as? ZwzV3Error,
            .identityConflict(store.restorableIdentity.fingerprint)
        )
        XCTAssertEqual(resumeCount, 0)
        XCTAssertNotNil(model.pendingConflict)
        model.cancelConflict()
        XCTAssertNil(model.pendingConflict)
        XCTAssertEqual(resumeCount, 0)
    }

    func testSuccessfulRestoreResumesExactlyOnceAndRefreshes() async throws {
        var resumeCount = 0
        let store = IdentityManagerControlledStore()
        let model = IdentityManagerViewModel(store: store) { resumeCount += 1 }
        try await model.refresh()

        let restored = try await model.restorePrivateBackup(
            store.encryptedBackup,
            password: "correct horse battery staple"
        )

        XCTAssertEqual(restored, store.restorableIdentity)
        XCTAssertEqual(model.identities, [store.restorableIdentity])
        XCTAssertEqual(model.selection, .localIdentity(store.restorableIdentity.fingerprint))
        XCTAssertEqual(resumeCount, 1)

        _ = try await model.restorePrivateBackup(
            store.encryptedBackup,
            password: "correct horse battery staple",
            conflict: .replaceExisting
        )
        XCTAssertEqual(resumeCount, 1)
    }

    func testAuthenticationCancellationAndKeychainFailureMessagesStayDistinct() async throws {
        let (model, store) = try await IdentityManagerTestSupport.modelWithIdentity()
        let fingerprint = try XCTUnwrap(model.identities.first?.fingerprint)
        store.fail(.exportBackup, with: .userAuthenticationCancelled)

        _ = await IdentityManagerTestSupport.capturedError {
            try await model.exportPrivateBackup(
                fingerprint: fingerprint,
                password: "password",
                confirmation: "password"
            )
        }
        let cancellationMessage = try XCTUnwrap(model.errorMessage)
        XCTAssertFalse(cancellationMessage.isEmpty)

        store.fail(.exportBackup, with: .keychainFailure(-25308))
        _ = await IdentityManagerTestSupport.capturedError {
            try await model.exportPrivateBackup(
                fingerprint: fingerprint,
                password: "password",
                confirmation: "password"
            )
        }
        let keychainMessage = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(keychainMessage.contains("-25308"))
        XCTAssertNotEqual(keychainMessage, cancellationMessage)
    }

    func testBusyRejectsOverlappingMutationAndStoreWorkRunsOffMainThread() async throws {
        let identity = IdentityManagerTestSupport.identity(name: "Alice", seed: 1)
        let store = IdentityManagerControlledStore(identities: [identity])
        store.setOperationDelay(0.15)
        let model = IdentityManagerViewModel(store: store)
        try await model.refresh()

        let createTask = Task { @MainActor in
            try await model.createIdentity(named: "Second Mac")
        }
        while store.callCount(.create) == 0 { await Task.yield() }

        let overlap = await IdentityManagerTestSupport.capturedError {
            try await model.rename(fingerprint: identity.fingerprint, to: "Renamed")
        }
        XCTAssertEqual(overlap as? IdentityManagerViewModelError, .operationInProgress)
        _ = try await createTask.value

        XCTAssertFalse(store.wasCalledOnMainThread(.create))
        XCTAssertFalse(store.wasCalledOnMainThread(.identities))
        XCTAssertEqual(store.callCount(.rename), 0)
        XCTAssertFalse(model.isBusy)
    }

    func testLoadingRejectsMutationSoRefreshCannotOverwriteNewState() async throws {
        let identity = IdentityManagerTestSupport.identity(name: "Alice", seed: 1)
        let store = IdentityManagerControlledStore(identities: [identity])
        store.setListingDelay(0.15)
        let model = IdentityManagerViewModel(store: store)

        let refreshTask = Task { @MainActor in
            try await model.refresh()
        }
        while store.callCount(.identities) == 0 { await Task.yield() }

        XCTAssertTrue(model.isLoading)
        let overlap = await IdentityManagerTestSupport.capturedError {
            try await model.createIdentity(named: "Second Mac")
        }
        XCTAssertEqual(overlap as? IdentityManagerViewModelError, .operationInProgress)
        XCTAssertEqual(store.callCount(.create), 0)

        try await refreshTask.value
        XCTAssertEqual(model.identities, [identity])
        XCTAssertFalse(model.isLoading)
    }

    func testCancelledRefreshDoesNotPublishLateSnapshotOrError() async {
        let identity = IdentityManagerTestSupport.identity(name: "Alice", seed: 1)
        let store = IdentityManagerControlledStore(identities: [identity])
        store.setListingDelay(0.1)
        let model = IdentityManagerViewModel(store: store)

        let refreshTask = Task { @MainActor in
            try await model.refresh()
        }
        while store.callCount(.identities) == 0 { await Task.yield() }
        refreshTask.cancel()
        _ = await refreshTask.result

        XCTAssertTrue(model.identities.isEmpty)
        XCTAssertTrue(model.contacts.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testSuccessfulCreateIsCommittedWhenFollowingListingFails() async throws {
        let store = IdentityManagerControlledStore()
        store.fail(.identities, with: .keychainFailure(-50))
        let model = IdentityManagerViewModel(store: store)

        let created = try await model.createIdentity(named: "Offline List Mac")

        XCTAssertTrue(store.contains(fingerprint: created.fingerprint))
        XCTAssertEqual(model.identities, [created])
        XCTAssertEqual(model.selection, .localIdentity(created.fingerprint))
        XCTAssertNotNil(model.successMessage)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(store.callCount(.create), 1)
    }

    func testSuccessfulRestoreResumesOnceWhenFollowingListingFails() async throws {
        var resumeCount = 0
        let store = IdentityManagerControlledStore()
        store.fail(.identities, with: .keychainFailure(-50))
        let model = IdentityManagerViewModel(store: store) { resumeCount += 1 }

        let restored = try await model.restorePrivateBackup(
            store.encryptedBackup,
            password: "correct horse battery staple"
        )

        XCTAssertEqual(restored, store.restorableIdentity)
        XCTAssertEqual(model.identities, [store.restorableIdentity])
        XCTAssertEqual(resumeCount, 1)
        XCTAssertNotNil(model.successMessage)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(store.wasCalledOnMainThread(.restoreBackup))

        _ = try await model.restorePrivateBackup(
            store.encryptedBackup,
            password: "correct horse battery staple",
            conflict: .replaceExisting
        )
        XCTAssertEqual(resumeCount, 1)
    }

    func testKeyFileSizeValidationUsesCheckedSixteenMiBBoundary() throws {
        XCTAssertNoThrow(try IdentityManagerKeyFileIO.validateFileSize(
            IdentityManagerKeyFileIO.maximumKeyFileBytes
        ))
        XCTAssertThrowsError(try IdentityManagerKeyFileIO.validateFileSize(
            IdentityManagerKeyFileIO.maximumKeyFileBytes + 1
        )) {
            XCTAssertEqual(
                $0 as? IdentityManagerFileError,
                .fileTooLarge(maximumBytes: IdentityManagerKeyFileIO.maximumKeyFileBytes)
            )
        }
        XCTAssertThrowsError(try IdentityManagerKeyFileIO.validateFileSize(-1)) {
            XCTAssertEqual($0 as? IdentityManagerFileError, .invalidFileSize)
        }
    }

    func testReadKeyFileDataIsUnaffectedByLaterSourceMutation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "IdentityManager-owned-data-\(UUID().uuidString).zwzpub"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("original-key-file".utf8)
        try original.write(to: url)

        let loaded = try IdentityManagerKeyFileIO.readData(from: url)
        try Data("modified-source!!".utf8).write(to: url)

        XCTAssertEqual(loaded, original)
    }

    func testSlowRestoreRejectsRepeatedConfirmationAndResumesOnce() async throws {
        var resumeCount = 0
        let store = IdentityManagerControlledStore()
        store.setOperationDelay(0.15)
        let model = IdentityManagerViewModel(store: store) { resumeCount += 1 }

        let restoreTask = Task { @MainActor in
            try await model.restorePrivateBackup(
                store.encryptedBackup,
                password: "correct horse battery staple"
            )
        }
        while store.callCount(.restoreBackup) == 0 { await Task.yield() }

        XCTAssertTrue(model.isBusy)
        let overlap = await IdentityManagerTestSupport.capturedError {
            try await model.restorePrivateBackup(
                store.encryptedBackup,
                password: "correct horse battery staple"
            )
        }
        XCTAssertEqual(overlap as? IdentityManagerViewModelError, .operationInProgress)
        _ = try await restoreTask.value

        XCTAssertEqual(store.callCount(.restoreBackup), 1)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertFalse(store.wasCalledOnMainThread(.restoreBackup))
    }

    func testSlowDeleteRejectsRepeatedConfirmation() async throws {
        let identity = IdentityManagerTestSupport.identity(name: "Alice", seed: 1)
        let store = IdentityManagerControlledStore(identities: [identity])
        let model = IdentityManagerViewModel(store: store)
        try await model.refresh()
        model.requestDelete(identity)
        store.setOperationDelay(0.15)

        let deleteTask = Task { @MainActor in
            try await model.confirmDelete()
        }
        while store.callCount(.delete) == 0 { await Task.yield() }

        XCTAssertTrue(model.isBusy)
        let overlap = await IdentityManagerTestSupport.capturedError {
            try await model.confirmDelete()
        }
        XCTAssertEqual(overlap as? IdentityManagerViewModelError, .operationInProgress)
        try await deleteTask.value

        XCTAssertEqual(store.callCount(.delete), 1)
        XCTAssertFalse(store.contains(fingerprint: identity.fingerprint))
        XCTAssertNil(model.pendingDeletion)
    }

    func testCancelAndDismissClearConflictErrorsAndMessages() async throws {
        let contact = IdentityManagerTestSupport.contact(name: "Bob", seed: 2)
        let store = IdentityManagerControlledStore(contacts: [contact])
        let model = IdentityManagerViewModel(store: store)
        try await model.refresh()
        let data = try ZwzKeyFileCodec.encodePublic(contact)

        _ = await IdentityManagerTestSupport.capturedError {
            try await model.importPublicIdentity(data)
        }
        XCTAssertNotNil(model.pendingConflict)
        model.cancelConflict()
        XCTAssertNil(model.pendingConflict)

        store.fail(.create, with: .keychainFailure(-50))
        _ = await IdentityManagerTestSupport.capturedError {
            try await model.createIdentity(named: "Failing Mac")
        }
        XCTAssertNotNil(model.errorMessage)
        model.clearTransientState()
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.successMessage)
        XCTAssertNil(model.pendingConflict)
    }
}
