import Foundation

/// Things worth telling someone about, which are not errors the caller sees.
/// Recovery is invisible to callers by design; it must not be invisible to
/// operators too.
public enum SessionEvent: Sendable {
    /// The connection dropped; recovery is starting.
    case connectionLost(reason: String)
    case recoveryAttempt(number: Int, of: Int)
    /// Back in business, having rebuilt the session this many times in total.
    case recovered(totalRecoveries: Int)
    /// Gave up. Every subsequent I/O on this session will fail.
    case recoveryExhausted(lastError: String)
}

public enum SessionError: Error, Equatable, Sendable {
    case notActive
    case loggedOut
    case recoveryExhausted(lastError: String)
    case taskFailed(SCSITaskResult)
    case taskTimedOut
}

/// Session-level policy knobs; test suites shrink the timings.
public struct SessionPolicy: Sendable {
    /// NOP keepalive cadence; nil disables the keepalive task.
    public var nopInterval: Duration? = .seconds(10)
    /// A ping unanswered for this long declares the connection dead.
    public var nopTimeout: Duration = .seconds(10)
    /// Re-login attempts after a connection drop (ERL0 session recovery).
    public var maxRecoveryAttempts = 5
    /// Backoff between recovery attempts (doubles per attempt, capped).
    public var recoveryBackoffBase: Duration = .milliseconds(500)
    public var recoveryBackoffCap: Duration = .seconds(30)
    /// Automatic transparent retries of a task interrupted by a connection
    /// drop. Block-layer reads/writes are idempotent, so retry is safe.
    public var taskRetries = 2
    /// A task unanswered for this long is abandoned: aborted at the target,
    /// then retried on a fresh session (bounded by `taskRetries`). nil waits
    /// forever. The keepalive does not cover this — a target that swallows
    /// commands usually still answers NOPs. 30s is the conventional SCSI
    /// command timeout.
    public var taskTimeout: Duration? = .seconds(30)
    /// How long a target that accepted the connection gets to finish logging
    /// in: the iSCSI login exchange, or an NVMe/TCP queue's ICReq and Fabrics
    /// Connect. The TCP connect has its own deadline (`NetworkTransport`);
    /// this one starts after it. nil waits forever, which is what every login
    /// did before 2026-11 — and since `taskTimeout` only covers I/O on an
    /// established connection, a target that accepted TCP and then went
    /// quiet hung the attach, and every recovery attempt behind it, with
    /// nothing to give up on. 15 s is open-iscsi's default login timeout.
    public var loginTimeout: Duration? = .seconds(15)
    /// How long a logout waits for the target's response before closing the
    /// connection anyway — the TMF path's five seconds. Bounded because the
    /// extension logs out on unmount, so an unanswered logout is an unmount
    /// that never finishes.
    public var logoutTimeout: Duration = .seconds(5)
    /// RFC 7143 §7.5: after a transport exception, recovery SHOULD NOT begin
    /// before the negotiated DefaultTime2Wait. Tests that script fast
    /// reconnects turn this off.
    public var honorTime2Wait = true

    public init() {}
}
