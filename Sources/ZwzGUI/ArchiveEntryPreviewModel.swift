import Combine
import Foundation
import ZwzCore

enum ArchiveEntryPreviewReadyPayload: Equatable, Sendable {
    case image(URL)
    case video(URL)
    case text(ArchiveEntryTextPreviewResult)
    case unsupported
}

enum ArchiveEntryPreviewState: Equatable, Sendable {
    case idle
    case loading
    case ready(ArchiveEntryPreviewReadyPayload)
    case failed(String)
}

enum ArchiveEntryPreviewProtectionFailure: Equatable, Sendable {
    case missingPrivateKey([String])
    case invalidSignature

    init?(_ error: Error) {
        guard let error = error as? ZwzV3Error else { return nil }
        switch error {
        case .noMatchingPrivateKey(let fingerprints):
            self = .missingPrivateKey(fingerprints)
        case .invalidSignature:
            self = .invalidSignature
        default:
            return nil
        }
    }

    var error: ZwzV3Error {
        switch self {
        case .missingPrivateKey(let fingerprints):
            return .noMatchingPrivateKey(fingerprints)
        case .invalidSignature:
            return .invalidSignature
        }
    }
}

struct ArchiveEntryPreviewProtectionEvent: Sendable {
    let failure: ArchiveEntryPreviewProtectionFailure
    let allowsPrivateKeyRecovery: Bool
    let retryAfterPrivateKeyRestore: @MainActor @Sendable () -> Void
}

typealias ArchiveEntryPreviewProtectionHandler = @MainActor @Sendable (
    ArchiveEntryPreviewProtectionEvent
) -> Void

protocol ArchiveEntryPreviewExtracting: Sendable {
    func extractEntryToTemp(
        archivePath: String,
        entryPath: String,
        password: String?,
        maximumBytes: Int64,
        cancellationToken: CancellationToken
    ) throws -> URL
}

private struct DefaultArchiveEntryPreviewExtractor: ArchiveEntryPreviewExtracting {
    let identityStore: any ZwzIdentityStore

    func extractEntryToTemp(
        archivePath: String,
        entryPath: String,
        password: String?,
        maximumBytes: Int64,
        cancellationToken: CancellationToken
    ) throws -> URL {
        try ArchiveExtractor().extractEntryToTemp(
            archivePath: archivePath,
            entryPath: entryPath,
            password: password,
            keyProvider: identityStore,
            maximumBytes: maximumBytes,
            cancellationToken: cancellationToken
        )
    }
}

@MainActor
final class ArchiveEntryPreviewModel: ObservableObject {
    @Published private(set) var state: ArchiveEntryPreviewState = .idle
    @Published private(set) var currentEntry: ArchiveEntry?
    @Published private(set) var currentPreviewURL: URL?

    var currentEntryPath: String? { currentEntry?.path }

    private let extractor: any ArchiveEntryPreviewExtracting
    private let onProtectionFailure: ArchiveEntryPreviewProtectionHandler?
    private var currentRequest: PreviewRequest?
    private var currentTask: Task<Void, Never>?
    private var currentCancellationToken: CancellationToken?
    private var generation = UUID()

    private struct PreviewRequest: Sendable {
        let archivePath: String
        let entry: ArchiveEntry
        let password: String?
        let allowsPrivateKeyRecovery: Bool

        var key: PreviewRequestKey {
            PreviewRequestKey(
                archivePath: archivePath,
                entryPath: entry.path,
                password: password,
                allowsPrivateKeyRecovery: allowsPrivateKeyRecovery
            )
        }
    }

    private struct PreviewRequestKey: Equatable, Sendable {
        let archivePath: String
        let entryPath: String
        let password: String?
        let allowsPrivateKeyRecovery: Bool
    }

    init(
        identityStore: any ZwzIdentityStore = ZwzGUIIdentityStore.shared,
        onProtectionFailure: ArchiveEntryPreviewProtectionHandler? = nil
    ) {
        extractor = DefaultArchiveEntryPreviewExtractor(identityStore: identityStore)
        self.onProtectionFailure = onProtectionFailure
    }

    init(
        extractor: any ArchiveEntryPreviewExtracting,
        onProtectionFailure: ArchiveEntryPreviewProtectionHandler? = nil
    ) {
        self.extractor = extractor
        self.onProtectionFailure = onProtectionFailure
    }

    func preview(
        archivePath: String,
        entry: ArchiveEntry,
        password: String? = nil,
        allowsPrivateKeyRecovery: Bool = true
    ) {
        let request = PreviewRequest(
            archivePath: archivePath,
            entry: entry,
            password: password?.isEmpty == true ? nil : password,
            allowsPrivateKeyRecovery: allowsPrivateKeyRecovery
        )
        if state == .loading, currentRequest?.key == request.key {
            return
        }
        if currentRequest?.key == request.key, currentPreviewURL != nil {
            return
        }

        invalidateCurrentPreview()
        currentRequest = request
        currentEntry = entry

        guard ArchiveEntryPreviewSupport.isSafeArchiveEntryPath(entry.path) else {
            state = .failed("The archive entry path is unsafe and cannot be previewed.")
            return
        }

        let kind = ArchiveEntryPreviewSupport.classify(fileName: entry.name)
        guard !entry.isDirectory, kind != .unsupported else {
            state = .ready(.unsupported)
            return
        }

        do {
            try ArchiveEntryPreviewSupport.validateDeclaredSize(entry.size, for: kind)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        guard let maximumBytes = ArchiveEntryPreviewSupport.extractionByteLimit(for: kind) else {
            state = .ready(.unsupported)
            return
        }

        let requestGeneration = generation
        let cancellationToken = CancellationToken()
        currentCancellationToken = cancellationToken
        state = .loading

        let extractor = self.extractor
        currentTask = Task.detached(priority: .userInitiated) { [weak self] in
            var extractedURL: URL?
            do {
                try cancellationToken.checkCancellation()
                let url = try extractor.extractEntryToTemp(
                    archivePath: request.archivePath,
                    entryPath: request.entry.path,
                    password: request.password,
                    maximumBytes: maximumBytes,
                    cancellationToken: cancellationToken
                )
                extractedURL = url
                try cancellationToken.checkCancellation()
                try Task.checkCancellation()
                let payload = try Self.readyPayload(for: kind, extractedURL: url)
                try cancellationToken.checkCancellation()
                try Task.checkCancellation()
                if let self {
                    await self.finish(
                        result: .success((url, payload)),
                        generation: requestGeneration
                    )
                } else {
                    Self.removeTemporaryRoot(containing: url)
                }
            } catch {
                if let extractedURL {
                    Self.removeTemporaryRoot(containing: extractedURL)
                }
                await self?.finish(result: .failure(error), generation: requestGeneration)
            }
        }
    }

    func retry() {
        guard let request = currentRequest else { return }
        preview(
            archivePath: request.archivePath,
            entry: request.entry,
            password: request.password,
            allowsPrivateKeyRecovery: request.allowsPrivateKeyRecovery
        )
    }

    func retryAfterPrivateKeyRestore() {
        guard let request = currentRequest else { return }
        preview(
            archivePath: request.archivePath,
            entry: request.entry,
            password: request.password,
            allowsPrivateKeyRecovery: false
        )
    }

    func clear() {
        invalidateCurrentPreview()
        currentRequest = nil
        currentEntry = nil
        state = .idle
    }

    private func invalidateCurrentPreview() {
        generation = UUID()
        currentCancellationToken?.cancel()
        currentCancellationToken = nil
        currentTask?.cancel()
        currentTask = nil
        if let currentPreviewURL {
            Self.removeTemporaryRoot(containing: currentPreviewURL)
        }
        currentPreviewURL = nil
    }

    private func finish(
        result: Result<(URL, ArchiveEntryPreviewReadyPayload), Error>,
        generation requestGeneration: UUID
    ) {
        guard generation == requestGeneration else {
            if case .success(let value) = result {
                Self.removeTemporaryRoot(containing: value.0)
            }
            return
        }

        currentTask = nil
        currentCancellationToken = nil
        switch result {
        case .success(let value):
            currentPreviewURL = value.0
            state = .ready(value.1)
        case .failure(let error):
            currentPreviewURL = nil
            let isOperationCancelled: Bool
            if let zwzError = error as? ZwzError, case .operationCancelled = zwzError {
                isOperationCancelled = true
            } else {
                isOperationCancelled = false
            }
            if error is CancellationError || isOperationCancelled {
                state = .idle
            } else {
                state = .failed(error.localizedDescription)
                if let failure = ArchiveEntryPreviewProtectionFailure(error),
                   let request = currentRequest {
                    onProtectionFailure?(ArchiveEntryPreviewProtectionEvent(
                        failure: failure,
                        allowsPrivateKeyRecovery: request.allowsPrivateKeyRecovery,
                        retryAfterPrivateKeyRestore: { [weak self] in
                            self?.retryAfterPrivateKeyRestore()
                        }
                    ))
                }
            }
        }
    }

    nonisolated private static func readyPayload(
        for kind: ArchiveEntryPreviewKind,
        extractedURL: URL
    ) throws -> ArchiveEntryPreviewReadyPayload {
        try ArchiveEntryPreviewSupport.validateExtractedFile(at: extractedURL, for: kind)
        switch kind {
        case .image:
            try ArchiveEntryPreviewSupport.validateImage(at: extractedURL)
            return .image(extractedURL)
        case .video:
            return .video(extractedURL)
        case .text:
            return .text(try ArchiveEntryPreviewSupport.readText(
                from: extractedURL,
                maximumBytes: ArchiveEntryPreviewSupport.maximumTextBytes
            ))
        case .unsupported:
            return .unsupported
        }
    }

    nonisolated private static func removeTemporaryRoot(containing url: URL) {
        guard let root = ArchiveEntryPreviewSupport.temporaryRoot(containing: url) else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
