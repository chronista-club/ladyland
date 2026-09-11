//! **render のコストを実機で控える器**（mako 裁定 2026-08-06「まず計測してから決める」）。
//!
//! 合成ベンチ（`RenderBenchTests`）は最悪ケースの上限を教えてくれるが、
//! **本番グラフの上で実際に何 ns かかっているか**は別の話 — 実バッファ長も、
//! 同時に走る他の AU（KORG / Splice…）も、そこにしか無い。
//!
//! ## 控えるのは加算と max だけ
//!
//! ⚠️ ここはリアルタイム経路。`padEvents` と同じ作法で、**RT 側では
//! 固定長のカウンタを足すだけ**にする — 確保も割り算も文字化もしない。
//! 平均・占有率を出すのは `InstrumentRack` の 0.5 秒タイマー（main）。
//!
//! ## 切り方
//!
//! 計測そのものにも費用がある（`clock_gettime_nsec_np` × 2 + 加算数本）ので、
//! **切れるようにしてある**。既定は on:
//!
//! ```bash
//! LADYLAND_RENDER_STATS=0 swift run -c release Ladyland   # 計測を切る
//! ```
//!
//! 既定を on にしたのは、費用がブロックあたり数十 ns で**実測値の 0.1% 未満**
//! （192kHz / 512 frames の sampler が中央値 207us）に対し、リハで数字が
//! 残っていることの価値の方が大きいため（design/06 §1 の価値基準②）。

import Foundation

/// 計測の入り切り。**プロセス起動時に 1 回だけ読む**（RT 経路で
/// 環境変数を引かないため `let`）
enum RenderMetering {
    /// 既定 on。`LADYLAND_RENDER_STATS=0` で切れる（再ビルド不要）
    static let enabled = ProcessInfo.processInfo.environment["LADYLAND_RENDER_STATS"] != "0"
}

/// 0.5 秒ぶんの render コスト（main 側で読む形）
struct RenderStats {
    /// 呼ばれた回数
    var calls: UInt64
    /// ns の合計
    var totalNs: UInt64
    /// 1 ブロックの最大 ns — **ここが締切を超えるとドロップする**
    var maxNs: UInt64
    /// 直近の frameCount（実機の実バッファ長。合成ベンチの前提の答え合わせになる）
    var frameCount: UInt32
    /// **AU が申告しているレート** — `outputBus.format.sampleRate`。
    /// 「自分はこのレートで回っているはずだ」という AU 側の信念
    var sampleRate: Double

    /// **出したフレームの累積**（この区間で実際に render したフレーム数）。
    /// ⚠️ `calls × frameCount` では近似にしかならない — frameCount は
    /// ブロックごとに変わりうるし、控えているのは直近 1 ブロック分だけ
    var frames: UInt64 = 0

    /// **前回ドレインからの実経過 ns**。
    /// ⚠️ 0.5 秒と決め打ちしてはいけない — `Timer` は正確ではなく、
    /// そこがずれると実測レートがそのまま嘘になる
    var elapsedNs: UInt64 = 0

    var averageNs: Double { calls > 0 ? Double(totalNs) / Double(calls) : 0 }

    // MARK: - 実測レート（申告値の答え合わせ）

    /// **実測レート = 出したフレーム ÷ 実経過秒**。
    ///
    /// AU が信じているレート（`sampleRate`）と食い違うなら、
    /// **エンジンは AU の申告とは違う速さで引いている**。
    /// 192k で作ったバッファを 44.1k で吐けば、ちょうど 4.35 倍に間延びする
    var measuredRate: Double? {
        guard elapsedNs > 0, frames > 0 else { return nil }
        return Double(frames) / (Double(elapsedNs) / 1_000_000_000)
    }

    /// 乖離とみなす割合（2%）。クロックの揺れとドレイン境界の端数は
    /// この程度に収まるので、それを超えたら本物のずれ
    static let divergenceTolerance = 0.02

    /// 申告に対する実測の倍率（1.0 = 一致）。測れなければ `nil`
    var rateRatio: Double? {
        guard let measured = measuredRate, sampleRate > 0 else { return nil }
        return measured / sampleRate
    }

    /// **申告と実測が食い違っているか**（純関数 — テスト対象）
    var isRateDiverged: Bool {
        guard let ratio = rateRatio else { return false }
        return abs(ratio - 1) > Self.divergenceTolerance
    }

    /// このブロックを出し切るまでの締切（ns）
    var deadlineNs: Double {
        sampleRate > 0 ? Double(frameCount) / sampleRate * 1_000_000_000 : 0
    }

    var averageLoad: Double { deadlineNs > 0 ? averageNs / deadlineNs * 100 : 0 }

    /// **最大の占有率** — 100% に近づいたら音が途切れる
    var maxLoad: Double { deadlineNs > 0 ? Double(maxNs) / deadlineNs * 100 : 0 }

    /// `debug.log` へ流す 1 行（**そのまま読んで判断できる形**にする）。
    ///
    /// ⚠️ **申告と実測を並べる**（2026-08-06、実機でまだ間延びしていたため）。
    /// 読む側に計算させない — ずれている時だけ ⚠️ と倍率を出し、
    /// 合っている時は静かに「実測一致」とだけ言う（平時は静かに、が既存の作法）
    func line(_ name: String) -> String {
        let cost = String(
            format: "平均 %.1fus (%.1f%%) / 最大 %.1fus (%.1f%%) / %llu blk",
            averageNs / 1000, averageLoad, Double(maxNs) / 1000, maxLoad, calls)

        guard let measured = measuredRate, let ratio = rateRatio else {
            // 実測できていない（区間が短すぎる / 1 ブロックも回っていない）
            return String(
                format: "render: %@ 申告 %.0fHz / 実測なし / %d frames — %@",
                name, sampleRate, frameCount, cost)
        }
        guard isRateDiverged else {
            return String(
                format: "render: %@ %.0fHz（実測一致）/ %d frames — %@",
                name, sampleRate, frameCount, cost)
        }
        // ⚠️ ここが出たら、**AU の信念とエンジンの実際が食い違っている**
        return String(
            format: "render: %@ 申告 %.0fHz / 実測 %.0fHz ⚠️ %.2f 倍ずれ / %d frames — %@",
            name, sampleRate, measured, 1 / ratio, frameCount, cost)
    }
}

/// **その 1 行を出すべきか**を決める門 — 純関数（テスト対象）。
///
/// mako 苦情 2026-08-07「render: sampler... が debug ログに**定期で**流れてる」。
/// ⚠️ **問題は信号ではなく周期性**。同じ「正常です」を 2 秒に 1 回言い続けると、
/// **本当に何かが変わった行がその中に埋もれる**。
///
/// ⚠️ **ログを増やして解決しない**（mako「あまり定期のログは拾いたくないし
/// 増やしたくはないんだよね」）。増やすのではなく**減らす**。
///
/// | 出す | なぜ |
/// |---|---|
/// | **初回** | 初期値が見えないと「変化」も読めない |
/// | **レートが変わった** | ここが今日 LadySynth のずれを見つけた種類の事実 |
/// | **締切を割った / 割りそう** | 本当に危ないとき |
/// | **申告と実測のずれが始まった / 直った** | 状態が変わった瞬間だけ |
///
/// それ以外（「今も正常」）は**出さない**。
/// 詳細が要るときは `LADYLAND_RENDER_STATS_ALL=1` で毎回出る。
///
/// **判断基準**: その行は「何かが変わった / おかしい」を言っているか。
/// 「今も正常」を言っているだけなら消す
enum RenderLogGate {
    /// 前回の姿（比較に要る分だけ）
    struct Mark {
        let sampleRate: Double
        let frameCount: UInt32
        let diverged: Bool
        /// 締切を割っていたか
        let overrun: Bool

        init(_ stats: RenderStats) {
            sampleRate = stats.sampleRate
            frameCount = stats.frameCount
            diverged = stats.isRateDiverged
            overrun = stats.maxLoad >= RenderLogGate.overrunPercent
        }
    }

    /// なぜ出すのか（行の頭に付ける）
    struct Reason {
        let prefix: String
    }

    /// **これを超えたら締切が危ない**。100% で音が途切れるので、
    /// 手前で言う必要がある — 途切れてから知っても遅い
    static let overrunPercent = 80.0

    /// ⚠️ **毎回出す**（従来の挙動）。既定は off = 静か。
    /// `LADYLAND_RENDER_STATS=0` が計測ごと切るのは変わらない
    static let verbose = ProcessInfo.processInfo.environment["LADYLAND_RENDER_STATS_ALL"] == "1"

    /// 出すべきなら理由、黙るべきなら `nil` — 純関数（テスト対象）
    static func reason(for stats: RenderStats, previous: Mark?) -> Reason? {
        if verbose { return Reason(prefix: "") }
        guard let previous else {
            // ⚠️ **初回は必ず出す** — 初期値が無いと変化が読めない
            return Reason(prefix: "起動 ")
        }
        if stats.sampleRate != previous.sampleRate {
            return Reason(prefix: "⚠️ レート変化 ")
        }
        // ブロック長が変わるのもデバイス側の事件（締切が変わる）
        if stats.frameCount != previous.frameCount {
            return Reason(prefix: "⚠️ ブロック長変化 ")
        }
        let overrun = stats.maxLoad >= overrunPercent
        if overrun != previous.overrun {
            // ⚠️ **直ったときも 1 回出す** — 「危ない」が出たきり黙ると、
            // まだ危ないのか直ったのかが分からない
            return Reason(prefix: overrun ? "⚠️ 締切が危ない " : "締切は戻った ")
        }
        if stats.isRateDiverged != previous.diverged {
            return Reason(prefix: stats.isRateDiverged ? "⚠️ 実測がずれた " : "ずれは直った ")
        }
        // ここまで来たら「今も正常」= 出さない
        return nil
    }
}

/// render のコストを控える AU（`LadySampler` / `LadySynth`）。
/// ドレインは `InstrumentRack` の 0.5 秒タイマーが 1 本でまとめて回す
protocol RenderMetered: AnyObject {
    /// 表示名（`debug.log` に出る）
    var meteredName: String { get }
    /// 控えを読んで**即クリア**する。何も無ければ `nil`
    func drainRenderStats() -> RenderStats?
}
