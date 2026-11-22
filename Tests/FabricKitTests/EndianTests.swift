import Foundation
import Testing
@testable import FabricKit

@Suite("Big-endian field helpers")
struct EndianTests {
    /// A slice with a non-zero start, which is what the framer hands out.
    private func slice() -> Data {
        Data((0 ..< 64).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })[5 ..< 53]
    }

    @Test func readsAgreeWithTheBytesAtEveryOffset() {
        let data = slice()
        let bytes = [UInt8](data)
        for offset in 0 ... data.count - 8 {
            #expect(data.u8(offset) == bytes[offset])
            #expect(data.beU16(offset) == UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
            #expect(data.beU24(offset) == UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8
                    | UInt32(bytes[offset + 2]))
            let be32 = bytes[offset ..< offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let be64 = bytes[offset ..< offset + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            #expect(data.beU32(offset) == be32)
            #expect(data.beU64(offset) == be64)
        }
        // The last field that fits, for each width.
        #expect(data.beU16(data.count - 2) == UInt16(bytes[bytes.count - 2]) << 8 | UInt16(bytes[bytes.count - 1]))
        #expect(data.beU32(data.count - 4) == bytes.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    @Test func writesLandOnTheRightBytesAndNowhereElse() {
        for offset in [0, 1, 3, 17, 40] {
            var data = slice()
            let before = [UInt8](data)
            data.setBE64(0x0102_0304_0506_0708, offset)
            var expected = before
            expected.replaceSubrange(offset ..< offset + 8, with: [1, 2, 3, 4, 5, 6, 7, 8])
            #expect([UInt8](data) == expected)
            #expect(data.beU64(offset) == 0x0102_0304_0506_0708)

            data = slice()
            data.setBE32(0xA1B2_C3D4, offset)
            expected = before
            expected.replaceSubrange(offset ..< offset + 4, with: [0xA1, 0xB2, 0xC3, 0xD4])
            #expect([UInt8](data) == expected)

            data = slice()
            data.setBE16(0xBEEF, offset)
            expected = before
            expected.replaceSubrange(offset ..< offset + 2, with: [0xBE, 0xEF])
            #expect([UInt8](data) == expected)

            data = slice()
            data.setBE24(0x0A0B0C, offset)
            expected = before
            expected.replaceSubrange(offset ..< offset + 3, with: [0x0A, 0x0B, 0x0C])
            #expect([UInt8](data) == expected)
        }
    }

    /// A write through a slice must not reach the buffer it was cut from.
    @Test func aWriteToASliceLeavesItsParentAlone() {
        let parent = Data(repeating: 0x55, count: 32)
        var child = parent[8 ..< 24]
        child.setBE32(0, 4)
        #expect(parent == Data(repeating: 0x55, count: 32))
        #expect(child.beU32(4) == 0)
        #expect(child.startIndex == 8)
    }
}
