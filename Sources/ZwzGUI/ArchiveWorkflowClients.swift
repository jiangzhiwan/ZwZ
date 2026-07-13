import Foundation
import ZwzCore

protocol ArchiveWorkflowClient: Sendable {
    func detectFormat(archivePath: String) throws -> ExtractionFormat

    func inspect(
        archivePath: String,
        identityStore: any ZwzIdentityStore
    ) throws -> ZwzV3ArchiveInspection

    func list(
        archivePath: String,
        password: String?,
        identityStore: any ZwzIdentityStore
    ) throws -> ZwzArchiveListing

    func compress(
        sourcePath: String,
        destinationPath: String?,
        options: CompressionOptions,
        identityStore: any ZwzIdentityStore,
        progress: ProgressHandler?,
        cancellationToken: CancellationToken?
    ) throws -> String

    func extract(
        archivePath: String,
        destinationPath: String?,
        password: String?,
        identityStore: any ZwzIdentityStore,
        progress: ProgressHandler?,
        cancellationToken: CancellationToken?
    ) throws -> ZwzExtractionResult

    func extractEntryToTemp(
        archivePath: String,
        entryPath: String,
        password: String?,
        identityStore: any ZwzIdentityStore
    ) throws -> URL
}

final class ZwzAPIArchiveWorkflowClient: ArchiveWorkflowClient, @unchecked Sendable {
    private let api: ZwzAPI

    init(api: ZwzAPI = ZwzAPI()) {
        self.api = api
    }

    func detectFormat(archivePath: String) throws -> ExtractionFormat {
        try api.detectFormat(archivePath: archivePath)
    }

    func inspect(
        archivePath: String,
        identityStore: any ZwzIdentityStore
    ) throws -> ZwzV3ArchiveInspection {
        try api.inspect(archivePath: archivePath, keyProvider: identityStore)
    }

    func list(
        archivePath: String,
        password: String?,
        identityStore: any ZwzIdentityStore
    ) throws -> ZwzArchiveListing {
        try api.list(
            archivePath: archivePath,
            password: password,
            keyProvider: identityStore
        )
    }

    func compress(
        sourcePath: String,
        destinationPath: String?,
        options: CompressionOptions,
        identityStore: any ZwzIdentityStore,
        progress: ProgressHandler?,
        cancellationToken: CancellationToken?
    ) throws -> String {
        try api.compress(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            options: options,
            keyProvider: identityStore,
            progress: progress,
            cancellationToken: cancellationToken
        )
    }

    func extract(
        archivePath: String,
        destinationPath: String?,
        password: String?,
        identityStore: any ZwzIdentityStore,
        progress: ProgressHandler?,
        cancellationToken: CancellationToken?
    ) throws -> ZwzExtractionResult {
        try api.extract(
            archivePath: archivePath,
            destinationPath: destinationPath,
            password: password,
            keyProvider: identityStore,
            progress: progress,
            cancellationToken: cancellationToken
        )
    }

    func extractEntryToTemp(
        archivePath: String,
        entryPath: String,
        password: String?,
        identityStore: any ZwzIdentityStore
    ) throws -> URL {
        try api.extractEntryToTemp(
            archivePath: archivePath,
            entryPath: entryPath,
            password: password,
            keyProvider: identityStore
        )
    }
}

protocol ArchiveEditWorkflowClient: Sendable {
    var archivePath: String? { get }
    var hasChanges: Bool { get }

    func open(
        archivePath: String,
        password: String?,
        securityInfo: ZwzArchiveSecurityInfo?,
        identityStore: any ZwzIdentityStore
    ) throws -> [ArchiveEntry]

    func entries() throws -> [ArchiveEntry]
    func add(urls: [URL], into directoryPath: String) throws
    func delete(path: String) throws
    func rename(path: String, to newName: String) throws
    func batchRename(items: [(sourcePath: String, newName: String)]) throws
    func replace(path: String, with sourceURL: URL) throws
    func text(for path: String) throws -> String
    func writeText(_ text: String, to path: String) throws

    func save(identityStore: any ZwzIdentityStore) throws

    func discard()
}

extension ArchiveEditWorkflowClient {
    var archivePath: String? { nil }
    var hasChanges: Bool { false }

    func entries() throws -> [ArchiveEntry] { [] }

    func add(urls: [URL], into directoryPath: String) throws {
        throw ArchiveEditWorkflowError.noActiveSession
    }

    func delete(path: String) throws {
        throw ArchiveEditWorkflowError.noActiveSession
    }

    func rename(path: String, to newName: String) throws {
        throw ArchiveEditWorkflowError.noActiveSession
    }

    func batchRename(items: [(sourcePath: String, newName: String)]) throws {
        throw ArchiveEditWorkflowError.noActiveSession
    }

    func replace(path: String, with sourceURL: URL) throws {
        throw ArchiveEditWorkflowError.noActiveSession
    }

    func text(for path: String) throws -> String {
        throw ArchiveEditWorkflowError.noActiveSession
    }

    func writeText(_ text: String, to path: String) throws {
        throw ArchiveEditWorkflowError.noActiveSession
    }

    func discard() {}
}

enum ArchiveEditWorkflowError: LocalizedError {
    case noActiveSession

    var errorDescription: String? {
        "There is no active archive editing session."
    }
}

@MainActor
protocol ArchiveMountWorkflowClient: AnyObject {
    func mount(
        archivePath: String,
        password: String?,
        capacityMB: Int,
        securityInfo: ZwzArchiveSecurityInfo?,
        identityStore: any ZwzIdentityStore
    ) async throws

    func save(identityStore: any ZwzIdentityStore) async throws
}
