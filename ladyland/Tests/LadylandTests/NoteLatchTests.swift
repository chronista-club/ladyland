//! ノートのキープ（ダンパーペダル CC64）のテスト。
//!
//! mako 裁定 2026-08-02「ペダルを踏んだら、Keystage の演奏中の
//! キーボードをキープする。そうすれば音を途切れさせずにつまみがいじれる」。
//! 実機確認: EXPRESSION ジャックは MIDI を出さず、DAMPER ジャック (CC64) が出た。
//!
//! ここを外すと**音が止まらない / 勝手に止まる**という、ライブで最悪の
//! 壊れ方をする。サスティンペダルと同じ意味論をピン留めする。

import Testing

@testable import Ladyland

@Suite("ノートのキープ（ダンパー CC64）")
struct NoteLatchTests {
    @Test("踏んでいない間は素通し — Note Off はそのまま送る")
    func passThroughWhenReleased() {
        var latch = NoteLatch()
        latch.noteOn(60, channel: 0)
        let sends = latch.shouldSendNoteOff(60)
        #expect(sends, "踏んでいなければ普通に消える")
        #expect(latch.sustainedCount == 0)
    }

    @Test("踏んでいる間は鍵を離しても消さない（両手が空く）")
    func holdsWhileEngaged() {
        var latch = NoteLatch()
        latch.noteOn(60, channel: 0)
        latch.noteOn(64, channel: 0)
        _ = latch.pedal(100)  // 踏む
        #expect(latch.isEngaged)

        let held60 = latch.shouldSendNoteOff(60)
        let held64 = latch.shouldSendNoteOff(64)
        #expect(!held60, "Note Off を握りつぶす")
        #expect(!held64)
        #expect(latch.sustainedCount == 2, "2 音が鳴り続けている")
    }

    @Test("離すと、鍵を離してあった音だけまとめて消える")
    func releasesOnPedalUp() {
        var latch = NoteLatch()
        latch.noteOn(60, channel: 0)
        latch.noteOn(64, channel: 2)
        _ = latch.pedal(100)
        _ = latch.shouldSendNoteOff(60)  // 鍵を離した（キープされる）
        // 64 はまだ押しっぱなし

        let released = latch.pedal(0)
        #expect(released.map(\.note) == [60], "離してあった音だけ消す")
        #expect(released.first?.channel == 0, "鳴らしたチャンネルへ返す")
        #expect(latch.sustainedCount == 0)
        #expect(!latch.isEngaged)
        // まだ押している 64 は生きているので、その後の Note Off は通る
        let sends64 = latch.shouldSendNoteOff(64)
        #expect(sends64)
    }

    @Test("キープ中に同じ鍵を弾き直したら鳴らし直しに戻る")
    func retriggerLeavesSustain() {
        var latch = NoteLatch()
        latch.noteOn(60, channel: 0)
        _ = latch.pedal(100)
        _ = latch.shouldSendNoteOff(60)
        #expect(latch.sustainedCount == 1)

        latch.noteOn(60, channel: 0)  // 弾き直し
        #expect(latch.sustainedCount == 0, "溜め置きから外れる")
        let heldAgain = latch.shouldSendNoteOff(60)
        #expect(!heldAgain, "改めてキープ対象になる")
    }

    @Test("ヒステリシス — 中間値でバタつかない")
    func hysteresis() {
        var latch = NoteLatch()
        _ = latch.pedal(40)
        #expect(!latch.isEngaged, "しきい値未満では踏んだことにしない")
        _ = latch.pedal(NoteLatch.engageAt)
        #expect(latch.isEngaged)
        // 一度踏んだら、離す側のしきい値まで戻さないと解除しない
        _ = latch.pedal(40)
        #expect(latch.isEngaged, "中間まで戻しただけでは解除しない")
        _ = latch.pedal(NoteLatch.releaseAt)
        #expect(!latch.isEngaged)
    }

    @Test("送り先が変わったら帳簿を仕切り直す（二重に消さない）")
    func resetOnTargetChange() {
        var latch = NoteLatch()
        latch.noteOn(60, channel: 0)
        _ = latch.pedal(100)
        _ = latch.shouldSendNoteOff(60)
        #expect(latch.sustainedCount == 1)

        // reset は**宙に浮くノートを返す** — 呼び手が旧スロットへ消しに行く。
        // 以前はここで捨てていたため実機で音が残った（2026-08-02）
        let orphaned = latch.reset()
        #expect(orphaned.map(\.note) == [60], "宙に浮くノートを返すこと")
        #expect(latch.sustainedCount == 0)
        #expect(!latch.isEngaged)
        let afterReset = latch.pedal(0)
        #expect(afterReset.isEmpty)
    }

    @Test("押した記録の無い Note Off は素通し（取りこぼしで音を残さない）")
    func unknownNoteOffPassesThrough() {
        var latch = NoteLatch()
        _ = latch.pedal(100)
        let passes = latch.shouldSendNoteOff(72)
        #expect(passes, "知らない音は握りつぶさず通す")
    }
}
