import Foundation

/// The memory a read's data is received into.
///
/// One allocation for the whole read, filled in place by whoever receives
/// its bytes and then handed to the caller as `Data` without a copy. A read
/// split into several commands gives each of them a region of the same
/// buffer, so the pieces are never joined afterwards either.
///
/// Not zeroed when made: a megabyte cleared and then overwritten is a
/// megabyte written twice. Whoever completes a read must `zero` any part of
/// its region that was not received before the bytes can be seen.
///
/// A reference type on purpose. A command that was given up on (a deadline,
/// a cancellation) may still have a byte or two on its way in, and whoever
/// writes them holds this object, so they land in memory that still exists.
/// `@unchecked Sendable`: writers are handed disjoint regions, and the
/// engines never write to a region whose `Data` has been handed out.
public final class ReadBuffer: @unchecked Sendable {
    public let count: Int
    private let base: UnsafeMutableRawPointer

    public init(count: Int) {
        precondition(count >= 0)
        self.count = count
        // One byte at least, so there is always an address to hand out.
        base = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 16)
    }

    deinit { base.deallocate() }

    /// Part of a buffer: where one command's data goes.
    public struct Region: Sendable {
        public let buffer: ReadBuffer
        public let offset: Int
        public let count: Int

        public init(buffer: ReadBuffer, offset: Int, count: Int) {
            precondition(offset >= 0 && count >= 0 && offset <= buffer.count - count,
                         "region outside its buffer")
            self.buffer = buffer
            self.offset = offset
            self.count = count
        }
    }

    /// The whole buffer as a region.
    public var whole: Region { Region(buffer: self, offset: 0, count: count) }

    /// `range` as memory to write into.
    public func bytes(_ range: Range<Int>) -> UnsafeMutableRawBufferPointer {
        precondition(range.lowerBound >= 0 && range.upperBound <= count, "range outside the buffer")
        return UnsafeMutableRawBufferPointer(start: base + range.lowerBound, count: range.count)
    }

    public func zero(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        bytes(range).initializeMemory(as: UInt8.self, repeating: 0)
    }

    /// Copy `source` in at `offset`.
    public func write(_ source: Data, at offset: Int) {
        guard !source.isEmpty else { return }
        let destination = bytes(offset ..< offset + source.count)
        source.withUnsafeBytes { destination.copyMemory(from: $0) }
    }

    /// `range` as `Data` that shares this memory and keeps it alive. Every
    /// byte of it must have been written or zeroed, and nothing may write to
    /// it afterwards.
    public func data(_ range: Range<Int>) -> Data {
        precondition(range.lowerBound >= 0 && range.upperBound <= count, "range outside the buffer")
        guard !range.isEmpty else { return Data() }
        return Data(bytesNoCopy: base + range.lowerBound, count: range.count,
                    deallocator: .custom { [self] _, _ in withExtendedLifetime(self) {} })
    }

    /// The whole buffer as `Data`; see `data(_:)`.
    public func data() -> Data { data(0 ..< count) }
}

extension ReadBuffer.Region {
    /// `range` of this region, counted from its start, as memory to write into.
    public func bytes(_ range: Range<Int>) -> UnsafeMutableRawBufferPointer {
        precondition(range.lowerBound >= 0 && range.upperBound <= count, "range outside the region")
        return buffer.bytes(offset + range.lowerBound ..< offset + range.upperBound)
    }

    public func zero(_ range: Range<Int>) {
        precondition(range.lowerBound >= 0 && range.upperBound <= count, "range outside the region")
        buffer.zero(offset + range.lowerBound ..< offset + range.upperBound)
    }

    public func write(_ source: Data, at position: Int) {
        precondition(position >= 0 && position <= count - source.count, "write outside the region")
        buffer.write(source, at: offset + position)
    }

    /// The first `length` bytes of this region as `Data`; see `ReadBuffer.data(_:)`.
    public func data(prefix length: Int) -> Data {
        precondition(length >= 0 && length <= count)
        return buffer.data(offset ..< offset + length)
    }
}
