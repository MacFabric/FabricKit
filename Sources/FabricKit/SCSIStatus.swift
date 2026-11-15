import Foundation

/// Completion of a SCSI task.
public struct SCSITaskResult: Sendable, Equatable {
    /// SAM status byte: 0x00 GOOD, 0x02 CHECK CONDITION, 0x08 BUSY, 0x28 TASK
    /// SET FULL, ...
    public var status: UInt8
    /// Data-In payload (reads).
    public var data: Data
    /// Sense bytes when status is CHECK CONDITION.
    public var sense: Data?
    public var residualCount: UInt32
    public var residualIsOverflow: Bool

    public var isGood: Bool { status == 0x00 }

    public init(
        status: UInt8,
        data: Data = Data(),
        sense: Data? = nil,
        residualCount: UInt32 = 0,
        residualIsOverflow: Bool = false
    ) {
        self.status = status
        self.data = data
        self.sense = sense
        self.residualCount = residualCount
        self.residualIsOverflow = residualIsOverflow
    }
}

/// Sense data essentials, fixed (SPC-4 §4.5.3) or descriptor (§4.5.2) format.
public struct SenseData: Sendable, Equatable {
    public var key: UInt8
    public var asc: UInt8
    public var ascq: UInt8

    public init?(_ bytes: Data) {
        guard !bytes.isEmpty else { return nil }
        switch bytes.u8(0) & 0x7F {
        case 0x70, 0x71: // fixed format
            guard bytes.count >= 14 else { return nil }
            key = bytes.u8(2) & 0x0F
            asc = bytes.u8(12)
            ascq = bytes.u8(13)
        case 0x72, 0x73: // descriptor format: key/ASC/ASCQ in the header
            guard bytes.count >= 4 else { return nil }
            key = bytes.u8(1) & 0x0F
            asc = bytes.u8(2)
            ascq = bytes.u8(3)
        default:
            return nil
        }
    }

    public var description: String {
        String(format: "sense key 0x%02x asc 0x%02x ascq 0x%02x", key, asc, ascq)
    }
}
