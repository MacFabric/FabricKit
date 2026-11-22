import Foundation

/// Bytes received and not yet consumed, held as the chunks they arrived in.
///
/// A deframer that appends every chunk to one growing buffer copies each
/// byte once just to queue it, and again to hand it on. Here a chunk is kept
/// as it came from the transport and bytes are copied once, to wherever they
/// are going: a small buffer for a header, or straight into the buffer of
/// the read they answer. A chunk is released when its last byte is consumed,
/// so nothing has to be compacted.
public struct ReceiveQueue: Sendable {
    private var chunks: [Data] = []
    /// Index of the first chunk with unconsumed bytes.
    private var head = 0
    /// Bytes of `chunks[head]` already consumed.
    private var offset = 0
    /// Unconsumed bytes.
    public private(set) var count = 0

    public init() {}

    public var isEmpty: Bool { count == 0 }

    public mutating func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        if head == chunks.count {
            chunks.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 32 {
            // Consumed chunks are already emptied; this only gives their
            // slots back, and rarely.
            chunks.removeFirst(head)
            head = 0
        }
        chunks.append(chunk)
        count += chunk.count
    }

    /// A copy of `length` bytes starting `skip` bytes in. Nothing is
    /// consumed. The range must be buffered.
    public func peek(_ length: Int, skippingFirst skip: Int = 0) -> Data {
        precondition(length >= 0 && skip >= 0 && skip <= count - length, "peek beyond what is buffered")
        guard length > 0 else { return Data() }
        var out = Data(count: length)
        out.withUnsafeMutableBytes { copy(into: $0, skippingFirst: skip) }
        return out
    }

    /// One byte, `index` bytes in, without consuming it.
    public func byte(at index: Int) -> UInt8 {
        precondition(index >= 0 && index < count, "byte beyond what is buffered")
        var at = head
        var skip = index + offset
        while skip >= chunks[at].count {
            skip -= chunks[at].count
            at += 1
        }
        return chunks[at][chunks[at].startIndex + skip]
    }

    /// Consume `length` bytes without looking at them.
    public mutating func skip(_ length: Int) {
        precondition(length >= 0 && length <= count, "skip beyond what is buffered")
        var left = length
        while left > 0 {
            let available = chunks[head].count - offset
            if left < available {
                offset += left
                left = 0
            } else {
                left -= available
                release()
            }
        }
        count -= length
    }

    /// Consume `length` bytes and return a copy of them. They must be buffered.
    public mutating func read(_ length: Int) -> Data {
        let out = peek(length)
        skip(length)
        return out
    }

    /// Move bytes into `destination`: as many as it holds, or as many as are
    /// buffered if that is fewer. Returns how many, all of them consumed.
    @discardableResult
    public mutating func read(into destination: UnsafeMutableRawBufferPointer) -> Int {
        let length = min(destination.count, count)
        guard length > 0 else { return 0 }
        copy(into: UnsafeMutableRawBufferPointer(rebasing: destination[0 ..< length]), skippingFirst: 0)
        skip(length)
        return length
    }

    /// Fill `destination` from the bytes `skip` in; they must all be buffered.
    private func copy(into destination: UnsafeMutableRawBufferPointer, skippingFirst skip: Int) {
        var at = head
        var from = offset + skip
        while from >= chunks[at].count {
            from -= chunks[at].count
            at += 1
        }
        var written = 0
        while written < destination.count {
            let chunk = chunks[at]
            let take = min(chunk.count - from, destination.count - written)
            chunk.withUnsafeBytes { source in
                destination.baseAddress!.advanced(by: written)
                    .copyMemory(from: source.baseAddress!.advanced(by: from), byteCount: take)
            }
            written += take
            from = 0
            at += 1
        }
    }

    /// Drop the head chunk, all of whose bytes are consumed.
    private mutating func release() {
        chunks[head] = Data()
        head += 1
        offset = 0
    }
}
