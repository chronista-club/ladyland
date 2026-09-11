//! ROTO-CONTROL の「パラメータ番号 ⇄ MIDI 位置」変換と、面ごとのセル上限。
//!
//! RotoService から切り出した**純粋層**（状態を持たない = テストで直に叩ける）。
//! 送信も受信もしない — 番号の意味だけを知っている。

import Foundation

/// パラメータ番号 ⇄ MIDI 位置の変換 — 純関数（テスト対象）。
///
/// **ページはデバイスが持つ**（実測 2026-08-03）。ホストは「全パラメータの地図」を
/// 渡すだけで、← → を押すとデバイスが自分で窓をずらし、**絶対パラメータ番号**で
/// 喋り始める（ページ変更の通知は無い — 番号が変わることがページ変更の表現）。
///
/// 配置は config.lua の動的生成規則:
///   param N → ch `0xBE − N/32`、CC `N%32`(MSB) / `+0x20`(LSB) / `+0x40`(touch)
/// **ROTO の物理部品の呼び名**（mako 制定 2026-08-07。
/// Creo 正典 `mem_1Cdo2L8auf2eDL78iUnvbg`）。
///
/// | 略 | 正式 | 実体 |
/// |---|---|---|
/// | **K1**〜**K8** | Knob 1-8 | **ノブ**（回す・触覚センサー付き・モーター駆動）|
/// | **RK1**〜**RK8** | **ROTO-KEY1**〜8 | **物理キー**（LCD の真下の 8 個）|
///
/// ⚠️ **日本語だと両方「キー」と呼べてしまい、実際に取り違えが起きた。**
/// 性質は正反対:
///
/// - **K1-8 は喋る** — 回転も触覚も ch15 CC が届く。モーターで動かせる
/// - **RK1-8 は喋らない** — ⚠️ **この個体ではどの面でも MIDI を 1 通も出さない**
///   （実測 2026-08-07。`RotoParam.decodeButton` に否定の記録）
///
/// ⚠️ **ノブの触覚（ch15 CC64-71）を RK と誤認しないこと** — 一度
/// 「CC64-71 = 8 キー」と読み違えて配線しかけた（`decodeButton` の doc）。
enum RotoParam {
    /// 1 チャンネルに載るパラメータ数
    static let perChannel = 32

    enum Kind: Equatable { case msb, lsb, touch }

    /// 受信した (status, cc) を絶対パラメータ番号と種別に解く。
    /// 解けなければ nil（param 面ではない CC）
    static func decode(status: UInt8, cc: UInt8) -> (param: Int, kind: Kind)? {
        // ch16(0xBF) は MIX 面。param 面は 0xBE(ch15) から下へ 8 本
        guard status <= 0xBE, status >= 0xB7 else { return nil }
        let base = Int(0xBE - status) * perChannel
        switch Int(cc) {
        case 0..<32: return (base + Int(cc), .msb)
        case 32..<64: return (base + Int(cc) - 32, .lsb)
        case 64..<96: return (base + Int(cc) - 64, .touch)
        default: return nil
        }
    }

    /// Bitwig/Ableton 方言のノブ配置（protocol.md「入力」）:
    /// **ch16 (0xBF) の CC12-19 = MSB / 44-51 = LSB / 52-59 = touch**。
    ///
    /// Logic 方言（`decode`）と違い**物理 8 本に固定**で、絶対セル番号では来ない。
    /// いまどのセルを触っているかは、直近の CONTROL_MAPPED が教えたページで決まる
    /// （ページを繰るとデバイスは新しい 8 セルを聞き直してくる）
    static func decodeKnob(status: UInt8, cc: UInt8) -> (knob: Int, kind: Kind)? {
        guard status == 0xBF else { return nil }
        switch Int(cc) {
        case 12..<20: return (Int(cc) - 12, .msb)
        case 44..<52: return (Int(cc) - 44, .lsb)
        case 52..<60: return (Int(cc) - 52, .touch)
        default: return nil
        }
    }

    /// **LCD の真下に並ぶ 8 個のボタン** = ch16 (0xBF) の CC20-27。
    ///
    /// ## 根拠（`docs/roto-control/protocol.md`）
    ///
    /// Logic 方言の「多チャンネル CC 配置（config.lua の動的生成規則、実測一致）」に
    /// **ch16 = 主: MIX knob 12-19/44-51、MIX touch 52-59、`button 20-27`、
    /// transport 28-35、meter 65+** とある。`button 20-27` は MIX 専用の行では
    /// なく、**面をまたいだ物理ボタン**として並んでいる。
    ///
    /// ⚠️ **ch15 の CC64-71 と取り違えないこと。** あちらは同じ表の隣の行
    /// （`ch15 → param N は CC N%32 / +0x20 / touch +0x40`）で、
    /// **ノブの静電容量タッチ**である。protocol.md の
    /// 「物理 8 knob（SMART 面）= param 0-7 = ch15 の CC0-7 / 32-39、**touch 64-71**」
    /// が直接そう書いている。**指が触れただけで発火する**ので入力には使えない
    /// （`decode` の `case 64..<96: .touch` は正しい。誤当てではない）。
    ///
    /// touch が 2 か所（ch16 の 52-59 / ch15 の 64-71）に出るのは**面が違う**から。
    /// 52-59 は MIX 面のノブ、64-71 は SMART/PLUGIN 面のノブ。
    ///
    /// ## ⭐ **RK は MIX 面でだけ喋る**（実測 2026-08-11 で確定 — 面の条件付き）
    ///
    /// | 面 | RK1-8 の送信 |
    /// |---|---|
    /// | SMART / PLUGIN | **沈黙**（2026-08-07 の「飛ばない」はこの面で測っていた） |
    /// | **MIX** | ⭐ **ch16 CC20-27 で押下 127 / 解放 0**（2026-08-11 mako 実測） |
    ///
    /// 2026-08-07 の否定測定は**誤りではなく条件不足**だった — 「否定測定は
    /// 条件ごと記録せよ」（Creo の教訓）の実例。protocol.md の `button 20-27`
    /// は MIX 面の話として正しかった。
    ///
    /// ⭐ **これが現在のページ直選の入口**（mako 裁定 2026-08-11「全部オミット
    /// して、RK1-8 使う方式に」）。実機側も MIX で Track 選択 → RK でその
    /// プラグインのページへ飛び、選択中ページのキーをトラック色で光らせる —
    /// こちらは信号を Transform して内部ページを追従させるだけ
    static func decodeButton(status: UInt8, cc: UInt8) -> Int? {
        guard status == 0xBF, (20..<28).contains(Int(cc)) else { return nil }
        return Int(cc) - 20
    }

    /// 物理ノブの本数（どちらの方言でも 8 本）
    static let physicalKnobs = 8

    /// 面ごとのセル上限（実測 2026-08-03。protocol.md「3 つの面と、それぞれの上限」）。
    ///
    /// 空セルにも Ctrl 番号を書いて埋めるのは変わらない — 空文字ラベルでは
    /// LCD が消えず、前の表示のまま迷子になる（実測）。ただし**上限より先へは
    /// 届かない**ので、そこまでで打ち切る。
    ///
    /// ⚠️ ここを 128 にしていたときは、モード切替のたびに 128 通
    /// （5ms ペーシングで **640ms**）が送信キューを埋め、**その後ろで learn と
    /// hello の応答が待たされていた**。応答義務のあるメッセージを一括投影の
    /// 人質にしない、が要点（protocol.md の VU メーター節に同型の先例）
    static let smartCells = 16
    /// PLUGIN 面 = 8 ノブ × 8 ページ。ラベルは learn 応答で付くので投影は不要だが、
    /// モーターはこの範囲まで動く
    static let pluginCells = 64
    /// MIX 面 = 16 トラック。⚠️ **ladyland のラック（24 スロット）より狭い**。
    /// ここを超えて `0A 11` を書くとデバイスが固まる（実測 2026-08-03: 24 席を
    /// 宣言して 0-23 へ書き込み、MIX 面を選んだ瞬間に停止）
    static let mixCells = 16

}
