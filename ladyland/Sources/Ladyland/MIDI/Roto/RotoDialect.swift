//! **方言は名乗り 1 バイト（`dawType`）で全レイヤーが入れ替わる**。
//!
//! ラベル経路・モーターの CC 配置・入力デコードが連動して変わるので、
//! 片方だけ変えると必ず壊れる（2026-08-03 に実測で確定。protocol.md の
//! 「方言は名乗り 1 バイトで全レイヤーが入れ替わる」節）。
//!
//! だからこのファイルは**能力表**にしてある。`dawType == 3` のような裸の
//! 比較を投影・入力・モーターに散らすと、「どちらの方言で何が有効か」が
//! どこにも書かれていない状態になる（散らしていた頃、Logic 方言なのに
//! PLUGIN 面の告知を送り続けてデバイスを PLUGIN 系の状態へ押し込んでいた）。
//!
//! ⚠️ 各能力の実装は**元の裸の比較と同じ述語**をそのまま書いてある
//! （`!= .logic` / `== .logic` / `== .bitwig`）。名前が違っても述語が同じ
//! ものがあるのは、たまたま今の表でそう並んでいるだけ — 揃えて 1 つに
//! まとめないこと。別の方言を足したときに別々に動く

import Foundation

/// 名乗る DAW 種別 = **方言**（1 = Ableton, 2 = Bitwig, 3 = Logic）。
///
/// - 3（Logic）: SMART 面と直接 setter（0A 11 track / 0B 13 knob）が解禁。
///   ただし **PLUGIN 面の pull フローが動かない**（CONTROL_MAPPED が来ない —
///   実測 2026-08-03: 告知と選択宣言を送っても 1 件も返らない）
/// - 2（Bitwig）: PLUGIN 面の learn が効く（64 セル・8 ページ）。ただし
///   **LCD の名前はデバイスの保存名で固定**（2026-08-04 に 4 通り試して全滅）
///
/// **採用: 3（Logic / SMART 面）** — mako 裁定 2026-08-04
/// 「SMART モードをうまく使ってやりたいことを実現させる方が楽」。
/// セル数は 16 に減るが、**`0B 13` でラベルを自由に書ける**方を取る。
/// 割当を変えた瞬間に LCD が追従するのは SMART 面だけ
enum RotoDialect: UInt8 {
    case ableton = 1
    case bitwig = 2
    case logic = 3

    /// 握手で名乗る 1 バイト（`0A 03` の payload）
    var dawType: UInt8 { rawValue }

    // MARK: - 能力表（どちらの方言で何が有効か）

    /// 直接 setter 群（`0A 11` track / `0B 13` knob / `smartMotor` の ch15 CC）が
    /// 使えるか。**投影とモーターの経路がまるごと入れ替わる**。
    ///
    /// ⚠️ これらは config.lua 由来のコマンドで、Bitwig を名乗っている間は
    /// **未定義**になる。実測 2026-08-03: まったく同じ learn を送っても、
    /// RigBench（投影なし）は LCD が変わり、ladyland（投影 32 通）は
    /// 変わらなかった — **未定義コマンドが PLUGIN 面の応答を巻き添えにしている**
    var usesDirectSetters: Bool { self == .logic }

    /// PLUGIN 面の告知（`0B 02`〜`0B 08`）を送るか。
    ///
    /// Logic 方言では PLUGIN 面を使わないのに選択宣言まで送っていて、
    /// デバイスを PLUGIN 系の状態に押し込んでいた疑いがある
    var announcesPlugins: Bool { self != .logic }

    /// **ホストが面を選ぶ**か（ch7 = 0xB6 の CC を押して離す）。
    ///
    /// Logic 方言では MODE キーだけでは SMART へ行けない（実測 2026-08-04:
    /// 種別 3 を名乗って握手しても、MODE キーでは SMART へ行けなかった）
    var hostSelectsFace: Bool { self == .logic }

    /// ノブ入力が**面をまたいで同じ CC を使う**か。
    ///
    /// Bitwig 方言では MIX 面も PLUGIN 面も ch16 CC12-19 を使うので、
    /// 面を見ずに AU へ書き込むと **MIX 面でノブを触っただけで音色が壊れる**。
    /// Logic 方言は ch15 で面が分離しているためこのガードは要らない。
    /// 呼ぶ側は `RotoService.Face.drivesPluginKnobs` と組にして見ること
    var knobInputSharedAcrossFaces: Bool { self == .bitwig }

    // MARK: - 受信デコード（**方言でノブの配置が違う**）

    /// 届いた CC を「どのセルの、どの種別か」に解く。
    ///
    ///   Logic  = ch15 の絶対デバイスセル 0-15 → **現在ページのセル**に写す
    ///   Bitwig = ch16 の物理 8 本 → 表示中のページから解く
    ///
    /// ページの解決は呼ぶ側から渡す（座標変換は `RotoPageLayout`、
    /// 現在ページは `RotoService` が持つ）。
    ///
    /// - Parameters:
    ///   - smartCell: 絶対デバイスセル → SMART 面のセル。**席が無ければ nil**
    ///   - pluginCell: 物理ノブ → PLUGIN 面のセル（表示中ページで解決済み）
    func resolveInput(
        status: UInt8, cc: UInt8,
        smartCell: (Int) -> Int?, pluginCell: (Int) -> Int
    ) -> (param: Int, kind: RotoParam.Kind)? {
        guard usesDirectSetters else {
            return RotoParam.decodeKnob(status: status, cc: cc)
                .map { (pluginCell($0.knob), $0.kind) }
        }
        return RotoParam.decode(status: status, cc: cc)
            .flatMap { decoded -> (param: Int, kind: RotoParam.Kind)? in
                // ⚠️ デバイスは 0-7 を表示しながら 8-15 で喋ることがある。
                // 16 セルをすべて `smartCell` へ渡し、前半・後半をどう写すかは
                // `RotoPageLayout` に一本化する。
                // これを入れるまで 8-15 は `smartCell` を通らず
                // **ctrl 8-15（= P2 付近）へ直行**していた —
                // 「LCD が消えるのに MIDI は生きている」の正体
                guard decoded.param < RotoParam.smartCells else {
                    // ノブ以外（ボタン等）は番号そのまま
                    return (decoded.param, decoded.kind)
                }
                // **セル番号そのままで引く** — 前半・後半の正規化と
                // 席の無いセルの棄却は、渡された座標変換が受け持つ
                guard let cell = smartCell(decoded.param) else { return nil }
                return (cell, decoded.kind)
            }
    }
}
