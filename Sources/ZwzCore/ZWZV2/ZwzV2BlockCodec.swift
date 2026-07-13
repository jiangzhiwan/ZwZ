import Foundation
import SWCompression

public struct ZwzV2EncodedBlock: Equatable {
    public var codec: ZwzV2Codec
    public var payload: Data
    public var originalLength: Int
    public var checksum: UInt32

    public init(codec: ZwzV2Codec, payload: Data, originalLength: Int, checksum: UInt32) {
        self.codec = codec
        self.payload = payload
        self.originalLength = originalLength
        self.checksum = checksum
    }
}

public enum ZwzV2BlockCodec {
    public static func encode(_ data: Data, level: ZwzV2CompressionLevel) throws -> ZwzV2EncodedBlock {
        let encoded: (codec: ZwzV2Codec, payload: Data)

        switch level {
        case .none:
            encoded = (.store, data)
        case .fastest:
            let lz4 = LZ4.compress(data: data)
            encoded = lz4.count + 40 < data.count ? (.lz4, lz4) : (.store, data)
        case .normal:
            let lz4 = LZ4.compress(data: data)
            let hasRepetition = hasRepetition(in: data)
            let deflate = hasRepetition ? Deflate.compress(data: data) : nil
            switch selectNormalCodec(
                inputCount: data.count,
                lz4Count: lz4.count,
                deflateCount: deflate?.count ?? 0,
                hasRepetition: hasRepetition
            ) {
            case .lz4:
                encoded = (.lz4, lz4)
            case .deflate:
                encoded = (.deflate, deflate!)
            case .store:
                encoded = (.store, data)
            }
        case .max:
            let deflate = Deflate.compress(data: data)
            encoded = deflate.count + 40 < data.count ? (.deflate, deflate) : (.store, data)
        }

        return ZwzV2EncodedBlock(
            codec: encoded.codec,
            payload: encoded.payload,
            originalLength: data.count,
            checksum: checksum(of: data)
        )
    }

    public static func decode(_ block: ZwzV2EncodedBlock) throws -> Data {
        let data = try decode(
            codec: block.codec,
            payload: block.payload,
            originalLength: block.originalLength,
            sequence: 0
        )
        guard checksum(of: data) == block.checksum else {
            throw ZwzV2Error.checksumMismatch(sequence: 0)
        }
        return data
    }

    public static func decode(
        codec: ZwzV2Codec,
        payload: Data,
        originalLength: Int,
        sequence: UInt64
    ) throws -> Data {
        guard originalLength >= 0 else {
            throw ZwzV2Error.decompressionFailed(sequence: sequence)
        }

        let data: Data
        do {
            switch codec {
            case .store:
                data = payload
            case .lz4:
                data = try LZ4.decompress(data: payload)
            case .deflate:
                data = try Deflate.decompress(data: payload)
            }
        } catch {
            throw ZwzV2Error.decompressionFailed(sequence: sequence)
        }

        guard data.count == originalLength else {
            throw ZwzV2Error.decompressionFailed(sequence: sequence)
        }
        return data
    }

    private static func saves(atLeast percent: Int, compressedCount: Int, inputCount: Int) -> Bool {
        compressedCount * 100 <= inputCount * (100 - percent)
    }

    private static func beatsLZ4ByAtLeast8Percent(deflateCount: Int, lz4Count: Int) -> Bool {
        deflateCount * 100 <= lz4Count * 92
    }

    // Kept internal so tests can pin the threshold decision without exposing it publicly.
    static func selectNormalCodec(
        inputCount: Int,
        lz4Count: Int,
        deflateCount: Int,
        hasRepetition: Bool
    ) -> ZwzV2Codec {
        if saves(atLeast: 12, compressedCount: lz4Count, inputCount: inputCount) {
            return .lz4
        }
        if hasRepetition,
           beatsLZ4ByAtLeast8Percent(deflateCount: deflateCount, lz4Count: lz4Count),
           saves(atLeast: 1, compressedCount: deflateCount, inputCount: inputCount) {
            return .deflate
        }
        if saves(atLeast: 1, compressedCount: lz4Count, inputCount: inputCount) {
            return .lz4
        }
        return .store
    }

    private static func hasRepetition(in data: Data) -> Bool {
        let sample = data.prefix(64 * 1024)
        guard sample.count >= 8 else { return false }

        var byteRuns = 0
        var tokenMatches = 0
        var tokens = Set<UInt32>()
        var previous: UInt8?
        var runLength = 0
        let bytes = Array(sample)

        for byte in bytes {
            if byte == previous {
                runLength += 1
                if runLength == 4 { byteRuns += 1 }
            } else {
                previous = byte
                runLength = 1
            }
        }

        for index in 0...(bytes.count - 4) {
            let token = UInt32(bytes[index])
                | UInt32(bytes[index + 1]) << 8
                | UInt32(bytes[index + 2]) << 16
                | UInt32(bytes[index + 3]) << 24
            if !tokens.insert(token).inserted { tokenMatches += 1 }
        }

        return byteRuns * 100 >= bytes.count || tokenMatches * 100 >= bytes.count * 10
    }

    private static func checksum(of data: Data) -> UInt32 {
        var value: UInt32 = 2_166_136_261
        for byte in data {
            value ^= UInt32(byte)
            value &*= 16_777_619
        }
        return value
    }
}
