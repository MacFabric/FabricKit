import Foundation
import Testing
@testable import FabricKit

/// The bounds check both block devices share. It runs in the root daemon on
/// lengths an XPC client chose, so every bad request has to be an error and
/// never a trap.
@Suite("Block request bounds")
struct BlockRequestTests {
    @Test func anAlignedRequestInsideTheDeviceIsAccepted() throws {
        try BlockRequest.validate(offset: 4096, length: 8192, blockSize: 512, capacity: 100)
        try BlockRequest.validate(offset: 0, length: 0, blockSize: 4096, capacity: 1)
        try BlockRequest.validate(offset: 99 * 512, length: 512, blockSize: 512, capacity: 100)
    }

    @Test func misalignmentAndNegativeLengthsAreRefused() {
        #expect(throws: BlockDeviceError.self) {
            try BlockRequest.validate(offset: 100, length: 512, blockSize: 512, capacity: 100)
        }
        #expect(throws: BlockDeviceError.self) {
            try BlockRequest.validate(offset: 0, length: 100, blockSize: 512, capacity: 100)
        }
        #expect(throws: BlockDeviceError.self) {
            try BlockRequest.validate(offset: 0, length: -512, blockSize: 512, capacity: 100)
        }
    }

    /// 2^44 bytes of 512-byte blocks is 2^35 blocks: the old check narrowed
    /// that to 32 bits before comparing it, and trapped.
    @Test func aLengthPastThirtyTwoBitsOfBlocksIsOutOfRangeNotATrap() {
        #expect(throws: BlockDeviceError.self) {
            try BlockRequest.validate(offset: 0, length: 1 << 44, blockSize: 512, capacity: 1 << 30)
        }
    }

    @Test func anEndPastTheDeviceIsOutOfRange() {
        #expect(throws: BlockDeviceError.self) {
            try BlockRequest.validate(offset: 100 * 512, length: 512, blockSize: 512, capacity: 100)
        }
        #expect(throws: BlockDeviceError.self) {
            try BlockRequest.validate(offset: UInt64.max - 511, length: 1024, blockSize: 512,
                                      capacity: 1 << 50)
        }
    }
}
