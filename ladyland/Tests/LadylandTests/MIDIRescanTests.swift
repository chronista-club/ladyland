import Testing

@testable import Ladyland

/// 起動レースの再列挙ポリシー（`MIDIRescan`）。
///
/// ⚠️ **有限であることが本体** — 実機が本当に居ない起動（スタジオ外）で
/// 引き直し続けない。挿されたときは `msgSetupChanged` が来る（実証 2026-08-09）
/// ので、打ち止めても取り逃さない
@Suite("MIDI 再列挙ポリシー")
struct MIDIRescanTests {
    @Test("待ちは伸びていき、必ず打ち止めになる")
    func delaysGrowThenStop() {
        var previous = 0.0
        for attempt in 0..<MIDIRescan.delays.count {
            let delay = MIDIRescan.delay(afterAttempt: attempt)
            #expect(delay != nil, "予算内は引き直す")
            #expect(delay! > previous, "待ちは単調に伸びる（連打で機材を叩かない）")
            previous = delay!
        }
        #expect(
            MIDIRescan.delay(afterAttempt: MIDIRescan.delays.count) == nil,
            "予算を使い切ったら打ち止め — 以後は挿抜通知に任せる")
        #expect(MIDIRescan.delay(afterAttempt: 99) == nil)
        #expect(MIDIRescan.delay(afterAttempt: -1) == nil, "負の試行回数は材料外")
    }

    @Test("初回の引き直しは数秒以内 — 起動レースの窓は短い")
    func firstRetryIsQuick() {
        // 実測 2026-08-09: アプリ再起動で普通に見えた = レースの窓は起動直後の
        // 数秒。初回が遅いと「繋がっているのに数十秒無反応」に見える
        #expect(MIDIRescan.delay(afterAttempt: 0)! <= 5)
    }
}
