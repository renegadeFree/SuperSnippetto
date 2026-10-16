import Foundation

// Original implementation of the public LZ4 frame/block and XXH32 specifications:
// https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md
// https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md
// https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md
// Exactly one frame; dictionaries, skippable frames and concatenation are unsupported.
enum LZ4FrameCodec {
    enum DecodeError: LocalizedError {
        case truncated, invalid(String), unsupported(String), checksum(String), outputLimit, trailing
        var errorDescription: String? {
            switch self {
            case .truncated: return "Frame LZ4 troncato."
            case .invalid(let detail): return "Frame LZ4 non valido: \(detail)."
            case .unsupported(let detail): return "Formato LZ4 non supportato: \(detail)."
            case .checksum(let detail): return "Checksum LZ4 errato: \(detail)."
            case .outputLimit: return "Il contenuto LZ4 supera il limite di decompressione."
            case .trailing: return "Dati aggiuntivi dopo il frame LZ4."
            }
        }
    }

    private struct Reader {
        let bytes: UnsafeRawBufferPointer
        var index = 0
        mutating func take(_ count: Int) throws -> Range<Int> {
            guard count >= 0, count <= bytes.count - index else { throw DecodeError.truncated }
            let start = index
            index += count
            return start..<index
        }
        mutating func byte() throws -> UInt8 { bytes[try take(1).lowerBound] }
        mutating func u32() throws -> UInt32 {
            let start = try take(4).lowerBound
            return LZ4FrameCodec.word(bytes, start)
        }
        mutating func u64() throws -> UInt64 {
            let lo = try u32(), hi = try u32()
            return UInt64(lo) | (UInt64(hi) << 32)
        }
    }

    static func decode(_ data: Data, maxOutput: Int = 64 * 1024 * 1024) throws -> Data {
        guard maxOutput >= 0 else { throw DecodeError.outputLimit }
        return try data.withUnsafeBytes { bytes in
            var reader = Reader(bytes: bytes)
            guard try reader.u32() == 0x184D2204 else { throw DecodeError.unsupported("firma del frame") }
            let descriptorStart = reader.index
            let flags = try reader.byte(), blockDescriptor = try reader.byte()
            guard flags >> 6 == 1 else { throw DecodeError.unsupported("versione") }
            guard flags & 0x02 == 0, blockDescriptor & 0x8F == 0 else {
                throw DecodeError.invalid("bit riservati")
            }
            let blockID = Int((blockDescriptor >> 4) & 7)
            guard (4...7).contains(blockID) else { throw DecodeError.unsupported("dimensione blocco") }
            let blockMaximum = 1 << (8 + 2 * blockID)
            let contentSize: UInt64? = flags & 0x08 == 0 ? nil : try reader.u64()
            let dictionaryID: UInt32? = flags & 1 == 0 ? nil : try reader.u32()
            let descriptorEnd = reader.index
            let headerChecksum = try reader.byte()
            guard headerChecksum == UInt8(truncatingIfNeeded: hash(bytes, descriptorStart..<descriptorEnd) >> 8) else {
                throw DecodeError.checksum("intestazione")
            }
            if let dictionaryID { throw DecodeError.unsupported("dizionario \(dictionaryID)") }
            if let contentSize, contentSize > UInt64(maxOutput) { throw DecodeError.outputLimit }
            let independent = flags & 0x20 != 0
            var output: [UInt8] = []
            // Never reserve memory from an unchecked input length or declared content size.
            output.reserveCapacity(min(maxOutput, 65536))
            while true {
                let block = try reader.u32()
                if block == 0 { break }
                let size = Int(block & 0x7FFFFFFF)
                guard size <= blockMaximum else { throw DecodeError.invalid("blocco troppo grande") }
                let range = try reader.take(size)
                if flags & 0x10 != 0 {
                    guard try reader.u32() == hash(bytes, range) else { throw DecodeError.checksum("blocco") }
                }
                if block & 0x80000000 != 0 {
                    guard size <= maxOutput - output.count else { throw DecodeError.outputLimit }
                    output.append(contentsOf: bytes[range])
                } else {
                    try decodeBlock(bytes, range, into: &output, independent: independent,
                                    maximum: min(blockMaximum, maxOutput - output.count))
                }
            }
            if let contentSize, UInt64(output.count) != contentSize { throw DecodeError.invalid("dimensione contenuto") }
            if flags & 0x04 != 0 {
                let expected = try reader.u32()
                let actual = output.withUnsafeBytes { hash($0, 0..<$0.count) }
                guard expected == actual else { throw DecodeError.checksum("contenuto") }
            }
            guard reader.index == bytes.count else { throw DecodeError.trailing }
            return Data(output)
        }
    }

    private static func decodeBlock(_ bytes: UnsafeRawBufferPointer, _ range: Range<Int>,
                                    into output: inout [UInt8], independent: Bool, maximum: Int) throws {
        var index = range.lowerBound
        let start = output.count
        var lastMatchStart: Int?
        func length(_ nibble: Int, _ index: inout Int) throws -> Int {
            var count = nibble
            if nibble == 15 {
                var extra: UInt8
                repeat {
                    guard index < range.upperBound else { throw DecodeError.truncated }
                    extra = bytes[index]; index += 1
                    guard Int(extra) <= maximum - count else { throw DecodeError.outputLimit }
                    count += Int(extra)
                } while extra == 255
            }
            return count
        }
        while index < range.upperBound {
            let token = bytes[index]; index += 1
            let literals = try length(Int(token >> 4), &index)
            guard literals <= range.upperBound - index else { throw DecodeError.truncated }
            guard literals <= maximum - (output.count - start) else { throw DecodeError.outputLimit }
            output.append(contentsOf: bytes[index..<(index + literals)])
            index += literals
            if index == range.upperBound {
                if let lastMatchStart {
                    guard literals >= 5, output.count - start - lastMatchStart >= 12 else {
                        throw DecodeError.invalid("sequenza finale del blocco")
                    }
                }
                return
            }
            guard range.upperBound - index >= 2 else { throw DecodeError.truncated }
            let offset = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2
            let available = independent ? output.count - start : min(output.count, 65535)
            guard offset > 0, offset <= available else { throw DecodeError.invalid("offset del riferimento") }
            let extra = try length(Int(token & 15), &index)
            let remaining = maximum - (output.count - start)
            guard remaining >= 4, extra <= remaining - 4 else { throw DecodeError.outputLimit }
            lastMatchStart = output.count - start
            // Byte-by-byte copy intentionally supports overlapping matches (including offset 1).
            for _ in 0..<(extra + 4) { output.append(output[output.count - offset]) }
        }
        throw DecodeError.invalid("blocco compresso senza sequenza finale")
    }

    private static func word(_ bytes: UnsafeRawBufferPointer, _ index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 |
            UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }
    private static func rotate(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value << bits) | (value >> (32 - bits))
    }
    // Internal so the standalone tests can check published XXH32 vectors directly.
    static func xxHash32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { hash($0, 0..<$0.count) }
    }
    private static func hash(_ bytes: UnsafeRawBufferPointer, _ range: Range<Int>) -> UInt32 {
        let p1: UInt32 = 0x9E3779B1, p2: UInt32 = 0x85EBCA77, p3: UInt32 = 0xC2B2AE3D
        let p4: UInt32 = 0x27D4EB2F, p5: UInt32 = 0x165667B1
        func round(_ value: UInt32, _ lane: UInt32) -> UInt32 { rotate(value &+ lane &* p2, 13) &* p1 }
        var index = range.lowerBound
        var result: UInt32
        if range.count >= 16 {
            var a = p1 &+ p2, b = p2, c: UInt32 = 0, d = UInt32(0) &- p1
            repeat {
                a = round(a, word(bytes, index)); b = round(b, word(bytes, index + 4))
                c = round(c, word(bytes, index + 8)); d = round(d, word(bytes, index + 12))
                index += 16
            } while range.upperBound - index >= 16
            result = rotate(a, 1) &+ rotate(b, 7) &+ rotate(c, 12) &+ rotate(d, 18)
        } else { result = p5 }
        result = result &+ UInt32(truncatingIfNeeded: range.count)
        while range.upperBound - index >= 4 {
            result = rotate(result &+ word(bytes, index) &* p3, 17) &* p4
            index += 4
        }
        while index < range.upperBound {
            result = rotate(result &+ UInt32(bytes[index]) &* p5, 11) &* p1
            index += 1
        }
        result ^= result >> 15; result = result &* p2
        result ^= result >> 13; result = result &* p3
        return result ^ (result >> 16)
    }
}
