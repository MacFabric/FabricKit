import Testing
import Foundation
@testable import FabricKit

/// `withDeadline` is the last line of defence between a stuck target and a
/// wedged Mac: the daemon's XPC reply, the FSKit extension's read, DiskImages
/// and APFS are all waiting on it to give up on time.
@Suite("withDeadline") struct DeadlineTests {

    /// A box that is safe to read from the test while a task writes it.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func returnsAResultBeforeTheDeadline() async throws {
        let value = try await withDeadline(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func nilDurationMeansNoDeadline() async throws {
        let value = try await withDeadline(nil) { 7 }
        #expect(value == 7)
    }

    @Test func timesOutOnAnOperationThatIsMerelySlow() async throws {
        await #expect(throws: DeadlineError.timedOut) {
            try await withDeadline(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// The one that matters: the deadline must hold for uncancellable work.
    /// A task-group race cannot deliver that — the group waits for every
    /// child, and `cancelAll()` only sets a flag a bare continuation never
    /// observes. Written with detached work so a regression fails the test
    /// instead of hanging the suite.
    @Test func timesOutEvenWhenTheOperationIgnoresCancellation() async throws {
        let returned = Flag()

        let work = Task {
            _ = try? await withDeadline(.milliseconds(100)) {
                // Never resumed, and no cancellation handler, so cancelling the
                // task that runs this does nothing at all.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
            returned.set()
        }

        // 20× the deadline: slow machines pass, a hang is obvious.
        try await Task.sleep(for: .seconds(2))
        work.cancel()

        #expect(returned.isSet,
                "withDeadline did not return 2s after a 100ms deadline: it is stuck waiting on an operation that ignores cancellation, which is the case a deadline exists to survive")
    }

    /// Same shape, one layer further out: the error has to be the deadline's,
    /// not something the stuck operation invented, or callers cannot tell
    /// "target is slow" from "target returned an error".
    @Test func reportsTimedOutRatherThanSomeOtherFailure() async throws {
        let caught = ErrorBox()

        let work = Task {
            do {
                try await withDeadline(.milliseconds(100)) {
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                }
            } catch {
                caught.store(error)
            }
        }

        try await Task.sleep(for: .seconds(2))
        work.cancel()

        #expect(caught.value is DeadlineError,
                "expected DeadlineError.timedOut; a caller cannot tell a slow target from a failing one otherwise")
    }

    /// Written by a task, read by the test.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (any Error)?
        func store(_ error: any Error) { lock.lock(); stored = error; lock.unlock() }
        var value: (any Error)? { lock.lock(); defer { lock.unlock() }; return stored }
    }
}

/// Deadlines share one sleeping task. What that must not change: each one
/// fires at its own time whatever order they were set in, and one whose work
/// finished leaves nothing behind.
@Suite("Deadlines on the shared scheduler", .serialized)
struct DeadlineSchedulerTests {
    private func settle(_ what: String, _ condition: () -> Bool) async {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < limit {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("never happened: \(what)")
    }

    @Test func aFinishedOperationLeavesNoDeadlineBehind() async throws {
        await settle("earlier tests' deadlines cleared") { pendingDeadlineCount == 0 }
        for i in 0 ..< 500 {
            #expect(try await withDeadline(.seconds(60)) { i } == i)
        }
        await settle("no deadline left behind") { pendingDeadlineCount == 0 }
        try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0 ..< 64 {
                group.addTask { try await withDeadline(.seconds(60)) { try await Task.sleep(for: .milliseconds(5)); return i } }
            }
            var sum = 0
            for try await value in group { sum += value }
            #expect(sum == (0 ..< 64).reduce(0, +))
        }
        await settle("no deadline left behind") { pendingDeadlineCount == 0 }
    }

    @Test func aCancelledCallerLeavesNoDeadlineBehind() async throws {
        await settle("earlier tests' deadlines cleared") { pendingDeadlineCount == 0 }
        let task = Task {
            try await withDeadline(.seconds(60)) { try await Task.sleep(for: .seconds(60)) }
        }
        await settle("the deadline was set") { pendingDeadlineCount == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await settle("no deadline left behind") { pendingDeadlineCount == 0 }
    }

    /// A short deadline set while the sleeper waits for a long one must not
    /// wait behind it.
    @Test func aShorterDeadlineSetLaterStillFiresFirst() async throws {
        let long = Task {
            try await withDeadline(.seconds(60)) { try await Task.sleep(for: .seconds(60)) }
        }
        await settle("the long deadline was set") { pendingDeadlineCount >= 1 }
        let started = ContinuousClock.now
        await #expect(throws: DeadlineError.timedOut) {
            try await withDeadline(.milliseconds(50)) { try await Task.sleep(for: .seconds(60)) }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        long.cancel()
        _ = try? await long.value
    }

    /// Set in no particular order, each fires at its own time: all of the
    /// short ones, none of the long ones.
    @Test func deadlinesSetInAnyOrderEachFireAtTheirOwnTime() async throws {
        let outcomes = try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
            let milliseconds = [900_000, 40, 700_000, 10, 120, 800_000, 5, 80, 600_000, 20]
            for (index, ms) in milliseconds.enumerated() {
                group.addTask {
                    do {
                        try await withDeadline(.milliseconds(ms)) { try await Task.sleep(for: .seconds(2)) }
                        return (index, false)
                    } catch is DeadlineError {
                        return (index, true)
                    }
                }
            }
            var fired = [Bool](repeating: false, count: milliseconds.count)
            for try await (index, timedOut) in group { fired[index] = timedOut }
            return zip(milliseconds, fired).map { ($0, $1) }
        }
        for (ms, timedOut) in outcomes {
            #expect(timedOut == (ms < 1000), "\(ms) ms")
        }
    }

    /// A zero or negative timeout has already passed.
    @Test func aDeadlineAlreadyPastFiresAtOnce() async {
        for duration: Duration in [.zero, .milliseconds(-5)] {
            await #expect(throws: DeadlineError.timedOut) {
                try await withDeadline(duration) { try await Task.sleep(for: .seconds(60)) }
            }
        }
    }
}
