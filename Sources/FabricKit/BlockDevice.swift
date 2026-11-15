import Foundation

/// A linear, byte-addressable block device: an iSCSI LUN (iSCSIKit's
/// `ISCSIBlockDevice`) or an NVMe namespace (NVMeKit's `NVMeBlockDevice`).
/// Implementations translate byte offsets to LBAs and split large transfers to
/// respect the target's limits, so a consumer sees one surface for both.
public protocol BlockDeviceBackend: Sendable {
    var blockSize: Int { get async }
    var blockCount: UInt64 { get async }
    /// Read `length` bytes at `offset` (both must be block-aligned).
    func read(offset: UInt64, length: Int) async throws -> Data
    /// Write `data` at `offset` (block-aligned, whole blocks).
    func write(offset: UInt64, data: Data) async throws
    /// Flush the device cache (SCSI SYNCHRONIZE CACHE, NVMe Flush).
    func flush() async throws
    /// Geometry, fetched on first use and cached; `blockSize`/`blockCount`
    /// are the non-throwing view of the same answer.
    func readCapacity() async throws -> (blockSize: Int, blockCount: UInt64)
    /// Whether the device has a volatile write cache (SCSI WCE, NVMe VWC),
    /// so FUA and flushes decide durability. nil when the device did not say.
    func writeCacheEnabled() async throws -> Bool?
}

public enum BlockDeviceError: Error, Equatable, Sendable {
    case notReady
    case misaligned(offset: UInt64, length: Int, blockSize: Int)
    case outOfRange(lba: UInt64, blocks: UInt32, capacity: UInt64)
    case scsiError(status: UInt8, sense: SenseData?)
    /// READ CAPACITY described a device that cannot exist; nothing the
    /// initiator does will make this target usable.
    case invalidGeometry(blockSize: Int, blockCount: UInt64, reason: String)
    /// An NVMe controller completed a command with a non-success status:
    /// Status Code Type, Status Code, and the opcode it answered. Lives in
    /// this enum, not NVMeKit, so code that classifies errors from both
    /// protocols sees one enum.
    case nvmeStatus(sct: UInt8, sc: UInt8, opcode: UInt8)
}

/// Bounds checks shared by both block devices, done in 64-bit arithmetic: a
/// block count is narrowed to a CDB's 32 bits only per chunk, after the
/// request has been split, so an oversized length is an error and never a
/// trap in a root daemon.
public enum BlockRequest {
    public static func validate(offset: UInt64, length: Int, blockSize: Int,
                                capacity: UInt64) throws {
        guard blockSize > 0,
              length >= 0,
              offset % UInt64(blockSize) == 0,
              length % blockSize == 0
        else {
            throw BlockDeviceError.misaligned(offset: offset, length: length, blockSize: blockSize)
        }
        let lba = offset / UInt64(blockSize)
        let blocks = UInt64(length / blockSize)
        let (end, overflow) = lba.addingReportingOverflow(blocks)
        guard !overflow, end <= capacity else {
            throw BlockDeviceError.outOfRange(lba: lba, blocks: UInt32(clamping: blocks),
                                              capacity: capacity)
        }
    }
}
