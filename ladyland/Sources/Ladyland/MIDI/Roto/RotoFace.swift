//! **面ごとの規則**を 1 箇所に集めた場所。
//!
//! ROTO は 3 つの面（MIX / SMART / PLUGIN）を持ち、面が変わると
//! 「何を塗ってよいか」も「ノブ入力が何を意味するか」も変わる。
//! その規則が投影・入力・モーターの 3 箇所に散っていると、片方だけ直して
//! 壊す（実際に「MIX から出られない」で踏んだ）。
//!
//! ここに書いてあるのは**実測で得た制約**であって、設計の好みではない。

import Foundation

extension RotoService {
    /// ROTO がいま表示している面。
    ///
    /// ⚠️ **ノブ入力の意味は面で変わる**。Bitwig 方言では MIX 面も PLUGIN 面も
    /// 同じ ch16 CC12-19 を使い、MIX 面ではトラックボリューム、PLUGIN 面では
    /// パラメータを意味する。面を見ずに AU へ書き込むと、**MIX 面でノブを
    /// 触っただけで音色が壊れる**（実測 2026-08-04: slot 0 の knob 0 =
    /// Pitch Bend が書き換わり、常時保存が毎秒走って音が出なくなった）
    enum Face {
        /// ⚠️ **`.smart` は 2026-08-04 に足した**。それまで SMART 面を表す値が
        /// 無く、`Roto.selectFace(.smart)` を送っても `currentFace` は
        /// `.unknown` か `.mix` のままだった。結果:
        ///   - `.mix` のとき（`0C 02` を一度でも受けた後）**SMART 面のラベル
        ///     投影が恒久的に死ぬ** — `paintsSmartCells` が false になるため
        ///   - `.unknown` のとき **SMART 面に `0A 11` を 16 通撃つ** —
        ///     このファイル自身が禁じている「MIX 面のセル更新でデバイスが
        ///     移動する」をホストが自分でやっていた
        case plugin, smart, mix, unknown

        /// 画面に出す名前（診断用。`RotoInspection`）
        var label: String {
            switch self {
            case .plugin: return "PLUGIN"
            case .smart: return "SMART"
            case .mix: return "MIX"
            case .unknown: return "不明（まだ面を受けていない）"
            }
        }

        // MARK: - いる面だけ塗る

        /// MIX 面のトラックセル（`0A 11`）を塗ってよいか。
        ///
        /// ⚠️ **いる面だけ塗る**（実測 2026-08-04）。Logic 方言では MIX 面の
        /// セル更新（0A 11）を送るとデバイスが MIX 面へ移動してしまい、
        /// SMART / PLUGIN 面から MODE キーで抜けられなくなる。
        /// 両面を毎回塗っていたのが「MIX から出られない」の正体
        /// ⚠️ `.smart` を含めない — SMART 面に居る最中に `0A 11` を送ると
        /// デバイスが MIX 面へ移動する。`!= .plugin` と書いていたときは
        /// SMART 面も素通しだった（2026-08-04 修正）
        var paintsTrackCells: Bool { self == .mix || self == .unknown }

        /// SMART 面のノブセル（`0B 13`）と MENU 窓（`0A 16`）を塗ってよいか。
        /// 上と対になる規則 — MIX 面に居るあいだはノブ側を触らない
        var paintsSmartCells: Bool { self != .mix }

        // MARK: - いる面のノブだけ効く

        /// ノブ入力とモーター出力が **PLUGIN 面のパラメータ**を指しているか。
        ///
        /// Bitwig 方言でだけ意味を持つ（Logic 方言は ch15 / ch16 で面が
        /// 分離しているので、そもそも取り違えが起きない）。
        /// 呼ぶ側は `RotoDialect.knobInputSharedAcrossFaces` と合わせて見ること
        var drivesPluginKnobs: Bool { self == .plugin }
    }
}
