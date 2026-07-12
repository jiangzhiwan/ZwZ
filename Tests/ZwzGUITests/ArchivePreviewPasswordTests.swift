import XCTest
import ZwzCore
@testable import ZwzGUI

@MainActor
final class ArchivePreviewPasswordTests: XCTestCase {
    func testInitialPasswordFailureShowsPromptInsteadOfGenericError() {
        let viewModel = ArchiveViewModel()

        viewModel.handlePreviewFailure(ZwzV2Error.wrongPasswordOrTamperedData, isPasswordRetry: false)

        XCTAssertTrue(viewModel.showPreviewPasswordPrompt)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.previewPasswordError)
        XCTAssertEqual(viewModel.password, "")
    }

    func testPasswordRetryFailureKeepsPromptOpenWithInlineError() {
        let viewModel = ArchiveViewModel()
        viewModel.password = "wrong"

        viewModel.handlePreviewFailure(ZwzV2Error.wrongPasswordOrTamperedData, isPasswordRetry: true)

        XCTAssertTrue(viewModel.showPreviewPasswordPrompt)
        XCTAssertEqual(viewModel.previewPasswordError, L.string("archive_password_or_tampered"))
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.password, "")
    }

    func testPreviewSuccessClosesPromptAndPublishesEntries() {
        let viewModel = ArchiveViewModel()
        viewModel.showPreviewPasswordPrompt = true
        viewModel.previewPasswordError = "old error"
        let entries = [
            ArchiveEntry(name: "secret.txt", path: "secret.txt", size: 4, isDirectory: false, modifiedDate: nil)
        ]

        viewModel.handlePreviewSuccess(entries)

        XCTAssertFalse(viewModel.showPreviewPasswordPrompt)
        XCTAssertNil(viewModel.previewPasswordError)
        XCTAssertEqual(viewModel.previewEntries.map(\.path), ["secret.txt"])
    }

    func testSubmittingPasswordImmediatelyDismissesPrompt() {
        let viewModel = ArchiveViewModel()
        viewModel.sourcePath = "/tmp/missing-encrypted.zwz"
        viewModel.password = "secret"
        viewModel.showPreviewPasswordPrompt = true
        viewModel.previewPasswordError = "old error"

        viewModel.retryPreviewWithPassword()

        XCTAssertFalse(viewModel.showPreviewPasswordPrompt)
        XCTAssertNil(viewModel.previewPasswordError)
        XCTAssertTrue(viewModel.isProcessing)
    }

    func testReplacementPasswordEnablesAnotherAttemptIndependentlyOfProcessingState() {
        let viewModel = ArchiveViewModel()
        viewModel.isProcessing = true

        viewModel.password = "   "
        XCTAssertFalse(viewModel.canSubmitPreviewPassword)

        viewModel.password = "replacement"
        XCTAssertTrue(viewModel.canSubmitPreviewPassword)
    }

    func testNonPasswordFailureUsesGenericErrorView() {
        let viewModel = ArchiveViewModel()
        let error = NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "broken archive"])

        viewModel.handlePreviewFailure(error, isPasswordRetry: false)

        XCTAssertFalse(viewModel.showPreviewPasswordPrompt)
        XCTAssertEqual(viewModel.errorMessage, "broken archive")
    }

    func testCancelPasswordPromptClearsPendingArchiveAndPassword() {
        let viewModel = ArchiveViewModel()
        viewModel.sourcePath = "/tmp/encrypted.zwz"
        viewModel.archiveName = "encrypted.zwz"
        viewModel.password = "secret"
        viewModel.showPreviewPasswordPrompt = true

        viewModel.cancelPreviewPasswordPrompt()

        XCTAssertFalse(viewModel.showPreviewPasswordPrompt)
        XCTAssertNil(viewModel.sourcePath)
        XCTAssertEqual(viewModel.archiveName, "")
        XCTAssertEqual(viewModel.password, "")
    }

    func testPreviewPasswordPromptStringsAreLocalized() {
        let languageManager = LanguageManager.shared
        let originalLanguage = languageManager.currentLanguage
        defer { languageManager.setLanguage(originalLanguage) }

        languageManager.setLanguage("zh")
        XCTAssertEqual(L.string("preview_password_title"), "需要密码")
        XCTAssertEqual(L.string("preview_with_password"), "预览")

        languageManager.setLanguage("en")
        XCTAssertEqual(L.string("preview_password_title"), "Password Required")
        XCTAssertEqual(L.string("preview_with_password"), "Preview")
    }
}
