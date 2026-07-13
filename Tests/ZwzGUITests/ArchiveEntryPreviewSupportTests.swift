import CoreFoundation
import XCTest
import ZwzCore
@testable import ZwzGUI

final class ArchiveEntryPreviewSupportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveEntryPreviewSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testClassifiesConfirmedImageExtensionsIgnoringCase() {
        let extensions = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
        for fileExtension in extensions {
            XCTAssertEqual(
                ArchiveEntryPreviewSupport.classify(fileName: "Photo.\(fileExtension.uppercased())"),
                .image,
                fileExtension
            )
        }
    }

    func testClassifiesConfirmedVideoExtensions() {
        for fileExtension in ["mp4", "mov", "m4v"] {
            XCTAssertEqual(
                ArchiveEntryPreviewSupport.classify(fileName: "clip.\(fileExtension)"),
                .video,
                fileExtension
            )
        }
    }

    func testClassifiesTextAndSourceExtensions() {
        let names = [
            "notes.txt", "README.md", "data.json", "feed.xml", "config.yaml", "table.csv", "app.log",
            "main.swift", "client.tsx", "styles.css", "script.py", "server.go", "Makefile", ".env", ".gitignore",
        ]
        for name in names {
            XCTAssertEqual(ArchiveEntryPreviewSupport.classify(fileName: name), .text, name)
        }
    }

    func testClassifiesStringsFilesAsTextAcrossSystemTypeDatabases() {
        XCTAssertEqual(ArchiveEntryPreviewSupport.classify(fileName: "Localizable.strings"), .text)
    }

    func testUnsupportedTypesRemainUnsupported() {
        XCTAssertEqual(ArchiveEntryPreviewSupport.classify(fileName: "manual.pdf"), .unsupported)
        XCTAssertEqual(ArchiveEntryPreviewSupport.classify(fileName: "song.mp3"), .unsupported)
        XCTAssertEqual(ArchiveEntryPreviewSupport.classify(fileName: "archive.zip"), .unsupported)
        XCTAssertEqual(ArchiveEntryPreviewSupport.classify(fileName: "document.rtf"), .unsupported)
        XCTAssertEqual(ArchiveEntryPreviewSupport.classify(fileName: "README"), .unsupported)
    }

    func testPreviewByteLimits() {
        XCTAssertEqual(ArchiveEntryPreviewSupport.maximumTextBytes, 2 * 1024 * 1024)
        XCTAssertEqual(ArchiveEntryPreviewSupport.maximumImageBytes, 100 * 1024 * 1024)
        XCTAssertGreaterThan(
            ArchiveEntryPreviewSupport.maximumTextExtractionBytes,
            Int64(ArchiveEntryPreviewSupport.maximumTextBytes)
        )
        XCTAssertGreaterThan(ArchiveEntryPreviewSupport.maximumVideoBytes, 0)
        XCTAssertLessThan(ArchiveEntryPreviewSupport.maximumVideoBytes, Int64.max)
    }

    func testExtractionBudgetAcceptsBoundaryAndRejectsOneByteOverForEveryKind() throws {
        for kind in [ArchiveEntryPreviewKind.text, .image, .video] {
            let limit = try XCTUnwrap(ArchiveEntryPreviewSupport.extractionByteLimit(for: kind))
            XCTAssertNoThrow(try ArchiveEntryPreviewSupport.validateDeclaredSize(limit, for: kind))
            XCTAssertThrowsError(try ArchiveEntryPreviewSupport.validateDeclaredSize(limit + 1, for: kind))
        }
        XCTAssertNil(ArchiveEntryPreviewSupport.extractionByteLimit(for: .unsupported))
    }

    func testImageMetricsAcceptBoundariesAndRejectFrameOrPixelOverflow() throws {
        XCTAssertNoThrow(try ArchiveEntryPreviewSupport.validateImageMetrics(
            framePixelCounts: Array(repeating: 1, count: ArchiveEntryPreviewSupport.maximumImageFrameCount)
        ))
        XCTAssertNoThrow(try ArchiveEntryPreviewSupport.validateImageMetrics(
            framePixelCounts: [ArchiveEntryPreviewSupport.maximumImageTotalPixels]
        ))
        XCTAssertThrowsError(try ArchiveEntryPreviewSupport.validateImageMetrics(
            framePixelCounts: Array(repeating: 1, count: ArchiveEntryPreviewSupport.maximumImageFrameCount + 1)
        ))
        XCTAssertThrowsError(try ArchiveEntryPreviewSupport.validateImageMetrics(
            framePixelCounts: [ArchiveEntryPreviewSupport.maximumImageTotalPixels + 1]
        ))
    }

    func testPreviewSidebarWidthDefaultsToNarrowestSupportedSize() {
        XCTAssertEqual(ArchiveEntryPreviewSettings.defaultSidebarWidth, 180.0)
        XCTAssertEqual(ArchiveEntryPreviewSettings.minimumSidebarWidth, 180.0)
        XCTAssertEqual(ArchiveEntryPreviewSettings.maximumSidebarWidth, 260.0)
    }

    func testReadsUTF8Text() throws {
        let url = try write(Data("hello, world".utf8), named: "utf8.txt")

        let result = try ArchiveEntryPreviewSupport.readText(from: url)

        XCTAssertEqual(result.text, "hello, world")
        XCTAssertEqual(result.encodingName, "UTF-8")
        XCTAssertFalse(result.isTruncated)
    }

    func testReadsUTF16Text() throws {
        let original = "hello \u{4E16}\u{754C}"
        let data = try XCTUnwrap(original.data(using: .utf16))
        let url = try write(data, named: "utf16.txt")

        let result = try ArchiveEntryPreviewSupport.readText(from: url)

        XCTAssertEqual(result.text, original)
        XCTAssertEqual(result.encodingName, "UTF-16")
        XCTAssertFalse(result.isTruncated)
    }

    func testReadsGB18030Text() throws {
        let original = "\u{4F60}\u{597D}\u{FF0C}\u{4E16}\u{754C}"
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let data = try XCTUnwrap(original.data(using: encoding))
        let url = try write(data, named: "gb18030.txt")

        let result = try ArchiveEntryPreviewSupport.readText(from: url)

        XCTAssertEqual(result.text, original)
        XCTAssertEqual(result.encodingName, "GB18030")
        XCTAssertFalse(result.isTruncated)
    }

    func testReportsTruncationAndReturnsOnlyRequestedBytes() throws {
        let url = try write(Data("0123456789".utf8), named: "truncated.txt")

        let result = try ArchiveEntryPreviewSupport.readText(from: url, maximumBytes: 6)

        XCTAssertEqual(result.text, "012345")
        XCTAssertTrue(result.isTruncated)
    }

    func testTruncatedUTF8DropsOnlyIncompleteTrailingScalar() throws {
        let url = try write(Data("abcd\u{1F600}tail".utf8), named: "scalar.txt")

        let result = try ArchiveEntryPreviewSupport.readText(from: url, maximumBytes: 6)

        XCTAssertEqual(result.text, "abcd")
        XCTAssertTrue(result.isTruncated)
    }

    func testTextReadCannotExceedHardLimit() throws {
        let data = Data(repeating: Character("x").asciiValue!, count: ArchiveEntryPreviewSupport.maximumTextBytes + 8)
        let url = try write(data, named: "large.txt")

        let result = try ArchiveEntryPreviewSupport.readText(
            from: url,
            maximumBytes: ArchiveEntryPreviewSupport.maximumTextBytes + 1_000
        )

        XCTAssertEqual(result.text.utf8.count, ArchiveEntryPreviewSupport.maximumTextBytes)
        XCTAssertTrue(result.isTruncated)
    }

    func testFindsOnlyDirectDragEntryAndV3EntryTemporaryRoots() {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let dragRoot = temporaryDirectory.appendingPathComponent("zwz-drag-\(UUID().uuidString)", isDirectory: true)
        let dragFile = dragRoot.appendingPathComponent("Docs/readme.txt")
        let entryRoot = temporaryDirectory.appendingPathComponent("zwz-entry-\(UUID().uuidString)", isDirectory: true)
        let entryFile = entryRoot.appendingPathComponent("image.png")
        let v3Root = temporaryDirectory.appendingPathComponent("zwz-v3-entry-\(UUID().uuidString)", isDirectory: true)
        let v3File = v3Root.appendingPathComponent("movie.mp4")

        XCTAssertEqual(ArchiveEntryPreviewSupport.temporaryRoot(containing: dragFile), dragRoot)
        XCTAssertEqual(ArchiveEntryPreviewSupport.temporaryRoot(containing: entryFile), entryRoot)
        XCTAssertEqual(ArchiveEntryPreviewSupport.temporaryRoot(containing: entryRoot), entryRoot)
        XCTAssertEqual(ArchiveEntryPreviewSupport.temporaryRoot(containing: v3File), v3Root)
    }

    func testTemporaryRootRejectsNestedFakePrefixThatCouldHijackCleanup() {
        let unrelatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("unrelated-\(UUID().uuidString)", isDirectory: true)
        let fakeRoot = unrelatedRoot.appendingPathComponent("zwz-drag-fake", isDirectory: true)
        XCTAssertNil(ArchiveEntryPreviewSupport.temporaryRoot(
            containing: fakeRoot.appendingPathComponent("victim.txt")
        ))
    }

    func testTemporaryRootRejectsEmptySuffixNearMatch() {
        XCTAssertNil(ArchiveEntryPreviewSupport.temporaryRoot(
            containing: root.appendingPathComponent("zwz-drag-/file.txt")
        ))
    }

    func testTemporaryRootRejectsUnrelatedTemporaryPath() {
        XCTAssertNil(ArchiveEntryPreviewSupport.temporaryRoot(
            containing: root.appendingPathComponent("unrelated/file.txt")
        ))
    }

    func testTemporaryRootRejectsMatchingPathOutsideSystemTemporaryDirectory() {
        XCTAssertNil(ArchiveEntryPreviewSupport.temporaryRoot(
            containing: URL(fileURLWithPath: "/Users/example/zwz-drag-123/file.txt")
        ))
    }

    func testTemporaryRootRejectsNonFileURL() {
        XCTAssertNil(ArchiveEntryPreviewSupport.temporaryRoot(
            containing: URL(string: "https://example.com/zwz-entry-123/file.txt")!
        ))
    }

    func testSafeArchiveEntryPaths() {
        XCTAssertTrue(ArchiveEntryPreviewSupport.isSafeArchiveEntryPath("file.txt"))
        XCTAssertTrue(ArchiveEntryPreviewSupport.isSafeArchiveEntryPath("Docs/Nested/file.txt"))
    }

    func testUnsafeArchiveEntryPaths() {
        let unsafePaths = [
            "", "/etc/passwd", "\\\\server\\share", "C:\\Windows\\file.txt",
            ".", "..", "././", "Docs/", "./file.txt", "Docs/./file.txt", "Docs//file.txt",
            "Docs/../file.txt", "Docs\\file.txt", "Docs\\..\\file.txt", "bad\0name.txt",
        ]
        for path in unsafePaths {
            XCTAssertFalse(ArchiveEntryPreviewSupport.isSafeArchiveEntryPath(path), path)
        }
    }

    func testWindowRestorationGateRejectsCallbackIssuedBeforeReopen() {
        var gate = ArchivePreviewWindowRestorationGate()
        let closeToken = gate.beginRestoration()
        XCTAssertTrue(gate.accepts(closeToken))

        gate.invalidateForPreviewOpen()

        XCTAssertFalse(gate.accepts(closeToken))
        XCTAssertTrue(gate.accepts(gate.currentToken))
    }

    @MainActor
    func testModelDeduplicatesIdenticalLoadingRequest() async throws {
        let extractor = BlockingPreviewExtractor()
        let model = ArchiveEntryPreviewModel(extractor: extractor)
        let entry = textEntry(path: "one.txt")

        model.preview(archivePath: "/archive.zip", entry: entry, password: "secret")
        try await waitUntil { extractor.callCount == 1 }
        model.preview(archivePath: "/archive.zip", entry: entry, password: "secret")
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(extractor.callCount, 1)
        extractor.releaseAll()
        try await waitUntil { if case .ready = model.state { true } else { false } }
        model.clear()
    }

    @MainActor
    func testModelRejectsOversizeBeforeExtractionAndRechecksActualFileAfterExtraction() async throws {
        let neverCalled = BlockingPreviewExtractor()
        let preflightModel = ArchiveEntryPreviewModel(extractor: neverCalled)
        preflightModel.preview(
            archivePath: "/archive.zip",
            entry: textEntry(
                path: "declared-too-large.txt",
                size: ArchiveEntryPreviewSupport.maximumTextExtractionBytes + 1
            )
        )
        XCTAssertEqual(neverCalled.callCount, 0)
        guard case .failed = preflightModel.state else {
            return XCTFail("Expected declared oversize failure")
        }

        let oversized = OversizedPreviewExtractor()
        let postflightModel = ArchiveEntryPreviewModel(extractor: oversized)
        postflightModel.preview(
            archivePath: "/archive.zip",
            entry: textEntry(path: "actual-too-large.txt", size: 1)
        )
        try await waitUntil { if case .failed = postflightModel.state { true } else { false } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oversized.root.path))
    }

    @MainActor
    func testModelCancelsOldRequestAndCleansItsLateTemporaryResultOnRapidSwitch() async throws {
        let extractor = SwitchingPreviewExtractor()
        let model = ArchiveEntryPreviewModel(extractor: extractor)
        let first = textEntry(path: "first.txt")
        let second = textEntry(path: "second.txt")

        model.preview(archivePath: "/archive.zip", entry: first, password: "one")
        try await waitUntil { extractor.callCount == 1 }
        model.preview(archivePath: "/archive.zip", entry: second, password: "two")

        try await waitUntil { model.currentEntryPath == second.path && model.currentPreviewURL != nil }
        XCTAssertEqual(extractor.callCount, 2)
        XCTAssertTrue(extractor.firstTokenWasCancelled)
        try await waitUntil { !FileManager.default.fileExists(atPath: extractor.firstRoot.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractor.secondFile.path))
        model.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: extractor.secondRoot.path))
    }

    @MainActor
    func testModelPrivateKeyRestoreRetryCannotRequestAnotherAutomaticRetry() async throws {
        let extractor = MissingPrivateKeyPreviewExtractor()
        let recorder = PreviewProtectionEventRecorder()
        let model = ArchiveEntryPreviewModel(
            extractor: extractor,
            onProtectionFailure: { recorder.events.append($0) }
        )

        model.preview(
            archivePath: "/archive.zwz",
            entry: textEntry(path: "protected.txt")
        )
        try await waitUntil { recorder.events.count == 1 }
        XCTAssertTrue(recorder.events[0].allowsPrivateKeyRecovery)
        XCTAssertEqual(
            recorder.events[0].failure,
            .missingPrivateKey(["AA:BB"])
        )

        recorder.events[0].retryAfterPrivateKeyRestore()
        try await waitUntil { recorder.events.count == 2 }
        XCTAssertFalse(recorder.events[1].allowsPrivateKeyRecovery)
        XCTAssertEqual(extractor.callCount, 2)
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func textEntry(path: String, size: Int64 = 5) -> ArchiveEntry {
        ArchiveEntry(
            name: (path as NSString).lastPathComponent,
            path: path,
            size: size,
            isDirectory: false,
            modifiedDate: nil
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw PreviewTestTimeout() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct PreviewTestTimeout: Error {}

@MainActor
private final class PreviewProtectionEventRecorder {
    var events: [ArchiveEntryPreviewProtectionEvent] = []
}

private final class MissingPrivateKeyPreviewExtractor: ArchiveEntryPreviewExtracting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func extractEntryToTemp(
        archivePath: String,
        entryPath: String,
        password: String?,
        maximumBytes: Int64,
        cancellationToken: CancellationToken
    ) throws -> URL {
        lock.withLock { calls += 1 }
        throw ZwzV3Error.noMatchingPrivateKey(["AA:BB"])
    }
}

private final class BlockingPreviewExtractor: ArchiveEntryPreviewExtracting, @unchecked Sendable {
    private let condition = NSCondition()
    private var calls = 0
    private var released = false

    var callCount: Int { condition.withLock { calls } }

    func releaseAll() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }

    func extractEntryToTemp(
        archivePath: String,
        entryPath: String,
        password: String?,
        maximumBytes: Int64,
        cancellationToken: CancellationToken
    ) throws -> URL {
        condition.lock()
        calls += 1
        while !released && !cancellationToken.isCancelled {
            condition.wait(until: Date().addingTimeInterval(0.01))
        }
        condition.unlock()
        try cancellationToken.checkCancellation()
        return try makePreviewFile(entryPath: entryPath, contents: "ready")
    }
}

private final class SwitchingPreviewExtractor: ArchiveEntryPreviewExtracting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var firstCancelled = false
    let firstRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("zwz-drag-\(UUID().uuidString)", isDirectory: true)
    let secondRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("zwz-drag-\(UUID().uuidString)", isDirectory: true)

    var firstFile: URL { firstRoot.appendingPathComponent("first.txt") }
    var secondFile: URL { secondRoot.appendingPathComponent("second.txt") }
    var callCount: Int { lock.withLock { calls } }
    var firstTokenWasCancelled: Bool { lock.withLock { firstCancelled } }

    func extractEntryToTemp(
        archivePath: String,
        entryPath: String,
        password: String?,
        maximumBytes: Int64,
        cancellationToken: CancellationToken
    ) throws -> URL {
        let call = lock.withLock { calls += 1; return calls }
        if call == 1 {
            try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
            try Data("late".utf8).write(to: firstFile)
            while !cancellationToken.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
            lock.withLock { firstCancelled = true }
            return firstFile
        }
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        try Data("ready".utf8).write(to: secondFile)
        return secondFile
    }
}

private final class OversizedPreviewExtractor: ArchiveEntryPreviewExtracting, @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("zwz-drag-\(UUID().uuidString)", isDirectory: true)

    func extractEntryToTemp(
        archivePath: String,
        entryPath: String,
        password: String?,
        maximumBytes: Int64,
        cancellationToken: CancellationToken
    ) throws -> URL {
        let file = root.appendingPathComponent(entryPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(maximumBytes + 1))
        return file
    }
}

private func makePreviewFile(entryPath: String, contents: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("zwz-drag-\(UUID().uuidString)", isDirectory: true)
    let file = root.appendingPathComponent(entryPath)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: file)
    return file
}
