import Foundation
import ZwzCore
@testable import ZwzGUI

enum PublicKeyArchiveWorkflowTestError: LocalizedError, Equatable {
    case stoppedAfterRecording
    case missingRecipient
    case missingSigner

    var errorDescription: String? {
        switch self {
        case .stoppedAfterRecording:
            return "The test stopped after recording the routed operation."
        case .missingRecipient:
            return "An original archive recipient is unavailable."
        case .missingSigner:
            return "The original archive signer is unavailable."
        }
    }
}

final class PublicKeyArchiveWorkflowStore: ZwzIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var localIdentities: [ZwzIdentityMetadata]
    private var publicContacts: [ZwzPublicIdentity]

    init(identities: [ZwzIdentityMetadata], contacts: [ZwzPublicIdentity]) {
        localIdentities = identities
        publicContacts = contacts
    }

    func createIdentity(named name: String) throws -> ZwzIdentityMetadata {
        throw PublicKeyArchiveWorkflowTestError.stoppedAfterRecording
    }

    func identities() throws -> [ZwzIdentityMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return localIdentities
    }

    func contacts() throws -> [ZwzPublicIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return publicContacts
    }

    func importPublicIdentity(
        _ data: Data,
        conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzPublicIdentity {
        throw PublicKeyArchiveWorkflowTestError.stoppedAfterRecording
    }

    func exportPublicIdentity(fingerprint: String) throws -> Data {
        throw PublicKeyArchiveWorkflowTestError.stoppedAfterRecording
    }

    func exportPrivateBackup(fingerprint: String, password: String) throws -> Data {
        throw PublicKeyArchiveWorkflowTestError.stoppedAfterRecording
    }

    func importPrivateBackup(
        _ data: Data,
        password: String,
        conflict: ZwzIdentityConflictPolicy
    ) throws -> ZwzIdentityMetadata {
        throw PublicKeyArchiveWorkflowTestError.stoppedAfterRecording
    }

    func rename(fingerprint: String, to name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let index = localIdentities.firstIndex(where: { $0.fingerprint == fingerprint }) {
            localIdentities[index].name = name
            return
        }
        if let index = publicContacts.firstIndex(where: { $0.fingerprint == fingerprint }) {
            publicContacts[index].name = name
            return
        }
        throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
    }

    func delete(fingerprint: String) throws {
        lock.lock()
        defer { lock.unlock() }
        localIdentities.removeAll { $0.fingerprint == fingerprint }
        publicContacts.removeAll { $0.fingerprint == fingerprint }
    }

    func agreementPrivateKey(fingerprint: String, reason: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard localIdentities.contains(where: { $0.fingerprint == fingerprint }) else {
            throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
        }
        return Data(repeating: 0xA1, count: 32)
    }

    func signingPrivateKey(fingerprint: String, reason: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard localIdentities.contains(where: { $0.fingerprint == fingerprint }) else {
            throw ZwzV3Error.noMatchingPrivateKey([fingerprint])
        }
        return Data(repeating: 0xB2, count: 32)
    }

    func isKnownSigningKey(fingerprint: String, signingPublicKey: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return localIdentities.contains {
            $0.fingerprint == fingerprint && $0.signingPublicKey == signingPublicKey
        } || publicContacts.contains {
            $0.fingerprint == fingerprint && $0.signingPublicKey == signingPublicKey
        }
    }
}

final class ArchiveWorkflowSpy: ArchiveWorkflowClient, @unchecked Sendable {
    enum Operation: Hashable {
        case inspect
        case list
        case compress
        case extract
        case entry
    }

    struct CompressionRecord {
        let sourcePath: String
        let destinationPath: String?
        let options: CompressionOptions
        let storeID: ObjectIdentifier
    }

    private let lock = NSLock()
    private var operationCounts: [Operation: Int] = [:]
    private var operationStoreIDs: [Operation: [ObjectIdentifier]] = [:]
    private var queuedListResults: [Result<ZwzArchiveListing, Error>] = []
    private var queuedExtractResults: [Result<ZwzExtractionResult, Error>] = []
    private var queuedCompressionResults: [Result<String, Error>] = []
    private var _compressionRecords: [CompressionRecord] = []

    var detectedFormat: ExtractionFormat = .zwz
    var inspectionResult = Result<ZwzV3ArchiveInspection, Error>.success(
        ZwzV3ArchiveInspection(
            recipients: [],
            securityInfo: ZwzArchiveSecurityInfo(encryption: .publicKey)
        )
    )
    var entryResult = Result<URL, Error>.success(
        FileManager.default.temporaryDirectory.appendingPathComponent("public-key-entry.txt")
    )

    var compressionRecords: [CompressionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return _compressionRecords
    }

    func enqueueList(_ result: Result<ZwzArchiveListing, Error>) {
        lock.lock()
        queuedListResults.append(result)
        lock.unlock()
    }

    func enqueueExtract(_ result: Result<ZwzExtractionResult, Error>) {
        lock.lock()
        queuedExtractResults.append(result)
        lock.unlock()
    }

    func enqueueCompression(_ result: Result<String, Error>) {
        lock.lock()
        queuedCompressionResults.append(result)
        lock.unlock()
    }

    func count(_ operation: Operation) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return operationCounts[operation, default: 0]
    }

    func storeIDs(for operation: Operation) -> [ObjectIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        return operationStoreIDs[operation, default: []]
    }

    func detectFormat(archivePath: String) throws -> ExtractionFormat {
        detectedFormat
    }

    func inspect(
        archivePath: String,
        identityStore: any ZwzIdentityStore
    ) throws -> ZwzV3ArchiveInspection {
        record(.inspect, store: identityStore)
        return try inspectionResult.get()
    }

    func list(
        archivePath: String,
        password: String?,
        identityStore: any ZwzIdentityStore
    ) throws -> ZwzArchiveListing {
        record(.list, store: identityStore)
        return try nextListResult().get()
    }

    func compress(
        sourcePath: String,
        destinationPath: String?,
        options: CompressionOptions,
        identityStore: any ZwzIdentityStore,
        progress: ProgressHandler?,
        cancellationToken: CancellationToken?
    ) throws -> String {
        record(.compress, store: identityStore)
        lock.lock()
        _compressionRecords.append(CompressionRecord(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            options: options,
            storeID: ObjectIdentifier(identityStore as AnyObject)
        ))
        let result = queuedCompressionResults.isEmpty
            ? .success(destinationPath ?? sourcePath + ".zwz")
            : queuedCompressionResults.removeFirst()
        lock.unlock()
        progress?(1)
        return try result.get()
    }

    func extract(
        archivePath: String,
        destinationPath: String?,
        password: String?,
        identityStore: any ZwzIdentityStore,
        progress: ProgressHandler?,
        cancellationToken: CancellationToken?
    ) throws -> ZwzExtractionResult {
        record(.extract, store: identityStore)
        let result = try nextExtractResult().get()
        progress?(1)
        return result
    }

    func extractEntryToTemp(
        archivePath: String,
        entryPath: String,
        password: String?,
        identityStore: any ZwzIdentityStore
    ) throws -> URL {
        record(.entry, store: identityStore)
        return try entryResult.get()
    }

    private func record(_ operation: Operation, store: any ZwzIdentityStore) {
        lock.lock()
        operationCounts[operation, default: 0] += 1
        operationStoreIDs[operation, default: []].append(ObjectIdentifier(store as AnyObject))
        lock.unlock()
    }

    private func nextListResult() -> Result<ZwzArchiveListing, Error> {
        lock.lock()
        defer { lock.unlock() }
        if !queuedListResults.isEmpty { return queuedListResults.removeFirst() }
        return .success(ZwzArchiveListing(
            entries: ArchiveViewModelTestSupport.entries,
            version: 3,
            securityInfo: try? inspectionResult.get().securityInfo
        ))
    }

    private func nextExtractResult() -> Result<ZwzExtractionResult, Error> {
        lock.lock()
        defer { lock.unlock() }
        if !queuedExtractResults.isEmpty { return queuedExtractResults.removeFirst() }
        return .success(ZwzExtractionResult(
            destinationPath: "/tmp/public-key-output",
            version: 3,
            securityInfo: try? inspectionResult.get().securityInfo
        ))
    }
}

final class ArchiveEditWorkflowSpy: ArchiveEditWorkflowClient, @unchecked Sendable {
    struct SaveRecord {
        let encryption: ZwzEncryptionMode
        let storeID: ObjectIdentifier
    }

    private let lock = NSLock()
    private var _openCount = 0
    private var _saveRecords: [SaveRecord] = []
    private var _openStoreIDs: [ObjectIdentifier] = []
    private var originalSecurityInfo: ZwzArchiveSecurityInfo?
    private var originalPassword: String?
    var openError: Error?
    var saveError: Error?
    var openDelay: TimeInterval = 0

    var openCount: Int {
        lock.withLock { _openCount }
    }

    var saveRecords: [SaveRecord] {
        lock.withLock { _saveRecords }
    }

    var openStoreIDs: [ObjectIdentifier] {
        lock.withLock { _openStoreIDs }
    }

    func open(
        archivePath: String,
        password: String?,
        securityInfo: ZwzArchiveSecurityInfo?,
        identityStore: any ZwzIdentityStore
    ) throws -> [ArchiveEntry] {
        lock.lock()
        _openCount += 1
        _openStoreIDs.append(ObjectIdentifier(identityStore as AnyObject))
        originalSecurityInfo = securityInfo
        originalPassword = password
        let error = openError
        let delay = openDelay
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if let error { throw error }
        return ArchiveViewModelTestSupport.entries
    }

    func save(identityStore: any ZwzIdentityStore) throws {
        let protection = lock.withLock { (originalSecurityInfo, originalPassword) }
        let encryption = try ArchiveEncryptionResolver.resolve(
            securityInfo: protection.0,
            password: protection.1,
            identityStore: identityStore
        )
        lock.lock()
        let error = saveError
        if error == nil {
            _saveRecords.append(SaveRecord(
                encryption: encryption,
                storeID: ObjectIdentifier(identityStore as AnyObject)
            ))
        }
        lock.unlock()
        if let error { throw error }
    }
}

@MainActor
final class ArchiveMountWorkflowSpy: ArchiveMountWorkflowClient {
    struct SaveRecord {
        let encryption: ZwzEncryptionMode
        let storeID: ObjectIdentifier
    }

    private(set) var mountCount = 0
    private(set) var mountStoreIDs: [ObjectIdentifier] = []
    private(set) var saveRecords: [SaveRecord] = []
    private var originalSecurityInfo: ZwzArchiveSecurityInfo?
    private var originalPassword: String?
    var mountError: Error?
    var saveError: Error?

    func mount(
        archivePath: String,
        password: String?,
        capacityMB: Int,
        securityInfo: ZwzArchiveSecurityInfo?,
        identityStore: any ZwzIdentityStore
    ) async throws {
        mountCount += 1
        mountStoreIDs.append(ObjectIdentifier(identityStore as AnyObject))
        originalSecurityInfo = securityInfo
        originalPassword = password
        if let mountError { throw mountError }
    }

    func save(identityStore: any ZwzIdentityStore) async throws {
        if let saveError { throw saveError }
        let encryption = try ArchiveEncryptionResolver.resolve(
            securityInfo: originalSecurityInfo,
            password: originalPassword,
            identityStore: identityStore
        )
        saveRecords.append(SaveRecord(
            encryption: encryption,
            storeID: ObjectIdentifier(identityStore as AnyObject)
        ))
    }
}

@MainActor
enum ArchiveViewModelTestSupport {
    struct Fixture {
        let model: ArchiveViewModel
        let store: PublicKeyArchiveWorkflowStore
        let archive: ArchiveWorkflowSpy
        let editor: ArchiveEditWorkflowSpy
        let mounter: ArchiveMountWorkflowSpy
        let signer: ZwzIdentityMetadata
        let recipients: [ZwzPublicIdentity]

        var storeID: ObjectIdentifier { ObjectIdentifier(store) }
    }

    nonisolated static let entries = [
        ArchiveEntry(
            name: "message.txt",
            path: "message.txt",
            size: 7,
            isDirectory: false,
            modifiedDate: nil
        )
    ]

    static func fixture(
        identities: [ZwzIdentityMetadata]? = nil,
        contacts: [ZwzPublicIdentity]? = nil
    ) async throws -> Fixture {
        let signer = identity(name: "Local Signer", seed: 1)
        let recipients = [
            contact(name: "Recipient B", seed: 4),
            contact(name: "Recipient A", seed: 2)
        ]
        let store = PublicKeyArchiveWorkflowStore(
            identities: identities ?? [signer],
            contacts: contacts ?? recipients
        )
        let archive = ArchiveWorkflowSpy()
        let editor = ArchiveEditWorkflowSpy()
        let mounter = ArchiveMountWorkflowSpy()
        let model = ArchiveViewModel(
            identityStore: store,
            archiveClient: archive,
            editClient: editor,
            mountClient: mounter
        )
        model.sourcePath = "/tmp/public-key-input.zwz"
        model.archiveName = "public-key-input.zwz"
        model.detectedFormat = .zwz
        model.compressFormat = .zwz
        try await model.refreshIdentityChoices()
        return Fixture(
            model: model,
            store: store,
            archive: archive,
            editor: editor,
            mounter: mounter,
            signer: signer,
            recipients: recipients
        )
    }

    static func publicKeyModel() async throws -> ArchiveViewModel {
        let fixture = try await fixture()
        fixture.model.selectEncryptionMode(.publicKey)
        return fixture.model
    }

    static func selectedPublicKeyModel() async throws -> ArchiveViewModel {
        let fixture = try await fixture()
        fixture.model.selectEncryptionMode(.publicKey)
        fixture.model.selectedRecipientFingerprints = Set(fixture.recipients.map(\.fingerprint))
        fixture.model.selectedSignerFingerprint = fixture.signer.fingerprint
        return fixture.model
    }

    static func inspection(
        signature: ZwzSignatureVerification,
        recipients: [ZwzPublicIdentity],
        signerSigningPublicKey: Data? = nil
    ) -> ZwzV3ArchiveInspection {
        ZwzV3ArchiveInspection(
            recipients: recipients.map {
                ZwzRecipientInfo(name: $0.name, fingerprint: $0.fingerprint)
            },
            securityInfo: ZwzArchiveSecurityInfo(
                encryption: .publicKey,
                recipientFingerprints: recipients.map(\.fingerprint),
                signature: signature,
                signerSigningPublicKey: signerSigningPublicKey
            )
        )
    }

    static func listing(
        signature: ZwzSignatureVerification,
        recipients: [ZwzPublicIdentity]
    ) -> ZwzArchiveListing {
        ZwzArchiveListing(
            entries: entries,
            version: 3,
            securityInfo: inspection(signature: signature, recipients: recipients).securityInfo
        )
    }

    static func preparePreview(
        _ fixture: Fixture,
        signature: ZwzSignatureVerification = .unsigned
    ) async throws {
        let signerKey: Data?
        switch signature {
        case .validKnownSigner, .validUnknownSigner:
            signerKey = fixture.signer.signingPublicKey
        case .unsigned, .invalid:
            signerKey = nil
        }
        fixture.archive.inspectionResult = .success(inspection(
            signature: signature,
            recipients: fixture.recipients,
            signerSigningPublicKey: signerKey
        ))
        fixture.archive.enqueueList(.success(ZwzArchiveListing(
            entries: entries,
            version: 3,
            securityInfo: inspection(
                signature: signature,
                recipients: fixture.recipients,
                signerSigningPublicKey: signerKey
            ).securityInfo
        )))
        fixture.model.performPreview(path: fixture.model.sourcePath!)
        try await waitUntil { fixture.archive.count(.list) == 1 && !fixture.model.isProcessing }
    }

    static func restoreAndRetryCount() async throws -> Int {
        let fixture = try await fixture()
        fixture.archive.inspectionResult = .success(inspection(
            signature: .unsigned,
            recipients: fixture.recipients
        ))
        let missing = ZwzV3Error.noMatchingPrivateKey(fixture.recipients.map(\.fingerprint))
        fixture.archive.enqueueList(.failure(missing))
        fixture.archive.enqueueList(.success(listing(
            signature: .unsigned,
            recipients: fixture.recipients
        )))

        fixture.model.performPreview(path: fixture.model.sourcePath!)
        try await waitUntil { fixture.model.showMissingPrivateKeyPrompt }
        fixture.model.resumePendingPrivateKeyOperationAfterRestore()
        try await waitUntil { fixture.archive.count(.list) == 2 && !fixture.model.isProcessing }
        fixture.model.resumePendingPrivateKeyOperationAfterRestore()
        await Task.yield()
        return fixture.archive.count(.list) - 1
    }

    static func blockedActionCount(for signature: ZwzSignatureVerification) async throws -> Int {
        let fixture = try await fixture()
        fixture.archive.inspectionResult = .success(inspection(
            signature: signature,
            recipients: fixture.recipients
        ))
        fixture.model.performPreview(path: fixture.model.sourcePath!)
        try await waitUntil { fixture.archive.count(.inspect) == 1 && !fixture.model.isProcessing }

        fixture.model.performPreview(path: fixture.model.sourcePath!)
        fixture.model.performExtract()
        await fixture.model.mountArchive(capacityMB: 256)
        await Task.yield()

        let downstreamCalls = fixture.archive.count(.list)
            + fixture.archive.count(.extract)
            + fixture.mounter.mountCount
        return 3 - downstreamCalls
    }

    static func identity(name: String, seed: UInt8) -> ZwzIdentityMetadata {
        ZwzIdentityMetadata(
            name: name,
            fingerprint: fingerprint(seed),
            agreementPublicKey: Data(repeating: seed, count: 32),
            signingPublicKey: Data(repeating: seed &+ 0x40, count: 32),
            creationDate: Date(timeIntervalSince1970: TimeInterval(seed))
        )
    }

    static func contact(name: String, seed: UInt8) -> ZwzPublicIdentity {
        ZwzPublicIdentity(
            name: name,
            fingerprint: fingerprint(seed),
            agreementPublicKey: Data(repeating: seed, count: 32),
            signingPublicKey: Data(repeating: seed &+ 0x40, count: 32)
        )
    }

    static func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard condition() else { throw PublicKeyArchiveWorkflowTestError.stoppedAfterRecording }
    }

    private static func fingerprint(_ seed: UInt8) -> String {
        String(repeating: String(format: "%02x", seed), count: 32)
    }
}
