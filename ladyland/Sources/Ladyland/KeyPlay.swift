//! PC キーボード演奏モード（mako 依頼 2026-08-09「機材がついていない状態で
//! 起動して音が出るようにしたい — 機材が繋がってなくても、動かして見せる」）。
//!
//! ## レイアウト = cortex の演奏モードをそのまま（`src/main.rs:880-978`）
//!
//! **A 行 = 白鍵 / W 行 = 黒鍵 / Z・X = オクターブ**。mako の手が既に
//! 覚えている配置（`CLAUDE.md` cortex 操作表「Tab | 演奏モード切替」）。
//!
//! ```text
//!   W E   T Y U   O P        ← 黒鍵（C# D#  F# G# A#  C# D#）
//!  A S D F G H J K L ;       ← 白鍵（C D E F G A B  C D E）
//! ```
//!
//! ## ⚠️ キーごとに「押したときのノート番号」を覚える
//!
//! オクターブを**押しっぱなしの最中に**変えると、キーを離したとき
//! 「今のオクターブで計算したノート」に Note Off を送ってしまい、
//! **元のノートが鳴りっぱなしになる** — cortex が踏み抜いた罠
//! （`pressed_note_keys`）。Note Off は必ず**押下時に覚えた番号**へ。
//!
//! ## ⚠️ キーリピートは呼ぶ側で捨てる
//!
//! `NSEvent.isARepeat` は UI 層にしか無い。ここは二重押下（既に pressed に
//! 居るキー）を nil で弾くが、**リピート捨ての本務は `handleKey` 側**。

import Foundation

/// 純状態機械 — NSEvent を知らない（テスト対象）
struct KeyPlay {
    /// オクターブ（4 = 中央。A キー = C4 = MIDI 60）
    private(set) var octave = 4

    /// 押下中のキー → **押したときの**ノート番号（Note Off はこれへ）
    private(set) var pressed: [UInt16: UInt8] = [:]

    /// keyCode → 半音オフセット（A = 0 = C）。US/JIS の物理配列で共通
    static let semitoneOffsets: [UInt16: Int] = [
        0: 0,  // A = C
        13: 1,  // W = C#
        1: 2,  // S = D
        14: 3,  // E = D#
        2: 4,  // D = E
        3: 5,  // F = F
        17: 6,  // T = F#
        5: 7,  // G = G
        16: 8,  // Y = G#
        4: 9,  // H = A
        32: 10,  // U = A#
        38: 11,  // J = B
        40: 12,  // K = C+1
        31: 13,  // O = C#+1
        37: 14,  // L = D+1
        35: 15,  // P = D#+1
        41: 16,  // ; = E+1
    ]

    /// Z / X のオクターブ移動（cortex と同じ）
    static let octaveDownKey: UInt16 = 6  // Z
    static let octaveUpKey: UInt16 = 7  // X

    /// 演奏キーなら Note On すべき番号を返す（違うキー・二重押下・音域外は nil）
    mutating func keyDown(_ keyCode: UInt16) -> UInt8? {
        guard let offset = Self.semitoneOffsets[keyCode], pressed[keyCode] == nil else {
            return nil
        }
        let note = (octave + 1) * 12 + offset
        guard (0...127).contains(note) else { return nil }
        pressed[keyCode] = UInt8(note)
        return UInt8(note)
    }

    /// 押下中の演奏キーなら Note Off すべき番号を返す（**押下時の番号**）
    mutating func keyUp(_ keyCode: UInt16) -> UInt8? {
        pressed.removeValue(forKey: keyCode)
    }

    /// オクターブを動かす（0-8 で止める。⚠️ 押下中のノートは動かさない —
    /// `pressed` が押下時の番号を覚えているので、離せば正しく消える）
    mutating func shiftOctave(_ delta: Int) {
        octave = max(0, min(8, octave + delta))
    }

    /// モードを抜けるとき全部消音するための一覧（返してから空にする）
    mutating func releaseAll() -> [UInt8] {
        let notes = Array(pressed.values)
        pressed.removeAll()
        return notes
    }
}
