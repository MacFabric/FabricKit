import FabricKit
import Foundation

/// Session policy tuned for fast tests: no Time2Wait, short backoff, and a
/// keepalive only when a test asks for one.
public func testPolicy(
    retries: Int = 2,
    recoveryAttempts: Int = 4,
    nopInterval: Duration? = nil
) -> SessionPolicy {
    var policy = SessionPolicy()
    policy.honorTime2Wait = false // scripted targets reconnect immediately
    policy.nopInterval = nopInterval
    policy.nopTimeout = .milliseconds(250)
    policy.maxRecoveryAttempts = recoveryAttempts
    policy.recoveryBackoffBase = .milliseconds(10)
    policy.recoveryBackoffCap = .milliseconds(50)
    policy.taskRetries = retries
    return policy
}

/// Poll `condition` until it holds or `timeout` passes; the peer's counters
/// move after the initiator's error surfaces, so a test asserts on them
/// this way rather than by sleeping.
public func eventually(timeout: Duration = .seconds(2), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Holds the first connect until the test opens it; later ones pass.
public actor ConnectGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public var isHeld: Bool { !waiters.isEmpty }

    public init() {}

    public func pass() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
