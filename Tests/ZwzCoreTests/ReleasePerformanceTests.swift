import XCTest
@testable import ZwzCore

final class ReleasePerformanceTests: XCTestCase {
    private let fileManager = FileManager.default

    func testZIPCompressionPerformance() throws { try benchmark(.zip, operation: .compress) }
    func testZIPListingPerformance() throws { try benchmark(.zip, operation: .list) }
    func testZIPExtractionPerformance() throws { try benchmark(.zip, operation: .extract) }
    func testZwzV2CompressionPerformance() throws { try benchmark(.v2, operation: .compress) }
    func testZwzV2ListingPerformance() throws { try benchmark(.v2, operation: .list) }
    func testZwzV2ExtractionPerformance() throws { try benchmark(.v2, operation: .extract) }
    func testZwzV3CompressionPerformance() throws { try benchmark(.v3, operation: .compress) }
    func testZwzV3ListingPerformance() throws { try benchmark(.v3, operation: .list) }
    func testZwzV3ExtractionPerformance() throws { try benchmark(.v3, operation: .extract) }

    private func benchmark(_ format: BenchmarkFormat, operation: BenchmarkOperation) throws {
        guard performanceTestsEnabled else { return }
        let fixture = try makeFixture(name: format.rawValue)
        defer { try? fileManager.removeItem(at: fixture.root) }
        let api = ZwzAPI()
        let archive = fixture.root.appendingPathComponent("fixture.\(format.fileExtension)")
        let identity = format == .v3 ? ZwzV3IdentityFixture.make(name: "Benchmark Recipient") : nil
        let options = format.options(identity: identity)

        if operation != .compress {
            _ = try api.compress(
                sourcePath: fixture.source.path,
                destinationPath: archive.path,
                options: options,
                keyProvider: nil
            )
        }

        var extractionIndex = 0
        measureThrowing {
            switch operation {
            case .compress:
                try? self.fileManager.removeItem(at: archive)
                _ = try api.compress(
                    sourcePath: fixture.source.path,
                    destinationPath: archive.path,
                    options: options,
                    keyProvider: nil
                )
            case .list:
                _ = try api.list(
                    archivePath: archive.path,
                    keyProvider: identity?.provider
                )
            case .extract:
                extractionIndex += 1
                let output = fixture.root.appendingPathComponent("output-\(extractionIndex)")
                _ = try api.extract(
                    archivePath: archive.path,
                    destinationPath: output.path,
                    keyProvider: identity?.provider
                )
                try? self.fileManager.removeItem(at: output)
            }
        }
    }

    private var performanceTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["ZWZ_RUN_PERFORMANCE_TESTS"] == "1"
    }

    private func measureThrowing(_ body: @escaping () throws -> Void) {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            do {
                try body()
            } catch {
                XCTFail("Measured operation failed: \(error)")
            }
        }
    }

    private func makeFixture(name: String) throws -> (root: URL, source: URL) {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("zwz-release-benchmark-\(name)-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)

        var bytes = DeterministicBytes()
        for index in 0..<1_000 {
            let directory = source.appendingPathComponent("small/\(index / 100)", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload = Data((0..<256).map { _ in bytes.next() })
            try payload.write(to: directory.appendingPathComponent(String(format: "%04d.bin", index)))
        }

        try Data(repeating: 0x41, count: 8 * 1_024 * 1_024)
            .write(to: source.appendingPathComponent("compressible.bin"))
        let randomPayload = Data((0..<(8 * 1_024 * 1_024)).map { _ in bytes.next() })
        try randomPayload.write(to: source.appendingPathComponent("incompressible.bin"))

        let deep = source.appendingPathComponent(".hidden/层级/更深", isDirectory: true)
        try fileManager.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("ZwZ benchmark".utf8).write(to: deep.appendingPathComponent("文件.txt"))
        return (root, source)
    }
}

private enum BenchmarkOperation {
    case compress
    case list
    case extract
}

private enum BenchmarkFormat: String {
    case zip
    case v2
    case v3

    var fileExtension: String { self == .zip ? "zip" : "zwz" }

    func options(identity: ZwzV3IdentityFixture?) -> CompressionOptions {
        switch self {
        case .zip:
            return CompressionOptions(format: .zip)
        case .v2:
            return CompressionOptions(format: .zwz)
        case .v3:
            let recipient = identity!.recipient
            return CompressionOptions(
                encryption: .publicKey(recipients: [recipient], signer: nil),
                format: .zwz
            )
        }
    }
}

private struct DeterministicBytes {
    private var state: UInt64 = 0x5A57_5A42_454E_4348

    mutating func next() -> UInt8 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: state >> 32)
    }
}
