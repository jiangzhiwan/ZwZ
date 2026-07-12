import Foundation

final class ZwzAsyncResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

final class ZwzProgressBox: @unchecked Sendable {
    private let handler: ProgressHandler?

    init(_ handler: ProgressHandler?) {
        self.handler = handler
    }

    func report(_ value: Double) {
        handler?(value)
    }
}

func waitForZwzAsync<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ZwzAsyncResultBox<Value>()

    Task.detached {
        do {
            box.store(.success(try await operation()))
        } catch {
            box.store(.failure(error))
        }
        semaphore.signal()
    }

    semaphore.wait()
    guard let result = box.load() else {
        throw ZwzV2Error.malformedArchive("asynchronous operation returned no result")
    }
    return try result.get()
}

extension CompressionOptions {
    var zwzV2Options: ZwzV2Options {
        ZwzV2Options(
            compressionLevel: level.zwzV2Level,
            password: password.flatMap { $0.isEmpty ? nil : $0 },
            splitVolumeSize: splitVolume.flatMap { $0.bytes > 0 ? UInt64($0.bytes) : nil },
            threadCount: resolveThreadCount(threadCount)
        )
    }
}

private extension CompressionLevel {
    var zwzV2Level: ZwzV2CompressionLevel {
        switch self {
        case .none: return .none
        case .fastest: return .fastest
        case .normal: return .normal
        case .max: return .max
        }
    }
}

/// Compatibility adapter that preserves the existing synchronous API while writing ZWZ v2 archives.
public final class ZwzCompressor {
    public init() {}

    public func compress(
        sourcePath: String,
        destinationPath: String,
        options: CompressionOptions = CompressionOptions(format: .zwz),
        progress: ProgressHandler? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws {
        try compress(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            options: options,
            keyProvider: nil,
            progress: progress,
            cancellationToken: cancellationToken
        )
    }

    public func compress(
        sourcePath: String,
        destinationPath: String,
        options: CompressionOptions = CompressionOptions(format: .zwz),
        keyProvider: ZwzPrivateKeyProvider?,
        progress: ProgressHandler? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let outputURL = URL(fileURLWithPath: destinationPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if case .publicKey = options.encryption {
            try ZwzV3Compressor().compress(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                options: options,
                keyProvider: keyProvider,
                progress: progress,
                cancellationToken: cancellationToken
            )
            return
        }

        let v2Options = options.zwzV2Options
        let progressBox = ZwzProgressBox(progress)
        try cancellationToken?.checkCancellation()
        let existed = FileManager.default.fileExists(atPath: outputURL.path)
        do {
            _ = try waitForZwzAsync {
                try await ZwzV2Compressor(options: v2Options).compress(
                    sourceURLs: [sourceURL],
                    to: outputURL,
                    progress: { value in
                        progressBox.report(value)
                    },
                    cancellationToken: cancellationToken
                )
            }
            try cancellationToken?.checkCancellation()
        } catch {
            if !existed { try? FileManager.default.removeItem(at: outputURL) }
            throw error
        }
    }
}
