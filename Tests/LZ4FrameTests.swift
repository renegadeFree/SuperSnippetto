import Foundation

@main
struct LZ4FrameTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1
        do { guard try condition() else { fatalError("FAILED: \(message)") } }
        catch { fatalError("FAILED: \(message): \(error)") }
    }
    static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError("FAILED: expected error: \(message)") }
        catch { checks += 1 }
    }
    static func u32(_ number: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) })
    }
    // Fixture encoder writes the frame layout directly; it never uses the decoder.
    // Checksum arithmetic is separately verified against the upstream published vectors below.
    static func frame(_ blocks: [(Data, Bool)], flags: UInt8 = 0x60, bd: UInt8 = 0x40,
                      contentSize: UInt64? = nil, content: Data = Data(), dictionary: UInt32 = 0) -> Data {
        var descriptor = Data([flags, bd])
        if flags & 8 != 0 {
            let size = contentSize ?? UInt64(content.count)
            descriptor.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) })
        }
        if flags & 1 != 0 { descriptor.append(u32(dictionary)) }
        var result = Data([4, 0x22, 0x4D, 0x18]) + descriptor
        result.append(UInt8(truncatingIfNeeded: LZ4FrameCodec.xxHash32(descriptor) >> 8))
        for (data, raw) in blocks {
            result.append(u32(UInt32(data.count) | (raw ? 0x80000000 : 0)))
            result.append(data)
            if flags & 0x10 != 0 { result.append(u32(LZ4FrameCodec.xxHash32(data))) }
        }
        result.append(u32(0))
        if flags & 4 != 0 { result.append(u32(LZ4FrameCodec.xxHash32(content))) }
        return result
    }
    static func main() throws {
        // Published XXH32 sanity vectors and deterministic input recipe, seed 0:
        // https://github.com/Cyan4973/xxHash/blob/v0.7.0/xxhsum.c (BMK_sanityCheck).
        var sanity = Data(), generator: UInt32 = 2654435761
        for _ in 0..<222 { sanity.append(UInt8(generator >> 24)); generator = generator &* generator }
        for (length, expected): (Int, UInt32) in [(0, 0x02CC5D05), (1, 0xB85CBEE5), (14, 0xE5AA0AB4), (222, 0xC8070816)] {
            check(LZ4FrameCodec.xxHash32(sanity.prefix(length)) == expected, "published XXH32 vector length \(length)")
        }

        // The standard empty independent frame has the known header checksum 0x82.
        let empty = Data([4, 0x22, 0x4D, 0x18, 0x60, 0x40, 0x82, 0, 0, 0, 0])
        check(try LZ4FrameCodec.decode(empty, maxOutput: 0).isEmpty, "known empty frame, zero budget")
        let hello = Data("hello".utf8)
        check(try LZ4FrameCodec.decode(frame([(hello, true)])) == hello, "raw block")
        check(try LZ4FrameCodec.decode(frame([(Data([0x50]) + hello, false)])) == hello, "literal-only compressed block")
        check(try LZ4FrameCodec.decode(frame([(Data([0]), false)])).isEmpty, "empty compressed block")
        check(try LZ4FrameCodec.decode(frame([(Data(), true)], flags: 0x74)).isEmpty, "empty raw block has checksum and is not end marker")

        let trailer = Data("12345".utf8)
        // One literal 'a', offset 1 and match length 15, then five final literals.
        let overlap = Data([0x1B, 0x61, 1, 0, 0x50]) + trailer
        let overlapText = Data(repeating: 0x61, count: 16) + trailer
        check(try LZ4FrameCodec.decode(frame([(overlap, false)])) == overlapText, "overlapping offset-one match")
        // A longer match includes the mandatory length extension byte (15 + 0 + 4).
        let extended = Data([0x1F, 0x61, 1, 0, 0, 0x50]) + trailer
        let extendedText = Data(repeating: 0x61, count: 20) + trailer
        check(try LZ4FrameCodec.decode(frame([(extended, false)])) == extendedText, "match length extension")
        let longLiterals = Data(repeating: 0x62, count: 285)
        check(try LZ4FrameCodec.decode(frame([(Data([0xF0, 255, 15]) + longLiterals, false)])) == longLiterals, "literal length extension with continuation")

        let history = Data("abcd".utf8)
        let dependent = Data([0x08, 4, 0, 0x50]) + trailer
        let dependentText = Data("abcdabcdabcdabcd12345".utf8)
        check(try LZ4FrameCodec.decode(frame([(history, true), (dependent, false)], flags: 0x40)) == dependentText, "dependent block references previous raw block")
        rejects("independent block cannot reference earlier block") {
            _ = try LZ4FrameCodec.decode(frame([(history, true), (dependent, false)]))
        }
        let deepHistory = Data(repeating: 0x78, count: 65536)
        let farMatch = Data([0x08, 0xFF, 0xFF, 0x50]) + trailer
        check(try LZ4FrameCodec.decode(frame([(deepHistory, true), (farMatch, false)], flags: 0x40)) == deepHistory + Data(repeating: 0x78, count: 12) + trailer, "maximum offset 65535 across block boundary")
        for bd: UInt8 in [0x40, 0x50, 0x60, 0x70] {
            check(try LZ4FrameCodec.decode(frame([(hello, true)], bd: bd)) == hello, "all four standard block capacities")
        }

        let complete = frame([(overlap, false), (hello, true)], flags: 0x7C, content: overlapText + hello)
        check(try LZ4FrameCodec.decode(complete) == overlapText + hello, "header, block and content checksums plus content size")
        check(try LZ4FrameCodec.decode(complete, maxOutput: 26) == overlapText + hello, "exact output budget")
        rejects("content size over budget") { _ = try LZ4FrameCodec.decode(complete, maxOutput: 25) }
        rejects("negative output budget") { _ = try LZ4FrameCodec.decode(empty, maxOutput: -1) }
        rejects("raw output over budget") { _ = try LZ4FrameCodec.decode(frame([(hello, true)]), maxOutput: 4) }
        rejects("compressed output over budget") { _ = try LZ4FrameCodec.decode(frame([(overlap, false)]), maxOutput: 20) }
        rejects("literal extension over budget") { _ = try LZ4FrameCodec.decode(frame([(Data([0xF0, 255]), false)]), maxOutput: 20) }
        rejects("declared content size mismatch") { _ = try LZ4FrameCodec.decode(frame([(hello, true)], flags: 0x68, contentSize: 4)) }
        rejects("UInt64 max content size cannot overflow") { _ = try LZ4FrameCodec.decode(frame([], flags: 0x68, contentSize: UInt64.max)) }

        var badHeader = complete; badHeader[14] ^= 1
        rejects("header checksum") { _ = try LZ4FrameCodec.decode(badHeader) }
        var badBlock = complete; badBlock[19] ^= 1
        rejects("block checksum") { _ = try LZ4FrameCodec.decode(badBlock) }
        var badContent = complete; badContent[badContent.count - 1] ^= 1
        rejects("content checksum") { _ = try LZ4FrameCodec.decode(badContent) }
        for flags: UInt8 in [0, 0x80, 0xC0, 0x62] {
            rejects("invalid version or reserved flag") { _ = try LZ4FrameCodec.decode(frame([], flags: flags)) }
        }
        for bd: UInt8 in [0, 0x30, 0x41, 0xC0] {
            rejects("reserved block descriptor or unsupported size") { _ = try LZ4FrameCodec.decode(frame([], bd: bd)) }
        }
        do {
            _ = try LZ4FrameCodec.decode(frame([], flags: 0x61, dictionary: 42))
            fatalError("FAILED: dictionary accepted")
        } catch LZ4FrameCodec.DecodeError.unsupported(let message) {
            check(message.contains("dizionario 42"), "dictionary reports explicit unsupported identifier")
        }
        var badMagic = empty; badMagic[0] = 0
        rejects("unknown magic") { _ = try LZ4FrameCodec.decode(badMagic) }
        rejects("oversized encoded block") { _ = try LZ4FrameCodec.decode(frame([(Data(repeating: 0, count: 65537), true)])) }
        let oversizedExpanded = Data([0x1F, 0x61, 1, 0]) + Data(repeating: 255, count: 258) + Data([0, 0x50]) + trailer
        rejects("expanded block exceeds declared block capacity") { _ = try LZ4FrameCodec.decode(frame([(oversizedExpanded, false)])) }
        for invalid in [Data([0x10, 0x61, 0, 0, 0x50]) + trailer, // zero offset
                        Data([0, 1, 0, 0x50]) + trailer,         // offset before beginning
                        Data([0x50, 0x61]),                     // missing literals
                        Data([0xF0, 255]),                      // truncated length
                        Data([0x10, 0x61, 1]),                  // truncated offset
                        Data([0x1F, 0x61, 1, 0]),               // missing match length
                        Data([0x18, 0x61, 1, 0]),               // no final sequence
                        Data([0x18, 0x61, 1, 0, 0]),            // fewer than 5 final literals
                        Data([0x10, 0x61, 1, 0, 0x50]) + trailer] { // last match starts too late
            rejects("malformed compressed block") { _ = try LZ4FrameCodec.decode(frame([(invalid, false)])) }
        }
        for count in 0..<complete.count {
            rejects("truncated frame at byte \(count)") { _ = try LZ4FrameCodec.decode(complete.prefix(count)) }
        }
        rejects("trailing junk") { _ = try LZ4FrameCodec.decode(empty + Data([0])) }
        rejects("concatenated frames") { _ = try LZ4FrameCodec.decode(empty + empty) }
        // Data slices can have a nonzero startIndex; the decoder uses a rebased raw buffer.
        check(try LZ4FrameCodec.decode((Data([0xFF]) + complete).dropFirst()) == overlapText + hello, "nonzero-index Data slice")
        print("LZ4 frame: \(checks) checks passed")
    }
}
