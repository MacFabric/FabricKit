#if canImport(Network)
import Foundation
import Testing
@testable import FabricKit
@testable import FabricTestSupport

/// `send(contentsOf:)` over real TCP. A PDU goes out as a header and a
/// payload in separate buffers; if another sender's bytes could land between
/// the two, the stream would lose framing for good.
@Suite("Multi-part sends")
struct MultiPartSendTests {

    /// Collects everything one connection delivers.
    private actor Sink {
        private(set) var bytes = Data()
        private var waiters: [(Int, CheckedContinuation<Data, Never>)] = []
        func append(_ chunk: Data) {
            bytes.append(chunk)
            waiters.removeAll { want, c in
                guard bytes.count >= want else { return false }
                c.resume(returning: bytes)
                return true
            }
        }
        func wait(for count: Int) async -> Data {
            if bytes.count >= count { return bytes }
            return await withCheckedContinuation { waiters.append((count, $0)) }
        }
    }

    @Test("the parts of one send stay adjacent while others send at the same time")
    func partsStayAdjacent() async throws {
        let sink = Sink()
        let server = try MockTargetServer { transport in
            while let chunk = try? await transport.receive() { await sink.append(chunk) }
        }
        let port = try await server.start()
        let client = try await NetworkTransport.connect(host: "127.0.0.1", port: port)

        // Each record: sender, body length, then that many bytes of `sender`.
        let senders = 8
        let rounds = 60
        var total = 0
        var lengths: [[Int]] = []
        for sender in 0 ..< senders {
            lengths.append((0 ..< rounds).map { 1 + (sender * 7919 + $0 * 104_729) % 70_000 })
            total += lengths[sender].reduce(0) { $0 + $1 + 5 }
        }
        let plan = lengths
        try await withThrowingTaskGroup(of: Void.self) { group in
            for sender in 0 ..< senders {
                group.addTask {
                    for length in plan[sender] {
                        var header = Data([UInt8(sender)])
                        withUnsafeBytes(of: UInt32(length).bigEndian) { header.append(contentsOf: $0) }
                        // A slice with a non-zero start, split in two: three
                        // parts, as a padded PDU with a digest would be.
                        let body = Data(repeating: UInt8(sender), count: length + 3)[3...]
                        let cut = body.startIndex + length / 2
                        try await client.send(contentsOf: [header, body[..<cut], body[cut...]])
                    }
                }
            }
            try await group.waitForAll()
        }

        let received = await sink.wait(for: total)
        #expect(received.count == total)
        var at = 0
        var seen = [Int](repeating: 0, count: senders)
        while at + 5 <= received.count {
            let sender = Int(received[at])
            let length = Int(received.beU32(at + 1))
            guard sender < senders, at + 5 + length <= received.count else {
                Issue.record("lost framing at byte \(at)")
                break
            }
            let body = received[at + 5 ..< at + 5 + length]
            #expect(body.allSatisfy { $0 == UInt8(sender) }, "another send's bytes inside record at \(at)")
            #expect(length == plan[sender][seen[sender]], "one sender's records out of order")
            seen[sender] += 1
            at += 5 + length
        }
        #expect(seen == [Int](repeating: rounds, count: senders))
        await client.close()
        await server.stop()
    }

    @Test("empty parts and an empty send are accepted and add nothing")
    func emptyParts() async throws {
        let sink = Sink()
        let server = try MockTargetServer { transport in
            while let chunk = try? await transport.receive() { await sink.append(chunk) }
        }
        let port = try await server.start()
        let client = try await NetworkTransport.connect(host: "127.0.0.1", port: port)
        try await client.send(contentsOf: [])
        try await client.send(contentsOf: [Data(), Data([1, 2]), Data(), Data([3])])
        try await client.send(Data())
        try await client.send(Data([4]))
        #expect(await sink.wait(for: 4) == Data([1, 2, 3, 4]))
        await client.close()
        await server.stop()
    }

    /// Large parts go to the connection as references to the caller's
    /// bytes, not copies. Whatever the bytes are kept in, what arrives must
    /// be what was handed over at the time of the send, even when the caller
    /// changes its buffer before the peer has read a byte.
    @Test("bytes sent without a copy arrive as they were when sent")
    func noCopySendsArriveIntact() async throws {
        let sink = Sink()
        let gate = AsyncStream<Void>.makeStream()
        let server = try MockTargetServer { transport in
            // Not reading yet: the send sits in the connection.
            for await _ in gate.stream { break }
            while let chunk = try? await transport.receive() { await sink.append(chunk) }
        }
        let port = try await server.start()
        let client = try await NetworkTransport.connect(host: "127.0.0.1", port: port)
        let size = 4 << 20
        #expect(size > NetworkTransport.noCopyThreshold)

        func pattern(_ seed: UInt8) -> Data {
            Data((0 ..< size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
        }
        // A native buffer, sliced; one bridged from NSData, as a buffer that
        // crossed XPC is; and one that wraps memory it does not own.
        var native = pattern(1)
        let bridged = NSData(data: pattern(2)) as Data
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        pattern(3).copyBytes(to: raw.assumingMemoryBound(to: UInt8.self), count: size)
        let wrapped = Data(bytesNoCopy: raw, count: size, deallocator: .custom { p, _ in p.deallocate() })

        let first = native[100...]
        let second = bridged[7 ..< size - 9]
        let expected = first + second + wrapped
        let sends = Task {
            try await client.send(contentsOf: [first, second])
            try await client.send(wrapped)
        }
        // While the bytes are still queued, the caller reuses its buffer.
        try await Task.sleep(for: .milliseconds(50))
        native.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 0xEE, $0.count) }
        gate.continuation.yield()
        try await sends.value

        let received = await sink.wait(for: expected.count)
        #expect(received.count == expected.count)
        #expect(received == expected, "the bytes on the wire changed after they were sent")
        await client.close()
        await server.stop()
    }

    @Test("a transport without its own multi-part send delivers the parts joined")
    func defaultJoins() async throws {
        let (a, b) = MemoryPipe.pair()
        let tail = Data([9, 9, 3, 4])[2...]
        try await a.send(contentsOf: [Data([1, 2]), tail, Data()])
        #expect(try await b.receive() == Data([1, 2, 3, 4]))
    }
}
#endif
