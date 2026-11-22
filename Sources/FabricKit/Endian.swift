import Foundation

/// Big-endian, slice-tolerant accessors over `Data`. All offsets are relative
/// to `startIndex`, so these work uniformly on slices returned by the framer.
extension Data {

    /// Trap, as a subscript would, before a raw load or store can touch
    /// bytes outside this buffer: the unsafe accessors below check their
    /// offsets only in debug builds, and these fields come off the network.
    @inline(__always)
    private func checkRange(_ offset: Int, _ width: Int) {
        precondition(offset >= 0 && width <= count && offset <= count - width,
                     "field outside the buffer")
    }

    /// One load of the whole field. Reading it a byte at a time through the
    /// subscript cost four bounds checks and four accesses for a 32-bit
    /// field; a PDU header is a dozen of them.
    @inline(__always)
    private func load<T: FixedWidthInteger>(_ offset: Int, as type: T.Type) -> T {
        checkRange(offset, MemoryLayout<T>.size)
        return withUnsafeBytes { T(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }

    @inline(__always)
    private mutating func store<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
        checkRange(offset, MemoryLayout<T>.size)
        withUnsafeMutableBytes { $0.storeBytes(of: value.bigEndian, toByteOffset: offset, as: T.self) }
    }

    public func u8(_ offset: Int) -> UInt8 {
        self[startIndex + offset]
    }


    public func beU16(_ offset: Int) -> UInt16 {
        load(offset, as: UInt16.self)
    }

    /// 24-bit big-endian field (used by DataSegmentLength).

    public func beU24(_ offset: Int) -> UInt32 {
        UInt32(u8(offset)) << 16 | UInt32(u8(offset + 1)) << 8 | UInt32(u8(offset + 2))
    }


    public func beU32(_ offset: Int) -> UInt32 {
        load(offset, as: UInt32.self)
    }


    public func beU64(_ offset: Int) -> UInt64 {
        load(offset, as: UInt64.self)
    }


    public func sub(_ offset: Int, _ count: Int) -> Data {
        self[startIndex + offset ..< startIndex + offset + count]
    }


    public mutating func setU8(_ v: UInt8, _ offset: Int) {
        self[startIndex + offset] = v
    }


    public mutating func setBE16(_ v: UInt16, _ offset: Int) {
        store(v, offset)
    }


    public mutating func setBE24(_ v: UInt32, _ offset: Int) {
        precondition(v <= 0xFF_FFFF)
        setU8(UInt8((v >> 16) & 0xFF), offset)
        setU8(UInt8((v >> 8) & 0xFF), offset + 1)
        setU8(UInt8(v & 0xFF), offset + 2)
    }


    public mutating func setBE32(_ v: UInt32, _ offset: Int) {
        store(v, offset)
    }


    public mutating func setBE64(_ v: UInt64, _ offset: Int) {
        store(v, offset)
    }


    public mutating func setSub(_ bytes: Data, _ offset: Int) {
        replaceSubrange(startIndex + offset ..< startIndex + offset + bytes.count, with: bytes)
    }
}

/// Round `n` up to the next multiple of 4 (iSCSI PDU segments are 4-byte padded).

public func padded4(_ n: Int) -> Int {
    (n + 3) & ~3
}
