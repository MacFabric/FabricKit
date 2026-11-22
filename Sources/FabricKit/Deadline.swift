import Foundation

public enum DeadlineError: Error, Equatable, Sendable {
    case timedOut
}

/// Delivers whichever of the racers finishes first, exactly once.
///
/// The loser calls `finish` too, and is ignored. Results that arrive before
/// anyone is waiting are buffered, so the race cannot be lost to scheduling.
private final class DeadlineGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var buffered: Result<T, any Error>?
    private var settled = false

    func finish(_ result: Result<T, any Error>) {
        lock.lock()
        if settled { lock.unlock(); return }
        settled = true
        let waiting = continuation
        continuation = nil
        if waiting == nil { buffered = result }
        lock.unlock()
        waiting?.resume(with: result)
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if let ready = buffered {
                buffered = nil
                lock.unlock()
                c.resume(with: ready)
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}

/// Every pending deadline in the process, on one sleeping task.
///
/// A deadline used to be a task of its own, asleep for the whole timeout and
/// cancelled when the work won, which is every time but the one that matters:
/// a task created and torn down per command to wait for something that does
/// not happen. Here a deadline is an entry in a heap, and one task sleeps
/// until the earliest of them. Scheduling and cancelling are a push and a
/// removal under a lock.
///
/// The sleeper is only replaced when a deadline earlier than the one it is
/// waiting for arrives. With one timeout in steady use that is never: each new
/// deadline is later than those before it, and a sleeper that wakes to find
/// its deadline cancelled just sleeps again until the next.
private final class DeadlineScheduler: @unchecked Sendable {
    static let shared = DeadlineScheduler()

    final class Entry: @unchecked Sendable {
        let due: ContinuousClock.Instant
        let fire: @Sendable () -> Void
        /// Position in the heap, -1 once fired or cancelled. Guarded by the
        /// scheduler's lock.
        fileprivate var index = -1

        init(due: ContinuousClock.Instant, fire: @escaping @Sendable () -> Void) {
            self.due = due
            self.fire = fire
        }
    }

    private let lock = NSLock()
    private var heap: [Entry] = []
    private var sleeper: Task<Void, Never>?
    /// What the current sleeper is waiting for; nil when there is none.
    private var sleeperDue: ContinuousClock.Instant?
    /// Tells a replaced sleeper, when it wakes, that it is no longer the one.
    private var sleeperGeneration: UInt64 = 0

    func schedule(after duration: Duration, fire: @escaping @Sendable () -> Void) -> Entry {
        let entry = Entry(due: ContinuousClock.now.advanced(by: duration), fire: fire)
        lock.lock()
        entry.index = heap.count
        heap.append(entry)
        siftUp(entry.index)
        if sleeperDue.map({ entry.due < $0 }) ?? true {
            startSleeperLocked(until: entry.due)
        }
        lock.unlock()
        return entry
    }

    /// Forget `entry`. Harmless if it already fired or was cancelled.
    func cancel(_ entry: Entry) {
        lock.lock()
        if entry.index >= 0 { removeLocked(at: entry.index) }
        lock.unlock()
    }

    private func startSleeperLocked(until due: ContinuousClock.Instant) {
        sleeper?.cancel()
        sleeperGeneration &+= 1
        let generation = sleeperGeneration
        sleeperDue = due
        sleeper = Task.detached { [self] in
            var wake = due
            while true {
                try? await Task.sleep(until: wake, clock: .continuous)
                guard let next = fireDue(generation: generation) else { return }
                wake = next
            }
        }
    }

    /// Fire everything due, then say when to wake next: nil when this sleeper
    /// has been replaced or nothing is pending, and it should end.
    private func fireDue(generation: UInt64) -> ContinuousClock.Instant? {
        var due: [Entry] = []
        lock.lock()
        guard generation == sleeperGeneration else {
            lock.unlock()
            return nil
        }
        let now = ContinuousClock.now
        while let first = heap.first, first.due <= now {
            removeLocked(at: 0)
            due.append(first)
        }
        let next = heap.first?.due
        sleeperDue = next
        if next == nil { sleeper = nil }
        lock.unlock()
        for entry in due { entry.fire() }
        return next
    }

    // A binary min-heap on `due`, each entry knowing its own position so a
    // cancelled one comes out in O(log n) and is not left to pile up: at
    // twenty thousand commands a second and a 30 s timeout, lazily kept
    // entries would number six hundred thousand.

    private func removeLocked(at index: Int) {
        let removed = heap[index]
        let last = heap.removeLast()
        removed.index = -1
        guard index < heap.count else { return }
        heap[index] = last
        last.index = index
        siftDown(siftUp(index))
    }

    @discardableResult
    private func siftUp(_ start: Int) -> Int {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].due < heap[parent].due else { break }
            swapEntries(child, parent)
            child = parent
        }
        return child
    }

    private func siftDown(_ start: Int) {
        var parent = start
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < heap.count, heap[left].due < heap[smallest].due { smallest = left }
            if right < heap.count, heap[right].due < heap[smallest].due { smallest = right }
            guard smallest != parent else { return }
            swapEntries(parent, smallest)
            parent = smallest
        }
    }

    private func swapEntries(_ a: Int, _ b: Int) {
        heap.swapAt(a, b)
        heap[a].index = a
        heap[b].index = b
    }

    /// Deadlines pending, for tests.
    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return heap.count
    }
}

/// Deadlines pending across the process. For tests: a deadline whose work
/// finished must not stay behind.
var pendingDeadlineCount: Int { DeadlineScheduler.shared.pendingCount }

/// Run `operation` with an optional deadline. On timeout the operation task is
/// cancelled and `DeadlineError.timedOut` is thrown.
///
/// **The deadline holds even if `operation` ignores cancellation** — that is
/// the point. A task-group race cannot deliver it: the group waits for every
/// child, and a task suspended on a plain continuation never observes
/// `cancelAll()`, so the deadline fires and changes nothing (a Backend A
/// volume once hung for eight hours behind exactly this). So the racers are
/// unstructured tasks and the winner is delivered through a gate. The cost —
/// deliberate — is that a genuinely uncancellable loser leaks a suspended
/// task, which is a few kilobytes, versus a machine that needs a reboot.
public func withDeadline<T: Sendable>(
    _ duration: Duration?,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard let duration else { return try await operation() }

    let gate = DeadlineGate<T>()

    let work = Task {
        do { gate.finish(.success(try await operation())) }
        catch { gate.finish(.failure(error)) }
    }
    let scheduler = DeadlineScheduler.shared
    let timer = scheduler.schedule(after: duration) {
        gate.finish(.failure(DeadlineError.timedOut))
    }
    defer { work.cancel(); scheduler.cancel(timer) }

    // The caller being cancelled has to reach the operation too, or a cancelled
    // read would leave its SCSI task outstanding at the target.
    return try await withTaskCancellationHandler {
        try await gate.value()
    } onCancel: {
        work.cancel()
        scheduler.cancel(timer)
        gate.finish(.failure(CancellationError()))
    }
}

/// `withDeadline` for a step that only a closed connection can stop: a login,
/// or an NVMe/TCP queue's bring-up, parked on a socket read. Cancellation does
/// not reach that read, so on timeout `abandon` runs — it closes the
/// connection, which is what ends the read and lets the abandoned operation
/// unwind instead of holding a socket open for as long as the peer likes.
/// Throws `DeadlineError.timedOut` once `abandon` has finished.
public func withDeadline<T: Sendable>(
    _ duration: Duration?,
    onTimeout abandon: @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await withDeadline(duration, operation: operation)
    } catch let error as DeadlineError {
        await abandon()
        throw error
    }
}
