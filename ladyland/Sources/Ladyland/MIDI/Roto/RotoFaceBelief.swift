//! **いま実機がどの面に居ると信じているか、そしてそれはどれくらい確かか**
//! （mako 要望 2026-08-07「SMART モードで遷移を網羅して、こちら側で shadow の
//! 状態を表示できるくらいに protocol に合わせないとだね」）。
//!
//! ## 病気の正体
//!
//! ladyland の状態は**「送ったこと」を記録していて、「実機がどうなっているか」を
//! 記録していない**。同じ形の不具合が 3 つ出た:
//!
//! | | 何が起きたか |
//! |---|---|
//! | `RotoShadow`（ラベル / モーター） | 送った内容を真実として持つので、**落ちたフレームが「もう正しい」と凍り**、二度と再送されない → 差し直しでしか直らない |
//! | `currentFace` | **SMART へ切替を送った時点で `.smart` にしている**。SMART には通知が無いので**反証が永久に来ない** → FUNC の引き戻しが無視されても誰も気づかなかった（実機は PLUGIN、ログは `face=SMART`） |
//! | モーター位置 | 同じ構造 |
//!
//! ⚠️ **ここで直すのは 2 番目だけ、それも「見えるようにする」までだ。**
//! `currentFace` は `paintsSmartCells` / `paintsTrackCells` を握っていて、
//! **算出を変えると送るものが変わる**。8/8 は明日なので、
//! **計器を付けるのであって機械は直さない**。信念は**並行して**持つ。
//!
//! ## なぜ SMART は永久に推定なのか
//!
//! デバイスは PLUGIN 面（`0B 01`）と MIX 面（`0C 02`）へ移ったことは通知するが、
//! **SMART 面へ移ったことは通知しない**。だから「SMART に居る」は
//! **こちらが送ったという事実からの推論**でしかありえない。
//!
//! これは実装の手落ちではなく**プロトコルの非対称性**なので、直しようがない。
//! できるのは「**推定であると名乗ること**」だけ — 画面に「SMART（推定・42 秒）」と
//! 出ていれば、mako が実機を見て食い違いに気づける。
//! 昨日欠けていたのはまさにこの警報だった。

import Foundation

/// 面が変わる**きっかけ**の一覧 — 値として持つ（doc コメントではない）。
///
/// ⚠️ **画面に出すために値にしてある。** doc コメントに書くと、実機を触りながら
/// 「いま何で面が変わったのか」を確かめられない
struct RotoFaceTransition: Identifiable, Equatable {
    /// 何をすると起きるか
    let trigger: String
    /// どの面へ行くか
    let target: String
    /// デバイスからの通知（`nil` = **通知が無い = 永久に推定**）
    let notification: String?
    /// **誰が起こすか** — 人 / デバイス / ホスト（= ladyland の送信）
    let origin: Origin
    /// この行の**由来**。⚠️ 実測と推論を混ぜない
    let provenance: Provenance

    enum Origin: String, Equatable {
        /// 人が実機のキーを押す
        case human = "人"
        /// デバイスが自分で移る
        case device = "デバイス"
        /// **ladyland の送信が面を動かす**（副作用）
        case host = "ホスト"
    }

    enum Provenance: Equatable {
        /// 実機で確かめた（日付つき）
        case measured(String)
        /// 資料や他の実測からの推論。⚠️ **確かめていない**
        case inferred(String)
        /// 未検証
        case untested

        var label: String {
            switch self {
            case .measured(let date): return "実測 \(date)"
            case .inferred(let why): return "推論（\(why)）"
            case .untested: return "未検証"
            }
        }

        var isMeasured: Bool {
            if case .measured = self { return true }
            return false
        }
    }

    var id: String { "\(trigger)→\(target)" }

    /// 通知があるか = **確認に昇格できるか**
    var isConfirmable: Bool { notification != nil }
}

enum RotoFaceTransitions {
    /// **面の遷移の全体像**（mako 要望 2026-08-07「遷移を網羅して」）。
    ///
    /// ⚠️ **`0A 11` の送信自体が面を動かす**（実測 2026-08-04）。
    /// 「ホストが塗ると面が変わる」は直感に反するので必ず表に入れておく —
    /// `Face.paintsTrackCells` が `.mix` と `.unknown` に限られているのは
    /// この副作用を避けるためで、理由がここに書いていないと次に読む人が
    /// 「なぜ全部塗らないのか」と思って戻してしまう。
    static let all: [RotoFaceTransition] = [
        // ── PLUGIN 面へ（通知あり = 確認できる） ──────────────
        RotoFaceTransition(
            trigger: "FUNC キーを押す", target: "PLUGIN", notification: "0B 01",
            origin: .human, provenance: .measured("2026-08-06")),
        RotoFaceTransition(
            trigger: "SEL キーを押す", target: "PLUGIN", notification: "0B 01",
            origin: .human, provenance: .measured("2026-08-04")),
        RotoFaceTransition(
            trigger: "selectFace(.plugin) を送る", target: "PLUGIN", notification: "0B 01",
            origin: .host, provenance: .measured("2026-08-07")),

        // ── MIX 面へ（通知あり） ─────────────────────────────
        RotoFaceTransition(
            trigger: "MIX を選ぶ", target: "MIX", notification: "0C 02",
            origin: .human, provenance: .measured("2026-08-03")),
        // ⚠️ **ホストの送信が面を動かす**。これが「MIX から出られない」の正体だった
        RotoFaceTransition(
            trigger: "0A 11（トラックセル）を送る", target: "MIX", notification: "0C 02",
            origin: .host, provenance: .measured("2026-08-04")),

        // ── SMART 面へ（⚠️ 通知が無い = 永久に推定） ──────────
        RotoFaceTransition(
            trigger: "selectFace(.smart) を送る", target: "SMART", notification: nil,
            origin: .host, provenance: .measured("2026-08-04")),
        // ⚠️ **デバイスが自分で戻る**。FUNC の引き戻しが効かないのに
        // 「キーを押すと戻る」のはこれ（実測 2026-08-07）。
        // 通知が無いので**戻ったことをホストは知りようがない**
        RotoFaceTransition(
            trigger: "デバイスが自分で戻る（キー押下後など）", target: "SMART", notification: nil,
            origin: .device, provenance: .measured("2026-08-07")),

        // ── 効かないもの（**残す**。次の人が試して同じ道を通らないように） ──
        RotoFaceTransition(
            trigger: "MODE キーを押す", target: "（Logic では効かない）", notification: nil,
            origin: .human, provenance: .measured("2026-08-04")),
        RotoFaceTransition(
            trigger: "ピッカー中の selectFace(.smart) 引き戻し", target: "（無視される）",
            notification: nil, origin: .host, provenance: .measured("2026-08-07")),
    ]

    /// 通知があるので**確認に昇格できる**遷移
    static var confirmable: [RotoFaceTransition] { all.filter(\.isConfirmable) }

    /// ⚠️ **通知が無い = 永久に推定のままの遷移**。ここが多いほど
    /// 「画面の面」と「実機の面」がズレる余地がある
    static var unconfirmable: [RotoFaceTransition] { all.filter { !$0.isConfirmable } }

    static var measuredCount: Int { all.filter(\.provenance.isMeasured).count }

    /// ⚠️ **ページ選択に使える入力は、この機材にはもう無い**（実測 2026-08-07）。
    ///
    /// `roto-plugin-probe` で SMART 面・PLUGIN 面の両方を洗った結果:
    ///
    /// | 入力 | 結果 |
    /// |---|---|
    /// | **RK1-8**（LCD 下の物理キー）| **両面とも無反応**（面依存ではなく個体の性質） |
    /// | ← → | **両面とも無反応** |
    /// | ノブ回転 | パラメータで使用中 |
    /// | ノブ**押し込み** | ⚠️ **物理的に存在しない**（mako 実機確認 2026-08-07）。 |
    /// | | ベンチが「2 通」と拾ったのは、押そうとして触れたのを**触覚が拾った**もの |
    /// | ノブ接触（ch15 CC64-71） | ⚠️ **使ってはいけない** — 静電容量なので |
    /// | | **演奏中に指がかすっただけでページが飛ぶ** |
    ///
    /// よって**ページ選択は FUNC ピッカー + Keystage の PLAY/STOP**
    /// （`ef2ef69`）で確定。他に選択肢が無いことが測定で確定した。
    /// **「PLUGIN 面へ行けば選べるようになる」という見通しも消えている**
    static let noSpareInputs = true
}

/// **面の状態と、その確からしさ**。
///
/// ⚠️ **`RotoService.currentFace` を置き換えない。** あれは
/// `paintsSmartCells` / `paintsTrackCells` を握っていて送信内容を決めている。
/// こちらは**観測専用**で、送信には一切影響しない
enum FaceBelief: Equatable {
    /// デバイスの通知（`0B 01` / `0C 02`）を受けた = **実機がそう言った**
    case confirmed(String, since: Date)
    /// こちらが送っただけ = **反証待ち**。⚠️ SMART はここから出られない
    case assumed(String, since: Date)
    /// まだ何も分からない
    case unknown

    var faceLabel: String {
        switch self {
        case .confirmed(let face, _), .assumed(let face, _): return face
        case .unknown: return "不明"
        }
    }

    var since: Date? {
        switch self {
        case .confirmed(_, let date), .assumed(_, let date): return date
        case .unknown: return nil
        }
    }

    var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }

    /// ⚠️ **「推定」であることが読めること自体が価値**（mako 要望 2026-08-07）。
    /// 「SMART（推定・42 秒）」と出ていれば、実機を見て食い違いに気づける
    func summary(now: Date = Date()) -> String {
        switch self {
        case .confirmed(let face, let date):
            return "\(face)（確認・\(Self.age(from: date, to: now))）"
        case .assumed(let face, let date):
            return "\(face)（⚠️ 推定・\(Self.age(from: date, to: now))）"
        case .unknown:
            return "不明（まだ面を受けていない）"
        }
    }

    static func age(from: Date, to: Date = Date()) -> String {
        let seconds = Int(max(0, to.timeIntervalSince(from)))
        if seconds < 60 { return "\(seconds) 秒" }
        if seconds < 3600 { return "\(seconds / 60) 分" }
        return "\(seconds / 3600) 時間"
    }

    /// **推定が覆されたか** — 純関数（テスト対象）。
    ///
    /// ⚠️ **これが昨日欠けていた警報**。推定 SMART の最中に `0B 01` が来たら、
    /// 「ladyland は SMART だと思っていたが実機は PLUGIN だった」ということ。
    /// FUNC の引き戻しが無視されていたのに誰も気づかなかったのはこれが無かったため。
    ///
    /// - Returns: 食い違っていれば人が読める説明。合っていれば `nil`
    static func contradiction(_ belief: FaceBelief, observed: String, now: Date = Date())
        -> String?
    {
        switch belief {
        case .assumed(let face, let date) where face != observed:
            return "⚠️ 推定と実機が食い違った（推定 \(face) / 実機 \(observed)、"
                + "推定してから \(age(from: date, to: now))）"
        case .confirmed(let face, let date) where face != observed:
            // 確認済みからの遷移は正常（人が面を移した）— 警報ではない
            _ = date
            return nil
        default:
            return nil
        }
    }
}
