//! **申告レートと実測レートの突き合わせ**（2026-08-06、実機でまだ間延びしていたため）。
//!
//! `setFormat` が成功していても、エンジンが古いレートで引き続けていれば
//! **192k で作ったバッファが 44.1k で吐かれて 4.35 倍に間延びする**。
//! 申告（AU の信念）と実測（出したフレーム ÷ 実経過）を突き合わせれば、
//! その食い違いがログの 1 行で分かる。
//!
//! ここで固定するのは純関数の部分だけ — 実機で何が起きるかは
//! `debug.log` の `render:` / `format[...]` 行が答える。

import Foundation
import Testing

@testable import Ladyland

@Suite("render の実測レート")
struct RenderStatsTests {
    /// 1 秒ぶん回した体（実経過も 1 秒）
    private func stats(
        declared: Double, frames: UInt64, elapsedNs: UInt64, frameCount: UInt32 = 512
    ) -> RenderStats {
        RenderStats(
            calls: frames / UInt64(frameCount), totalNs: 1_000, maxNs: 2_000,
            frameCount: frameCount, sampleRate: declared,
            frames: frames, elapsedNs: elapsedNs)
    }

    @Test("実測レート = 出したフレーム ÷ 実経過秒")
    func measuredRate() {
        // 1 秒で 48000 フレーム出した → 48kHz
        let s = stats(declared: 48000, frames: 48000, elapsedNs: 1_000_000_000)
        let measured = try! #require(s.measuredRate)
        #expect(abs(measured - 48000) < 1)
    }

    /// ⚠️ **0.5 秒と決め打ちしない**ことの効き目。`Timer` が 0.6 秒で
    /// 発火したのに 0.5 で割ると、実測レートが 2 割ずれて嘘の警告が出る
    @Test("経過が伸びても正しい Hz が出る — Timer の誤差に引きずられない")
    func measuredRateFollowsActualElapsed() {
        // 0.6 秒で 28800 フレーム = 48kHz（0.5 で割ると 57.6k になってしまう）
        let s = stats(declared: 48000, frames: 28800, elapsedNs: 600_000_000)
        let measured = try! #require(s.measuredRate)
        #expect(abs(measured - 48000) < 1)
        #expect(s.isRateDiverged == false, "正しく測れていれば警告は出ない")
    }

    @Test("測れないときは nil — 嘘の数字を出さない")
    func measuredRateIsNilWhenUnmeasurable() {
        #expect(stats(declared: 48000, frames: 48000, elapsedNs: 0).measuredRate == nil,
                "初回ドレインは基準が無い")
        #expect(stats(declared: 48000, frames: 0, elapsedNs: 1_000_000_000).measuredRate == nil,
                "1 ブロックも回っていない")
        #expect(stats(declared: 48000, frames: 48000, elapsedNs: 0).isRateDiverged == false,
                "測れないなら警告も出さない")
    }

    /// **これが今の症状**。192k を申告しているのに 44.1k で引かれていれば、
    /// バッファは 4.35 倍に間延びして聞こえる
    @Test("申告 192k / 実測 44.1k を乖離として捕まえる")
    func catchesTheStretchCase() {
        // 1 秒で 44100 フレームしか出ていないのに、AU は 192k のつもり
        let s = stats(declared: 192000, frames: 44100, elapsedNs: 1_000_000_000)
        #expect(s.isRateDiverged, "これを見逃すと原因が分からないまま")
        let ratio = try! #require(s.rateRatio)
        #expect(abs(1 / ratio - 192000.0 / 44100.0) < 0.01, "約 4.35 倍のずれ")
        #expect(s.line("Lady Sampler").contains("⚠️"))
        #expect(s.line("Lady Sampler").contains("4.35 倍ずれ"))
    }

    @Test("一致していれば静かに通す", arguments: [44100.0, 48000.0, 96000.0, 192000.0])
    func matchingRateIsQuiet(rate: Double) {
        let s = stats(declared: rate, frames: UInt64(rate), elapsedNs: 1_000_000_000)
        #expect(s.isRateDiverged == false)
        let line = s.line("Lady Sampler")
        #expect(line.contains("実測一致"))
        #expect(line.contains("⚠️") == false, "平時は静かに")
    }

    /// 閾値は 2%。クロックの揺れとドレイン境界の端数はこの中に収まる
    @Test("2% の閾値どおりに出る / 出ない")
    func toleranceBoundary() {
        // 1.9% 速い → 許容
        let inside = stats(
            declared: 48000, frames: UInt64(48000 * 1.019), elapsedNs: 1_000_000_000)
        #expect(inside.isRateDiverged == false)

        // 2.5% 速い → 乖離
        let outside = stats(
            declared: 48000, frames: UInt64(48000 * 1.025), elapsedNs: 1_000_000_000)
        #expect(outside.isRateDiverged)

        // 遅い側も同じように捕まえる
        let slow = stats(
            declared: 48000, frames: UInt64(48000 * 0.97), elapsedNs: 1_000_000_000)
        #expect(slow.isRateDiverged)
    }

    /// ⚠️ `calls × frameCount` では近似にしかならない — frameCount は
    /// ブロックごとに変わりうるので、**累積を持つ**必要がある
    @Test("累積フレームを使う — calls × frameCount の近似ではない")
    func usesAccumulatedFrames() {
        // 直近の frameCount は 512 だが、実際は可変長で 40000 フレーム出た
        let s = RenderStats(
            calls: 100, totalNs: 1_000, maxNs: 2_000,
            frameCount: 512, sampleRate: 48000,
            frames: 40000, elapsedNs: 1_000_000_000)
        let measured = try! #require(s.measuredRate)
        #expect(abs(measured - 40000) < 1, "累積を割る（100 × 512 = 51200 ではない）")
    }
}

/// **ログの門**（mako 苦情 2026-08-07「render: sampler... が debug ログに
/// **定期で**流れてる」）。
///
/// ⚠️ 固定するのは **「今も正常」を繰り返さないこと**と
/// **「変わった / 危ない」を落とさないこと**の両方。
/// 前者だけ守ると、今日 LadySynth のずれを見つけた種類の行まで消える
@Suite("render ログの門")
struct RenderLogGateTests {
    private func stats(
        rate: Double = 48000, frameCount: UInt32 = 512, maxNs: UInt64 = 1_000_000,
        frames: UInt64 = 48000, elapsedNs: UInt64 = 1_000_000_000
    ) -> RenderStats {
        RenderStats(
            calls: 100, totalNs: 1_000_000, maxNs: maxNs,
            frameCount: frameCount, sampleRate: rate,
            frames: frames, elapsedNs: elapsedNs)
    }

    /// ⚠️ **初期値が見えないと「変化」も読めない**
    @Test("初回は必ず出す")
    func firstAlwaysSpeaks() {
        #expect(RenderLogGate.reason(for: stats(), previous: nil) != nil)
    }

    /// ⭐ **これが苦情の本体** — 同じ姿なら二度と出さない
    @Test("何も変わらなければ二度と出さない")
    func steadyStateIsSilent() {
        let first = stats()
        let mark = RenderLogGate.Mark(first)
        #expect(RenderLogGate.reason(for: stats(), previous: mark) == nil)
        // 何回来ても黙ったまま
        #expect(RenderLogGate.reason(for: stats(), previous: mark) == nil)
    }

    /// ⚠️ **これを落としたら今日のバグは見つからなかった**
    @Test("レートが変わったら出す")
    func rateChangeSpeaks() {
        let mark = RenderLogGate.Mark(stats(rate: 44100, frames: 44100))
        let reason = RenderLogGate.reason(
            for: stats(rate: 192000, frames: 192000), previous: mark)
        #expect(reason != nil)
        #expect(reason?.prefix.contains("レート") == true)
    }

    /// ブロック長が変わると**締切そのものが変わる**（デバイス側の事件）
    @Test("ブロック長が変わったら出す")
    func frameCountChangeSpeaks() {
        let mark = RenderLogGate.Mark(stats(frameCount: 512))
        #expect(RenderLogGate.reason(for: stats(frameCount: 128), previous: mark) != nil)
    }

    /// ⚠️ **途切れてから知っても遅い**ので、手前（80%）で言う
    @Test("締切が危なくなったら出す")
    func overrunSpeaks() {
        let safe = stats(frameCount: 512, maxNs: 1_000_000)  // 締切 10.67ms に対し 9.4%
        let mark = RenderLogGate.Mark(safe)
        let danger = stats(frameCount: 512, maxNs: 10_000_000)  // 93.8%
        let reason = RenderLogGate.reason(for: danger, previous: mark)
        #expect(reason != nil)
        #expect(reason?.prefix.contains("締切") == true)
    }

    /// ⚠️ **直ったときも 1 回出す** — 「危ない」が出たきり黙ると、
    /// まだ危ないのか直ったのかが分からない
    @Test("締切が戻ったら 1 回出して、その後は黙る")
    func recoverySpeaksOnce() {
        let danger = stats(frameCount: 512, maxNs: 10_000_000)
        let safe = stats(frameCount: 512, maxNs: 1_000_000)
        let mark = RenderLogGate.Mark(danger)
        #expect(RenderLogGate.reason(for: safe, previous: mark) != nil, "戻ったことを言う")
        #expect(
            RenderLogGate.reason(for: safe, previous: RenderLogGate.Mark(safe)) == nil,
            "その後は黙る")
    }

    /// 申告と実測のずれも**始まり / 終わりだけ**
    @Test("実測のずれは始まったときと直ったときだけ出す")
    func divergenceEdgesOnly() {
        let ok = stats(rate: 48000, frames: 48000)
        let bad = stats(rate: 48000, frames: 11000)  // 4.35 倍ずれ相当
        #expect(bad.isRateDiverged)

        #expect(RenderLogGate.reason(for: bad, previous: RenderLogGate.Mark(ok)) != nil)
        // ずれたまま変わらなければ黙る（**ずれの繰り返しも周期ログ**）
        #expect(RenderLogGate.reason(for: bad, previous: RenderLogGate.Mark(bad)) == nil)
        #expect(RenderLogGate.reason(for: ok, previous: RenderLogGate.Mark(bad)) != nil)
    }

    /// 詳細が要るときの逃げ道が**残っている**こと
    @Test("全部出す口が用意されている")
    func verboseEscapeHatchExists() {
        if ProcessInfo.processInfo.environment["LADYLAND_RENDER_STATS_ALL"] == nil {
            #expect(RenderLogGate.verbose == false, "既定は静か")
        }
    }
}
