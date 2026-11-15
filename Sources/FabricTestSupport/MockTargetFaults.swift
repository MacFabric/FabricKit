import Foundation

/// Scripted misbehavior. Every fault is off by default; tests switch on the
/// hostility they want to probe.
public struct MockTargetFaults: Sendable {
    /// Fail login with this status class/detail.
    public var rejectLoginStatus: (class: UInt8, detail: UInt8)?
    /// Answer login with a redirect (status class 1) to this address.
    public var redirectTo: String?
    /// Send that redirect as "moved temporarily" (0x0101), the way an
    /// EqualLogic group address hands every login to a member port, rather
    /// than "moved permanently" (0x0102).
    public var redirectIsTemporary = false
    /// Hard-drop the connection after N PDUs sent (post-login).
    public var dropAfterSentPDUs: Int?
    /// Drop mid-read after N Data-In PDUs of a burst.
    public var dropDuringDataInAt: Int?
    /// Flip a byte in the data segment of Data-In PDUs (digest must catch it
    /// when DataDigest=CRC32C, otherwise it silently corrupts).
    public var corruptDataInPayload = false
    /// Flip a byte inside the BHS after the header digest is computed.
    public var corruptHeaderDigestOnce = false
    /// Skip this many StatSN values after login (lost-status simulation).
    public var statSNJump: UInt32 = 0
    /// Repeat the previous StatSN on the next status PDU.
    public var duplicateStatSN = false
    /// Send an R2T for a *read* task (protocol violation).
    public var unsolicitedR2T = false
    /// Ignore the initiator's declared MaxRecvDataSegmentLength on Data-In.
    public var oversizeDataIn = false
    /// Issue the R2T for writes, then never accept the data / respond.
    public var stallAfterR2T = false
    /// Accept commands and never respond at all.
    public var stallCommands = false
    /// Respond to every command with a Reject PDU.
    public var rejectAllCommands = false
    /// Respond to every command with CHECK CONDITION.
    public var checkConditionAll = false
    /// Delay before each response PDU.
    public var responseDelay: Duration?
    /// NVMe/TCP only: I/O commands that arrive before this instant are held
    /// until it, and then handled, while the admin queue (keep-alives
    /// included) answers as usual. A loaded NAS committing a 30 s flush with
    /// writes queued behind it, which still answers keep-alives (2026-11-09):
    /// `responseDelay` and `stallCommands` hold the keep-alive too, so the
    /// initiator drops the connection on that instead of on the task timeout.
    public var holdIOUntil: ContinuousClock.Instant?
    /// Send a target-initiated NOP-In ping right after login.
    public var nopPingOnConnect = false
    /// Ignore initiator NOP-Out pings (dead-peer simulation while the TCP
    /// connection stays up).
    public var swallowNops = false
    /// Ignore task management requests. A target this sick is the reason an
    /// abort cannot be a precondition for giving up on a task.
    public var swallowTMF = false
    /// Ignore logout requests, keeping the connection open: the target that
    /// makes an unbounded logout an unmount that never finishes.
    public var swallowLogout = false
    /// Freeze MaxCmdSN at login value (command window never reopens).
    public var freezeWindow = false
    /// Split text responses into C-bit continuations of this size.
    public var splitTextResponsesAt: Int?

    public init() {}
}
