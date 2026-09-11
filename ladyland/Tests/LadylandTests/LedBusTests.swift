//! LedBus のテスト — completion-gated 送信と合成器。
//!
//! fake sender を注入し、実測で決めた設計則を固定する:
//!   in-flight は常に 1 / 中間状態は合流 / 無変化は送らない / watchdog 自己回復。

import Foundation
import Testing

import Lpd8Kit

@testable import Ladyland

/// 送信を記録し、完了を手動で発火できる fake
@MainActor
final class FakeLedSender: LedSender {
    private(set) var sentFrames: [[UInt8]] = []
    private(set) var invalidateCount = 0
    private var completions: [@MainActor () -> Void] = []
    var hasDestination = true

    func send(_ frame: [UInt8], onComplete: @escaping @MainActor () -> Void) -> Bool {
        guard hasDestination else { return false }
        sentFrames.append(frame)
        completions.append(onComplete)
        return true
    }

    func invalidate() {
        invalidateCount += 1
    }

    /// 最古の完了コールバックを発火する（デバイスの「食い終わった」相当）
    func completeOldest() {
        guard !completions.isEmpty else { return }
        completions.removeFirst()()
    }
}

@Suite("LedBus completion-gated 送信")
@MainActor
struct LedBusTests {
    private func makeBus() -> (LedBus, FakeLedSender) {
        let sender = FakeLedSender()
        let bus = LedBus(sender: sender)
        return (bus, sender)
    }

    @Test("in-flight は常に 1 — 完了が来るまで次を送らない")
    func singleInFlight() {
        let (bus, sender) = makeBus()
        bus.pump()
        #expect(sender.sentFrames.count == 1)

        // 状態を変えて何度 pump しても in-flight 中は送らない
        bus.flashSelection(0)
        bus.flashSelection(3)
        bus.pump()
        #expect(sender.sentFrames.count == 1)

        // 完了 = 次を送っていい合図。溜まった変更は 1 フレームに合流している
        sender.completeOldest()
        #expect(sender.sentFrames.count == 2)
    }

    @Test("無変化なら送らない（アイドル時トラフィック 0）")
    func noSendWhenUnchanged() {
        let (bus, sender) = makeBus()
        bus.pump()
        sender.completeOldest()
        let count = sender.sentFrames.count
        bus.pump()
        bus.tick()
        bus.tick()
        #expect(sender.sentFrames.count == count, "同じ desired を再送しない")
    }

    /// ⚠️ **状態が変わったときだけフレームが飛ぶ**こと。明滅や進捗による輝度変化を
    /// 入れると shadow 差分が効かなくなり、9-10fps の帯域を毎 tick 食い潰す
    @Test("状態が変わらない間は送信 0 — 進捗では送らない")
    func playStateSendsOnlyOnChange() {
        let (bus, sender) = makeBus()
        var states = [PadPlayState](repeating: .idle, count: 8)
        bus.configure(playStateProvider: { states })

        bus.pump()
        sender.completeOldest()
        let settled = sender.sentFrames.count

        // 再生を始めた = 状態が変わった → 1 フレーム飛ぶ
        states[0] = .playing
        bus.tick()
        sender.completeOldest()
        #expect(sender.sentFrames.count == settled + 1, "変化したら送る")

        // 鳴り続けている間は何 tick 回しても送らない（進捗は色に出さない）
        let playing = sender.sentFrames.count
        for _ in 0..<20 {
            bus.tick()
            sender.completeOldest()
        }
        #expect(sender.sentFrames.count == playing, "⚠️ 再生中も無変化なら送信 0")

        // 一時停止 = 光りが消える（再生中とはワイヤ上で違うので 1 回飛ぶ）
        states[0] = .paused
        bus.tick()
        sender.completeOldest()
        #expect(sender.sentFrames.count == playing + 1, "消灯のフレームが飛ぶ")

        // ⚠️ **二値化の効き目**: 一時停止 → 頭で停止 は**どちらも光らない**ので、
        // ワイヤ上の差分が無い = 送信 0
        let paused = sender.sentFrames.count
        states[0] = .idle
        for _ in 0..<10 {
            bus.tick()
            sender.completeOldest()
        }
        #expect(sender.sentFrames.count == paused, "一時停止 → 頭で停止 は送信 0")
    }

    @Test("メーターの微小な揺れは量子化で吸収される")
    func quantizationSuppressesJitter() {
        let (bus, sender) = makeBus()
        var level: Float = 0.50
        bus.configure(levelProvider: { level })
        bus.pump()
        sender.completeOldest()
        let count = sender.sentFrames.count

        level = 0.51  // 1/15 段未満の揺れ → 同じワイヤ値
        bus.pump()
        #expect(sender.sentFrames.count == count)

        level = 0.9  // 段をまたぐ変化 → 送る
        bus.pump()
        #expect(sender.sentFrames.count == count + 1)
    }

    @Test("watchdog — 完了が消えても 1 秒で自己回復する")
    func watchdogRecovers() {
        let (bus, sender) = makeBus()
        bus.pump()
        #expect(sender.sentFrames.count == 1)

        // 完了を発火しないまま 1 秒経過を偽装 → in-flight 解除 + 宛先破棄 + 再送
        bus.tick(nowNs: DispatchTime.now().uptimeNanoseconds + 1_500_000_000)
        #expect(sender.invalidateCount == 1)
        #expect(sender.sentFrames.count == 2, "shadow 破棄で全再描画が走る")
    }

    @Test("キルスイッチ — オフで即全消灯、以後は送らない")
    func killSwitch() {
        let (bus, sender) = makeBus()
        bus.pump()
        sender.completeOldest()

        bus.enabled = false
        #expect(sender.sentFrames.last == LedBus.allOffFrame)
        let count = sender.sentFrames.count
        bus.flashSelection(2)
        bus.tick()
        #expect(sender.sentFrames.count == count, "無効中は一切送らない")

        bus.enabled = true
        #expect(sender.sentFrames.count == count + 1, "再有効化で全再描画")
    }

    @Test("宛先なし（LPD8 不在）でも in-flight が立たない")
    func noDestination() {
        let (bus, sender) = makeBus()
        sender.hasDestination = false
        bus.pump()
        #expect(sender.sentFrames.isEmpty)
        #expect(!bus.inFlight, "送れなかったのに待ち続けない")
    }

    @Test("suspend 中は送らず、resume で全再描画")
    func suspendResume() {
        let (bus, sender) = makeBus()
        bus.pump()
        sender.completeOldest()
        let count = sender.sentFrames.count

        bus.suspend()
        bus.flashSelection(1)
        bus.tick()
        #expect(sender.sentFrames.count == count)

        bus.resume()
        #expect(sender.sentFrames.count == count + 1)
    }
}

@Suite("LedCompositor 合成器")
struct LedCompositorTests {
    private let base = Array(repeating: Rgb8(0, 100, 200), count: 8)

    // MARK: - 再生状態の色（mako 要望「Pad の色も合わせたい」）

    /// ⚠️ **プロバイダ未接続なら今までどおり**（degrade gracefully）
    @Test("プロバイダが繋がっていなければ基本色のまま")
    func playStatesAbsentKeepsBase() {
        let base = [Rgb8](repeating: Rgb8(0, 24, 48), count: 8)
        #expect(LedCompositor.base(base, playStates: []) == base)
    }

    /// ⚠️ **二値**（mako 裁定「再生中だけ光る」）。ステージで目に入る情報を
    /// 1 つに絞る判断で、実機の LED は「いま鳴っている席はどれか」だけを言う
    @Test("光るのは再生中だけ — 一時停止は基本色に落ちる")
    func onlyPlayingLights() {
        let base = [Rgb8](repeating: Rgb8(0, 24, 48), count: 8)
        var states = [PadPlayState](repeating: .idle, count: 8)
        states[0] = .playing
        states[3] = .paused

        let out = LedCompositor.base(base, playStates: states)
        #expect(out[0] == LedCompositor.playingColor, "鳴っている席だけ水色")
        #expect(out[3] == base[3], "一時停止は光らない")
        #expect(out[1] == base[1], "頭で停止している席も光らない")
        #expect(out[3] == out[1], "⚠️ 一時停止と頭で停止はワイヤ上で同じ")
    }

    @Test("flash が基本色より優先され、対象パッドは白・他は減光")
    func flashPriority() {
        let out = LedCompositor.compose(base: base, flashPad: 3, level: 1.0)
        #expect(out[3] == Rgb8(255, 255, 255))
        #expect(out[0].g < 100, "flash 中の他パッドは減光")
    }

    @Test("レベル 0 でも輝度 floor で基本色が見える")
    func brightnessFloor() {
        let out = LedCompositor.compose(base: base, flashPad: nil, level: 0)
        #expect(out[0].g > 0 && out[0].b > 0, "無音でも死んで見えない")
        #expect(out[0].b == UInt8(200.0 * LedCompositor.brightnessFloor))
    }

    @Test("レベル最大で基本色そのまま")
    func fullLevel() {
        let out = LedCompositor.compose(base: base, flashPad: nil, level: 1.0)
        #expect(out[0] == Rgb8(0, 100, 200))
    }
}

/// **論理席 ↔ 実機セルの並び替え**
/// （mako 実機報告 2026-08-06「ついてるかついてないかの Pad が上下逆ですね」）
@Suite("LED の上下段")
struct Lpd8PadRowTests {
    /// ⚠️ **自分自身が逆変換**（前半と後半を入れ替えるだけ = involution）。
    /// これが成り立つので、席 → セルにも セル → 席 にも同じ関数が使える
    @Test("2 回掛けると元に戻る")
    func swapIsInvolution() {
        let seats = Array(0..<8)
        #expect(Lpd8SysEx.swapPadRows(Lpd8SysEx.swapPadRows(seats)) == seats)
    }

    @Test("上段と下段が入れ替わる")
    func swapsRows() {
        #expect(Lpd8SysEx.swapPadRows(Array(0..<8)) == [4, 5, 6, 7, 0, 1, 2, 3])
    }

    /// 8 個でなければ触らない（部分更新は無い前提を壊さない）
    @Test("8 個でなければそのまま返す")
    func passesThroughWrongCount() {
        #expect(Lpd8SysEx.swapPadRows([1, 2, 3]) == [1, 2, 3])
        #expect(Lpd8SysEx.swapPadRows([Int]()) == [])
    }

    /// **席 0（論理 pad 1 = 上段左）が上段のセルを光らせる**。
    /// LED フレームは下段が先なので、上段は**セル 4-7**に載る
    @Test("上段左の席は上段のセルへ載る")
    func topLeftSeatLandsOnTopRow() {
        var seats = [PadPlayState](repeating: .idle, count: 8)
        seats[0] = .playing  // 論理 pad 1 = 上段左

        let base = [Rgb8](repeating: Rgb8(0, 24, 48), count: 8)
        let cells = Lpd8SysEx.swapPadRows(
            LedCompositor.base(base, playStates: seats))

        #expect(cells[4] == LedCompositor.playingColor, "上段はセル 4-7")
        #expect(cells[0] == base[0], "セル 0-3（下段）は光らない")
    }

    /// **席 4（論理 pad 5 = 下段左）が下段のセルを光らせる**
    @Test("下段左の席は下段のセルへ載る")
    func bottomLeftSeatLandsOnBottomRow() {
        var seats = [PadPlayState](repeating: .idle, count: 8)
        seats[4] = .playing  // 論理 pad 5 = 下段左

        let base = [Rgb8](repeating: Rgb8(0, 24, 48), count: 8)
        let cells = Lpd8SysEx.swapPadRows(
            LedCompositor.base(base, playStates: seats))

        #expect(cells[0] == LedCompositor.playingColor, "下段はセル 0-3")
        #expect(cells[4] == base[4], "セル 4-7（上段）は光らない")
    }

    /// 並び替えは**フレームの中身を変えるだけ**で、長さも構造も変えない
    @Test("並び替えてもフレームの形は同じ")
    func frameShapeUnchanged() {
        let colors = (0..<8).map { Rgb8(UInt8($0 * 8), 0, 0) }
        let direct = Lpd8SysEx.ledFrame(colors)
        let swapped = Lpd8SysEx.ledFrame(Lpd8SysEx.swapPadRows(colors))
        #expect(direct.count == swapped.count)
        #expect(direct != swapped, "中身は入れ替わっている")
    }
}
