import Foundation

/// 遅延処理の世代と実行中の処理を分ける。古い予約は捨て、開始済みだけを待つ。
final class MIDIWorkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var enabled = false
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var stamp: UInt64? { lock.withLock { enabled ? generation : nil } }
    var isIdle: Bool { lock.withLock { active == 0 } }
    @discardableResult
    func activate() -> Bool {
        lock.withLock {
            guard active == 0 else { return false }
            generation &+= 1
            enabled = true
            return true
        }
    }
    func revoke() { lock.withLock { enabled = false; generation &+= 1 } }
    func begin(_ stamp: UInt64) -> Work? {
        lock.withLock {
            guard enabled, generation == stamp else { return nil }
            active += 1
            return Work(gate: self, stamp: stamp)
        }
    }
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if active == 0 { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    private func current(_ stamp: UInt64) -> Bool { lock.withLock { enabled && generation == stamp } }
    private func finish() {
        lock.lock()
        active -= 1
        let ready = active == 0 ? waiters : []
        if active == 0 { waiters.removeAll() }
        lock.unlock()
        for waiter in ready { waiter.resume() }
    }
    final class Work: @unchecked Sendable {
        private let gate: MIDIWorkGate
        private let stamp: UInt64
        private let lock = NSLock()
        private var finished = false
        fileprivate init(gate: MIDIWorkGate, stamp: UInt64) { self.gate = gate; self.stamp = stamp }
        var isCurrent: Bool { lock.withLock { !finished && gate.current(stamp) } }
        func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            gate.finish()
        }
        deinit { finish() }
    }
}
