//! 送信統計（ベンチ共通）。完了コールバックは CoreMIDI のスレッドから
//! 呼ばれるためロックで守る。

import Foundation

final class Stats: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    private var completed = 0
    private var maxOutstanding = 0
    private var latencySumMs = 0.0
    private var latencyMaxMs = 0.0

    /// 送信を記録し、現在の滞留数を返す
    func onSend() -> Int {
        lock.lock(); defer { lock.unlock() }
        sent += 1
        let outstanding = sent - completed
        maxOutstanding = max(maxOutstanding, outstanding)
        return outstanding
    }

    func onComplete(latencyMs: Double) {
        lock.lock(); defer { lock.unlock() }
        completed += 1
        latencySumMs += latencyMs
        latencyMaxMs = max(latencyMaxMs, latencyMs)
    }

    var outstandingNow: Int {
        lock.lock(); defer { lock.unlock() }
        return sent - completed
    }

    func snapshotAndReset() -> (sent: Int, completed: Int, maxOutstanding: Int, avgMs: Double, maxMs: Double) {
        lock.lock(); defer { lock.unlock() }
        let snap = (
            sent, completed, maxOutstanding,
            completed > 0 ? latencySumMs / Double(completed) : 0.0,
            latencyMaxMs
        )
        sent = 0; completed = 0; maxOutstanding = 0
        latencySumMs = 0; latencyMaxMs = 0
        return snap
    }
}
