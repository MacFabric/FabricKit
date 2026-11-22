import Foundation
import Testing
@testable import FabricKit

@Suite("CRC32C digest")
struct CRC32CTests {
    // RFC 7143 §13.1 / RFC 3720 B.4 test patterns. The RFC gives the wire
    // byte sequences; values here are those bytes read little-endian.
    @Test func rfcZeroVector() {
        let bytes = [UInt8](repeating: 0x00, count: 32)
        #expect(CRC32C.checksum(bytes) == 0x8A91_36AA)
        #expect(CRC32C.wireDigest(bytes) == Data([0xAA, 0x36, 0x91, 0x8A]))
    }

    @Test func rfcOnesVector() {
        let bytes = [UInt8](repeating: 0xFF, count: 32)
        #expect(CRC32C.checksum(bytes) == 0x62A8_AB43)
        #expect(CRC32C.wireDigest(bytes) == Data([0x43, 0xAB, 0xA8, 0x62]))
    }

    @Test func rfcIncrementingVector() {
        let bytes = (UInt8(0) ..< 32).map { $0 }
        #expect(CRC32C.checksum(bytes) == 0x46DD_794E)
        #expect(CRC32C.wireDigest(bytes) == Data([0x4E, 0x79, 0xDD, 0x46]))
    }

    @Test func rfcDecrementingVector() {
        let bytes = (UInt8(0) ..< 32).map { 31 - $0 }
        #expect(CRC32C.checksum(bytes) == 0x113F_DB5C)
        #expect(CRC32C.wireDigest(bytes) == Data([0x5C, 0xDB, 0x3F, 0x11]))
    }

    /// Standard CRC-32C check value for "123456789".
    @Test func checkValue() {
        #expect(CRC32C.checksum(Array("123456789".utf8)) == 0xE306_9283)
    }

    @Test func emptyInput() {
        #expect(CRC32C.checksum([]) == 0)
    }
}

// MARK: - Accelerated implementation

@Suite("CRC32C acceleration")
struct CRC32CAccelTests {
    /// The streaming API must agree with the one-shot for every split point,
    /// including splits that land mid-8-byte-word — the hardware path consumes
    /// 8 bytes at a time and handles the tail separately, which is exactly
    /// where a chained digest goes wrong.
    @Test func chunkedMatchesOneShot() {
        let data = Data((0 ..< 1000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let expected = CRC32C.checksum(data)
        for split in [0, 1, 7, 8, 9, 15, 16, 63, 64, 65, 511, 999, 1000] {
            var crc: UInt32 = 0xFFFF_FFFF
            crc = data.prefix(split).withUnsafeBytes { CRC32C.update(crc, $0) }
            crc = data.dropFirst(split).withUnsafeBytes { CRC32C.update(crc, $0) }
            #expect(CRC32C.finalize(crc) == expected, "split at \(split)")
        }
    }

    /// Data, [UInt8] and the generic Sequence overload must not diverge; the
    /// fast paths are separate code.
    @Test func overloadsAgree() {
        let bytes = (0 ..< 257).map { UInt8($0 & 0xFF) }
        let viaArray = CRC32C.checksum(bytes)
        let viaData = CRC32C.checksum(Data(bytes))
        let viaSequence = CRC32C.checksum(AnySequence(bytes))
        #expect(viaArray == viaData)
        #expect(viaArray == viaSequence)
    }

    /// Lengths around the 8-byte block boundary, where the tail loop runs.
    @Test func allTailLengthsAreCorrect() {
        // Reference: the original byte-at-a-time definition.
        func reference(_ b: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in b {
                crc ^= UInt32(byte)
                for _ in 0 ..< 8 {
                    crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x82F6_3B78 : crc >> 1
                }
            }
            return crc ^ 0xFFFF_FFFF
        }
        for len in 0 ... 40 {
            let b = (0 ..< len).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) }
            #expect(CRC32C.checksum(b) == reference(b), "length \(len)")
        }
    }
}

// MARK: - Three streams at once

@Suite("CRC32C folding")
struct CRC32CFoldingTests {
    /// CRC-32C one bit at a time: no table, no instruction, nothing shared
    /// with the implementation under test.
    static func reference(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var crc = crc
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x82F6_3B78 : 0) }
        }
        return crc
    }

    /// x^n mod P in the instruction's bit order, where bit 31 is x^0.
    static func xPower(_ n: Int) -> UInt32 {
        var v: UInt32 = 0x8000_0000
        for _ in 0 ..< n { v = (v >> 1) ^ (v & 1 == 1 ? 0x82F6_3B78 : 0) }
        return v
    }

    /// The constants in ccrc32c.c, derived again: x^(16N-33) and x^(8N-33).
    @Test func theFoldingConstantsAreWhatTheMathSays() {
        #expect(Self.xPower(16 * 4096 - 33) == 0x54A8_6326)
        #expect(Self.xPower(8 * 4096 - 33) == 0x82F8_9C77)
        #expect(Self.xPower(16 * 512 - 33) == 0x1700_76FA)
        #expect(Self.xPower(8 * 512 - 33) == 0xDD7E_3B0C)
        #expect(Self.xPower(16 * 64 - 33) == 0x0D3B_6092)
        #expect(Self.xPower(8 * 64 - 33) == 0x9E4A_DDF8)
    }

    private static let noise: [UInt8] = {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0 ..< 70_000).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
    }()

    /// Every length around each block size's threshold and its multiples,
    /// which is where a stream boundary or a leftover tail would go wrong.
    @Test func everyLengthAroundEachBlockSizeMatchesTheReference() {
        var lengths = Set(0 ... 600)
        for edge in [3 * 64, 6 * 64, 3 * 512, 3 * 512 + 3 * 64, 6 * 512, 3 * 4096, 3 * 4096 + 3 * 512,
                     6 * 4096, 65536, 65536 + 48] {
            for delta in -9 ... 9 { lengths.insert(edge + delta) }
        }
        Self.noise.withUnsafeBytes { all in
            for length in lengths.sorted() {
                let slice = UnsafeRawBufferPointer(rebasing: all[0 ..< length])
                #expect(CRC32C.update(CRC32C.initial, slice) == Self.reference(CRC32C.initial, slice),
                        "length \(length)")
            }
        }
    }

    /// The loads are unaligned on purpose: a data segment starts wherever the
    /// network left it. And the running CRC coming in is arbitrary, not the
    /// initial value: stream A carries it through the fold.
    @Test func anyAlignmentAndAnyIncomingStateMatchesTheReference() {
        Self.noise.withUnsafeBytes { all in
            for offset in 0 ..< 9 {
                for length in [191, 192, 200, 1536, 1543, 12288, 12301, 40_000] {
                    for seed: UInt32 in [0, 0xFFFF_FFFF, 0x1234_5678, 0x8000_0001] {
                        let slice = UnsafeRawBufferPointer(rebasing: all[offset ..< offset + length])
                        #expect(CRC32C.update(seed, slice) == Self.reference(seed, slice),
                                "offset \(offset) length \(length) seed \(seed)")
                    }
                }
            }
        }
    }

    /// Chained over arbitrary pieces, as the framer does for a segment and
    /// its padding, it still comes to the one-shot value.
    @Test func chainingAcrossPiecesOfEverySizeMatchesOneShot() {
        Self.noise.withUnsafeBytes { all in
            let whole = UnsafeRawBufferPointer(rebasing: all[0 ..< 50_000])
            let expected = Self.reference(CRC32C.initial, whole)
            for piece in [1, 7, 64, 191, 193, 1000, 4096, 12288, 12289, 30_000] {
                var crc = CRC32C.initial
                var at = 0
                while at < whole.count {
                    let end = min(at + piece, whole.count)
                    crc = CRC32C.update(crc, UnsafeRawBufferPointer(rebasing: whole[at ..< end]))
                    at = end
                }
                #expect(crc == expected, "pieces of \(piece)")
            }
        }
    }
}
