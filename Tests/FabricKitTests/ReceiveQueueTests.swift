import Foundation
import Testing
@testable import FabricKit

@Suite("Receive queue")
struct ReceiveQueueTests {
    private static func noise(_ count: Int, seed: UInt64 = 1) -> Data {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        return Data((0 ..< count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        })
    }

    /// Fed in pieces of every shape and taken out in pieces of every other
    /// shape, by every operation, the bytes come out in order and complete.
    @Test func whateverTheChunkingTheBytesComeOutInOrder() {
        let stream = Self.noise(20_000)
        for chunkSize in [1, 3, 7, 48, 1000, 4096, 20_000] {
            for takeSize in [1, 5, 48, 333, 5000] {
                var queue = ReceiveQueue()
                var fed = 0
                var out = Data()
                var step = 0
                while out.count < stream.count {
                    if fed < stream.count, queue.count < takeSize || step % 3 == 0 {
                        let end = min(fed + chunkSize, stream.count)
                        // A slice, as a transport may hand over.
                        queue.append(stream[fed ..< end])
                        fed = end
                    }
                    let n = min(takeSize, queue.count)
                    #expect(queue.count == fed - out.count)
                    if n > 0 { #expect(queue.byte(at: n - 1) == stream[out.count + n - 1]) }
                    switch step % 4 {
                    case 0:
                        out.append(queue.read(n))
                    case 1:
                        #expect(queue.peek(n) == stream.subdata(in: out.count ..< out.count + n))
                        if n > 1 {
                            #expect(queue.peek(n - 1, skippingFirst: 1)
                                    == stream.subdata(in: out.count + 1 ..< out.count + n))
                        }
                        out.append(queue.peek(n))
                        queue.skip(n)
                    default:
                        var piece = Data(count: takeSize)
                        let got = piece.withUnsafeMutableBytes { queue.read(into: $0) }
                        #expect(got == n)
                        out.append(piece.prefix(got))
                    }
                    step += 1
                }
                #expect(out == stream, "chunks of \(chunkSize), taken \(takeSize) at a time")
                #expect(queue.isEmpty)
            }
        }
    }

    @Test func emptyChunksAndEmptyReadsAreNothing() {
        var queue = ReceiveQueue()
        queue.append(Data())
        #expect(queue.isEmpty)
        #expect(queue.read(0) == Data())
        #expect(queue.peek(0) == Data())
        queue.append(Data([1, 2, 3]))
        queue.append(Data())
        queue.skip(0)
        var none = Data()
        #expect(none.withUnsafeMutableBytes { queue.read(into: $0) } == 0)
        #expect(queue.read(3) == Data([1, 2, 3]))
        #expect(queue.isEmpty)
    }

    /// A consumed chunk is let go at once: the queue must not keep the bytes
    /// of everything that ever passed through it.
    @Test func aConsumedChunkIsReleased() {
        final class Witness: @unchecked Sendable { var freed = 0 }
        let witness = Witness()
        var queue = ReceiveQueue()
        for _ in 0 ..< 100 {
            let memory = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
            memory.initializeMemory(as: UInt8.self, repeating: 7, count: 4096)
            queue.append(Data(bytesNoCopy: memory, count: 4096, deallocator: .custom { p, _ in
                witness.freed += 1
                p.deallocate()
            }))
            queue.skip(4000)
            #expect(queue.read(96) == Data(repeating: 7, count: 96))
        }
        #expect(witness.freed == 100)
        #expect(queue.isEmpty)
    }
}

@Suite("Read buffer")
struct ReadBufferTests {
    @Test func regionsWriteWhereTheySayAndTheDataSharesTheMemory() {
        let buffer = ReadBuffer(count: 64)
        buffer.zero(0 ..< 64)
        let first = ReadBuffer.Region(buffer: buffer, offset: 0, count: 16)
        let second = ReadBuffer.Region(buffer: buffer, offset: 16, count: 48)
        first.write(Data(repeating: 1, count: 16), at: 0)
        second.write(Data([9, 9]), at: 4)
        second.bytes(40 ..< 48).initializeMemory(as: UInt8.self, repeating: 5)
        var expected = Data(repeating: 1, count: 16) + Data(count: 48)
        expected.replaceSubrange(20 ..< 22, with: [9, 9])
        expected.replaceSubrange(56 ..< 64, with: Data(repeating: 5, count: 8))
        let data = buffer.data()
        #expect(data == expected)
        #expect(second.data(prefix: 6) == expected.subdata(in: 16 ..< 22))
        // No copy was made on the way out.
        let address = data.withUnsafeBytes { $0.baseAddress }
        #expect(address == UnsafeRawPointer(buffer.bytes(0 ..< 64).baseAddress))
        #expect(buffer.whole.count == 64)
    }

    /// The `Data` keeps the memory alive after every other reference is gone.
    @Test func theDataOutlivesTheBuffer() {
        var data: Data
        do {
            let buffer = ReadBuffer(count: 1 << 16)
            buffer.bytes(0 ..< 1 << 16).initializeMemory(as: UInt8.self, repeating: 0xAB)
            data = buffer.data(100 ..< 1 << 16)
        }
        #expect(data.count == (1 << 16) - 100)
        #expect(data.allSatisfy { $0 == 0xAB })
        // And is an ordinary value: a change to it is the holder's own.
        data[data.startIndex] = 1
        #expect(data.first == 1)
    }

    @Test func anEmptyBufferIsUsable() {
        let buffer = ReadBuffer(count: 0)
        #expect(buffer.data() == Data())
        buffer.zero(0 ..< 0)
        #expect(buffer.whole.data(prefix: 0) == Data())
    }
}
