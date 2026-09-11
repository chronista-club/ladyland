//! VALUE エンコーダーの連打 → トラック移動の歩数化（design/06 §8 追補）。
//!
//! Keystage の丸い VALUE エンコーダーは回転中 `BF 3E/3F 7F` を連打で送る
//! （docs/keystage §6）。1 パルス = 1 移動にすると 8 スロットを一瞬で
//! 飛び越えてしまうため、最小間隔を空けて「歩数」に落とす。純関数（テスト対象）。

struct TrackNavThrottle {
    /// 1 歩の最小間隔（150ms — 回し続けると秒 6〜7 歩。手応えと追従の折衷）
    var minIntervalNs: UInt64
    private var lastStepNs: UInt64 = 0

    init(minIntervalNs: UInt64 = 150_000_000) {
        self.minIntervalNs = minIntervalNs
    }

    /// このパルスで 1 歩進んで良いか（進むなら時刻を消費する）
    mutating func shouldStep(nowNs: UInt64) -> Bool {
        guard nowNs &- lastStepNs >= minIntervalNs else { return false }
        lastStepNs = nowNs
        return true
    }
}
