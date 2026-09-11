//! MIDI ルーティングトレース（design/06 §8 追補、mako 要望 2026-07-31）。
//!
//! 「どの Ctrl から・何が・どこへ」を Debug ウィンドウで追う。
//! MIDIRouter は判断の瞬間に全情報を持っている — そこから RT スレッドで
//! MidiRoute（値型）を発行し、main で名前を足して整形する。
//! 整形は純関数（テスト対象）。連続する同種ストリーム（ノブ CC・AT・PB）は
//! collapse key で 1 行に畳む（ノート類は 1 発ずつ残す）。

/// ルータの判断 1 件（RT スレッド生成 → main で整形）
enum MidiRoute: Sendable, Equatable {
    /// 顔つまみへ横取りされた CC
    case knob(cc: UInt8, value: UInt8)
    /// LPD8 ノブ → ドラムスロットの顔つまみ
    case drumKnob(cc: UInt8, value: UInt8)
    /// LPD8 の PROG 4 パッド → プラグイン選択（音は出さない）
    case padSelect(pad: Int)
    /// Keystage の Rec / Loop（`KeystageControls.pageStep`）→ ROTO のページ送り
    case pageStep(direction: Int)
    /// CC120 = All Sound Off（Keystage の EXIT ボタン）→ panic
    case allSoundOff
    /// VALUE エンコーダー → トラックナビ（歩数。速く回せば 2 以上も来る）
    case nav(direction: Int)
    /// Program Change 由来ナビの基準取り（初回の 1 発は動かさず基準にする）
    case programNavBaseline(value: UInt8)
    /// ノートのキープ（ダンパーペダル）の踏み替え
    case latch(engaged: Bool, released: Int)
    /// キープ中に鍵を離した = Note Off を握りつぶした
    case latchHold(note: UInt8, sustaining: Int)
    /// ch16 の未割当 CC（Value ボタン等の実測特定用）
    case unassignedCh16(cc: UInt8, value: UInt8)
    /// keyboard 経路（選択中スロットへ）
    case keyboard(status: UInt8, data1: UInt8, data2: UInt8, hasTarget: Bool)
    /// drums 経路（LPD8 → ドラムスロットへ）
    case drums(status: UInt8, data1: UInt8, data2: UInt8, hasTarget: Bool)
    /// 鍵盤 2（NCXse）経路 — 入力元ごとの送り先（2nd キーボード計画 ①）。
    /// ⚠️ **Keystage の帯の解釈は通らない** — NCXse の CC0/32/7 は Bank Select
    /// や音量であって席ではない（実測 2026-08-10。同じ番号でも面が違えば別物）
    case secondKeyboard(status: UInt8, data1: UInt8, data2: UInt8, hasTarget: Bool)
}

extension MidiRoute {
    /// Keystage 面で受けた CC 番号（ノブページ推定の材料 —
    /// FaceKnobAssignment.inferredPage に渡す）。
    /// 帯（CC0-63）は**割当の有無に関わらず `.knob` trace を出す**
    /// （監査 2026-08-08 の B-7）ので、未割当ノブでもページが追従する。
    /// 素通し (.keyboard の 0xB0) も材料に拾うが、いま素通しするのは
    /// 帯の外（Mod 116 / Exp 115 / Damper 64 など）だけで、推定側が nil を返す。
    /// ch16（VALUE ボタン等）と LPD8 側は対象外
    var keystageCC: Int? {
        switch self {
        case .knob(let cc, _):
            return Int(cc)
        case .keyboard(let status, let data1, _, _) where status & 0xF0 == 0xB0:
            return Int(data1)
        default:
            return nil
        }
    }
}

enum MidiTraceFormat {
    /// 1 イベント → (collapse key, 表示行)。key が nil なら常に追記、
    /// 同じ key が連続したら最後の行を置き換えて ×N を積む
    static func line(
        _ route: MidiRoute, selectedSlot: String, drumSlot: String,
        secondSlot: String? = nil
    ) -> (key: String?, text: String) {
        switch route {
        case .knob(let cc, let value) where cc == 128:
            return ("knob-pb", "Keystage PB ホイール = \(value) → 顔つまみ")
        case .knob(let cc, let value):
            return ("knob-\(cc)", "Keystage ノブ (CC\(cc)) = \(value) → 顔つまみ")
        case .drumKnob(let cc, let value):
            return ("drumknob-\(cc)", "LPD8 ノブ (CC\(cc)) = \(value) → ドラム顔つまみ")
        case .allSoundOff:
            // 押すたびに残す（畳まない）— 音が止まった理由は履歴で追えないと困る
            return (nil, "CC120 All Sound Off → パニック（全消音）")
        case .pageStep(let direction):
            return (
                nil,
                "Keystage \(direction > 0 ? "Loop" : "Rec") → ROTO ページ"
                    + "\(direction > 0 ? "+" : "-")1"
            )
        case .padSelect(let pad):
            // 押すたびに 1 行残す（畳まない）— どれを選んだかは履歴が要る
            return (nil, "LPD8 PROG4 パッド \(pad + 1) → プラグイン選択")
        case .nav(let direction):
            return (
                "nav",
                "Keystage VALUE エンコーダー → トラックナビ \(direction > 0 ? "+" : "")\(direction)"
            )
        case .programNavBaseline(let value):
            return ("nav-base", "Keystage VALUE エンコーダー = \(value)（基準取り。動かさない）")
        case .latch(let engaged, let released):
            return (
                nil,
                engaged
                    ? "ダンパー踏み込み → ノートをキープ（鍵を離しても鳴り続ける）"
                    : "ダンパーを戻す → キープ解除、\(released) 音を消音"
            )
        case .latchHold(let note, let sustaining):
            return ("latch-hold", "キープ中: note \(note) の Note Off を握りつぶし（計 \(sustaining) 音）")
        case .unassignedCh16(let cc, let value):
            return ("ch16-\(cc)", "Keystage ch16 CC\(cc) = \(value) → 未割当（トラックナビ候補）")
        case .keyboard(let status, let d1, let d2, let hasTarget):
            let dest = hasTarget ? selectedSlot : "(送り先なし)"
            return message(status, d1, d2, from: "Keystage", to: dest)
        case .drums(let status, let d1, let d2, let hasTarget):
            let dest = hasTarget ? drumSlot : "(送り先なし)"
            return message(status, d1, d2, from: "LPD8", to: dest)
        case .secondKeyboard(let status, let d1, let d2, let hasTarget):
            let dest = hasTarget ? (secondSlot ?? selectedSlot) : "(送り先なし)"
            return message(status, d1, d2, from: "鍵盤2", to: dest)
        }
    }

    private static func message(
        _ status: UInt8, _ d1: UInt8, _ d2: UInt8, from source: String, to dest: String
    ) -> (key: String?, text: String) {
        let channel = (status & 0x0F) + 1
        switch status & 0xF0 {
        case 0x90 where d2 > 0:
            return (nil, "\(source) note on \(d1) vel \(d2) (ch\(channel)) → \(dest)")
        case 0x80, 0x90:
            return (nil, "\(source) note off \(d1) (ch\(channel)) → \(dest)")
        case 0xB0:
            return ("cc-\(source)-\(d1)", "\(source) CC\(d1) = \(d2) (ch\(channel)) → \(dest)")
        case 0xA0:
            return ("at-\(source)", "\(source) poly AT \(d1) = \(d2) → \(dest)")
        case 0xD0:
            return ("at-\(source)", "\(source) ch AT = \(d1) → \(dest)")
        case 0xE0:
            return ("pb-\(source)", "\(source) pitch bend → \(dest)")
        case 0xC0:
            return (nil, "\(source) program change \(d1) (ch\(channel)) → \(dest)")
        default:
            return (nil, "\(source) \(hex(status)) \(d1) \(d2) → \(dest)")
        }
    }

    private static func hex(_ v: UInt8) -> String {
        String(format: "0x%02X", v)
    }
}
