//! ROTO-CONTROL **MIDI モード**の setup 文書（ROTO-SETUP の Export/Import All 互換）。
//!
//! MIDI モードは DAW セッション機構（握手・宣言・フラッシュ）を丸ごと回避できる
//! 本線（mako 発案 2026-08-11 深夜）。設定は SysEx ではなく **ROTO-SETUP アプリの
//! バックアップ JSON** で焼く — Export All が吐く
//! `ROTO-CONTROL <日時>/MIDI/SETUP NN.json` と同じ形を作れば Import All で入る。
//!
//! フォーマットは実機 Export の実物（docs/roto-control/backups/）から確定:
//! - 4 スペースインデント、フィールド順固定、末尾改行なし
//! - `colorScheme` は DAW モードと同じ **83 色パレットの index** と見ている
//!   （Export 実物の未編集ノブが 70 = `Color.black`「未割当セルの地」と一致）
//! - `stepNames` は常に 16 要素（haptic のステップ名。使わなくても空文字で埋まる）
//!
//! ⚠️ `controlMode` の値の意味（CC / NRPN / 14bit?）は未確認。実物の 0 を既定に
//! する。ROTO-SETUP で 1 ノブだけ設定を変えて Export した差分で解読できるはず。

import Foundation

public enum RotoMidiSetup {
    /// ノブ 1 本の設定（Export JSON の 1 要素）
    public struct Knob {
        /// 物理ノブの位置（0-7）
        public let controlIndex: Int
        /// 送信 MIDI チャンネル（1-16）
        public let channel: Int
        /// 送信 CC 番号（0-127）
        public let cc: Int
        /// ノブ LCD に出る名前（Export 実物の既定は "CH:1/CC:0" 形式だった）
        public let name: String
        /// `Roto.Color.palette` の index（と見ている — 上記ヘッダ参照）
        public let colorScheme: UInt8

        public init(controlIndex: Int, channel: Int, cc: Int, name: String, colorScheme: UInt8) {
            self.controlIndex = controlIndex
            self.channel = channel
            self.cc = cc
            self.name = name
            self.colorScheme = colorScheme
        }
    }

    /// setup 1 冊分の JSON 文書（Export All 互換、バイト単位で同形）。
    ///
    /// ボタン 1 個の設定（PUSH = 押下 ON 値 / 離し OFF 値、TOGGLE = 押すたび交互）。
    /// LED は実機ローカル — 外から CC を送っても動かない（実測 2026-08-12）
    public struct Button {
        public let controlIndex: Int
        public let channel: Int
        public let cc: Int
        public let name: String
        /// ボタン LCD の地色（83 色パレット index）
        public let colorScheme: UInt8
        public let ledOn: UInt8
        public let ledOff: UInt8
        public let toggle: Bool

        public init(
            controlIndex: Int, channel: Int, cc: Int, name: String,
            colorScheme: UInt8, ledOn: UInt8, ledOff: UInt8, toggle: Bool
        ) {
            self.controlIndex = controlIndex
            self.channel = channel
            self.cc = cc
            self.name = name
            self.colorScheme = colorScheme
            self.ledOn = ledOn
            self.ledOff = ledOff
            self.toggle = toggle
        }
    }

    /// Swift の JSONEncoder はキー順を握れない（alphabetical か不定）ので手組みする。
    /// Import 側が順序を見ない可能性は高いが、**実機 Export と diff できる**ことが
    /// 解読の道具として効く — 形を寄せない理由がない。
    /// ⚠️ buttons の JSON 欄構成は Export 実物未採取（公式 payload.mjs の
    /// makeNewMidiButtonConfig 準拠）— Import で使う前に一度 Export と突合する
    public static func document(
        name: String, index: Int, knobs: [Knob], buttons: [Button] = []
    ) -> String {
        var lines: [String] = []
        lines.append("{")
        lines.append("    \"version\": 1,")
        lines.append("    \"type\": \"MIDI\",")
        lines.append("    \"name\": \"\(escape(name))\",")
        lines.append("    \"index\": \(index),")
        if knobs.isEmpty {
            lines.append("    \"knobs\": [],")
        } else {
            lines.append("    \"knobs\": [")
            for (position, knob) in knobs.enumerated() {
                let last = position == knobs.count - 1
                lines.append("        {")
                lines.append("            \"controlIndex\": \(knob.controlIndex),")
                lines.append("            \"controlMode\": 0,")
                lines.append("            \"controlChannel\": \(knob.channel),")
                lines.append("            \"controlParam\": \(knob.cc),")
                lines.append("            \"nrpnAddress\": 0,")
                lines.append("            \"minValue\": 0,")
                lines.append("            \"maxValue\": 127,")
                lines.append("            \"controlName\": \"\(escape(knob.name))\",")
                lines.append("            \"colorScheme\": \(knob.colorScheme),")
                lines.append("            \"hapticMode\": 0,")
                lines.append("            \"hapticIndent1\": 255,")
                lines.append("            \"hapticIndent2\": 255,")
                lines.append("            \"hapticSteps\": 0,")
                lines.append("            \"stepNames\": [")
                for step in 0..<16 {
                    lines.append("                \"\"\(step == 15 ? "" : ",")")
                }
                lines.append("            ]")
                lines.append("        }\(last ? "" : ",")")
            }
            lines.append("    ],")
        }
        if buttons.isEmpty {
            lines.append("    \"buttons\": []")
        } else {
            lines.append("    \"buttons\": [")
            for (position, button) in buttons.enumerated() {
                let last = position == buttons.count - 1
                lines.append("        {")
                lines.append("            \"controlIndex\": \(button.controlIndex),")
                lines.append("            \"controlChannel\": \(button.channel),")
                lines.append("            \"controlParam\": \(button.cc),")
                lines.append("            \"nrpnAddress\": 65535,")
                lines.append("            \"minValue\": 0,")
                lines.append("            \"maxValue\": 127,")
                lines.append("            \"controlName\": \"\(escape(button.name))\",")
                lines.append("            \"colorScheme\": \(button.colorScheme),")
                lines.append("            \"ledOnColor\": \(button.ledOn),")
                lines.append("            \"ledOffColor\": \(button.ledOff),")
                lines.append("            \"hapticMode\": \(button.toggle ? 1 : 0),")
                lines.append("            \"hapticSteps\": 0,")
                lines.append("            \"stepNames\": [")
                for step in 0..<16 {
                    lines.append("                \"\"\(step == 15 ? "" : ",")")
                }
                lines.append("            ]")
                lines.append("        }\(last ? "" : ",")")
            }
            lines.append("    ]")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// JSON 文字列の最小限のエスケープ（名前は ASCII 前提だが、壊れた文書は作らない）
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
