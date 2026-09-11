//! Keystage の SysEx 語彙（docs/keystage/README.md §5、`Keystage_MIDIimp.txt`）。
//!
//! ## ⚠️ Arp / Chord は「1 パラメータだけ書く」ができない
//!
//! Func `2B`/`41`（Get Parameter / Parameter Change）は一見すると汎用の
//! パラメータ読み書きに見えるが、**対象は TABLE 3 の 1 行だけ = BPM 専用**
//! （実装チャート L950-956 で確認、2026-08-04）。README が「パラメータは
//! 読み・書き・変更 Push の完全双方向」と書いていたのは誤読。
//!
//! Arp Mode / Chord Set Num などは **TABLE 1（Scene Parameter）** にあり、
//! 触るには Dump しかない:
//!
//! ```
//!   Scene:  10 要求 → 40 で受信 → 該当バイトを書き換え → 40 で送り返す → ACK(23)
//!           永続化は 11（Scene Data Write Request、保存先 0-7）を別途
//!   Global: 0E 要求 → 51 で受信 → 書き換え → 51 で送り返す → ACK(23)
//! ```
//!
//! Dump の中身は **8bit データを 7bit に詰め替えた形**（NOTE 2）。
//! 7 バイトごとに MSB を集めた 1 バイトが先頭に付く 8 バイト単位。

import Foundation

public enum Keystage {
    /// 機種（Member ID）
    public enum Model: UInt8, Sendable {
        case keys49 = 0x01
        case keys61 = 0x09
    }

    /// Func ID（実装チャート L117-124、241-244）
    public enum Func: UInt8, Sendable {
        case sceneDumpRequest = 0x10
        case sceneDump = 0x40
        case globalDumpRequest = 0x0E
        case globalDump = 0x51
        case sceneWriteRequest = 0x11
        case displayMessage = 0x28
        /// 接続 / 切断（Ableton 公式スクリプト方式。payload 01 = 接続 / 00 = 切断）。
        ///
        /// ⚠️ **以下は想定であって実測ではない**（2026-08-07 に明記）。
        /// **Native Mode Enter（Func 01）とは別物** — こちらはノブの CC 割当を
        /// 変えないので 16 ページと両立する、**はず**。
        ///
        /// ⚠️ **実機と食い違っている疑いがある**（mako 実測 2026-08-07）:
        /// 差し直した直後は **PAGE -/+ でノブの組が切り替わる**が、
        /// **ladyland 起動後は反応しなくなる**。犯人はこの `0x6F` か
        /// `controllerModeChange` のどちらか。
        /// `LADYLAND_KEYSTAGE_CONNECT=0` で止めて切り分けられる
        /// （`KeystageService.Handshake`）。
        ///
        /// ⚠️ **Controller Mode はアプリを終了しても機材に居座る** —
        /// ⌘Q だけでは「ladyland の影響が無い状態」にならない。
        /// **切り分けには USB の差し直しが要る**
        case connect = 0x6F
        /// Controller Mode の変更要求（実装チャート L518-531）。
        /// payload 1 byte: `00 = Assignable` / `01 = Logic` / `04 = Ableton Live` …
        ///
        /// ⚠️ **Assignable でないとノブの CC がその DAW の規約に固定される**。
        /// ladyland は独自ホストなので、16 ページの割当が丸ごと壊れる。
        ///
        /// ⚠️ **これも `connect` と並ぶ容疑者**（実測 2026-08-07）。
        /// これが犯人なら **Assignable と PAGE ページ送りは交換条件**で、
        /// 両取りできないことになる。`LADYLAND_KEYSTAGE_ASSIGNABLE=0` で
        /// 止めて切り分ける
        case controllerModeChange = 0x49
        /// 上への応答（実機の現在値を返す）
        case controllerModeChanged = 0x5F
        case ack = 0x23
        case nak = 0x24
        case writeComplete = 0x21
        case writeError = 0x22
    }

    /// `F0 42 4g 00 01 69 mm <len×3 little endian> <Func> <data…> F7`
    ///
    /// len は **Func 1 バイトを含む長さ**（チャートの "(1+n)" 表記）
    public static func frame(
        _ function: Func, data: [UInt8] = [], globalChannel: UInt8 = 0, model: Model = .keys49
    ) -> [UInt8] {
        let length = data.count + 1
        return [0xF0, 0x42, 0x40 | (globalChannel & 0x0F), 0x00, 0x01, 0x69, model.rawValue]
            + [UInt8(length & 0x7F), UInt8((length >> 7) & 0x7F), 0x00]
            + [function.rawValue] + data + [0xF7]
    }

    /// 受信フレームの Func を読む（Keystage 由来でなければ nil）
    public static func function(of bytes: [UInt8]) -> Func? {
        guard bytes.count >= 12, bytes[0] == 0xF0, bytes[1] == 0x42,
            bytes[3] == 0x00, bytes[4] == 0x01, bytes[5] == 0x69
        else { return nil }
        return Func(rawValue: bytes[10])
    }

    /// Dump の生データ部（7bit エンコードされたまま）を切り出す
    public static func payload(of bytes: [UInt8]) -> [UInt8]? {
        guard function(of: bytes) != nil, bytes.count >= 12, bytes.last == 0xF7 else { return nil }
        return Array(bytes.dropFirst(11).dropLast())
    }

    // MARK: - 7bit ⇄ 8bit 詰め替え（NOTE 2）

    /// 8bit → 7bit（送信用）。7 バイトごとに、各バイトの MSB を集めた
    /// 1 バイトを**先頭に**置いた 8 バイト単位にする
    public static func encode7bit(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for chunk in stride(from: 0, to: data.count, by: 7) {
            let slice = data[chunk..<min(chunk + 7, data.count)]
            var msbs: UInt8 = 0
            for (i, byte) in slice.enumerated() where byte & 0x80 != 0 {
                msbs |= UInt8(1 << i)
            }
            out.append(msbs)
            out.append(contentsOf: slice.map { $0 & 0x7F })
        }
        return out
    }

    /// 7bit → 8bit（受信用）。encode7bit の逆
    public static func decode7bit(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for chunk in stride(from: 0, to: data.count, by: 8) {
            let slice = Array(data[chunk..<min(chunk + 8, data.count)])
            guard slice.count >= 2 else { break }
            let msbs = slice[0]
            for (i, byte) in slice.dropFirst().enumerated() {
                out.append(byte | (msbs & UInt8(1 << i) != 0 ? 0x80 : 0))
            }
        }
        return out
    }

    // MARK: - Scene パラメータのオフセット（TABLE 1）

    /// Scene Dump をデコードした 8bit 配列上の位置。
    /// **Arp / Chord はここを書き換えて Dump ごと送り返す**（1 個だけ書く術は無い）
    public enum SceneOffset {
        // Arpeggiator（実装チャート L690-707）
        public static let arpMode = 31  // 0-6
        public static let arpOctave = 32  // 0-3 = 1-4
        public static let arpLatch = 33  // 0/1
        public static let arpKeySync = 34  // 0/1
        public static let arpRate = 35  // 0-11
        public static let arpSwing = 36  // 0-100 (%)
        public static let arpPattern = 37  // 0-20 = Repeat, 1-20
        public static let arpGateTime = 42  // 0-200 = -100%…+100%
        public static let arpVelocity = 45  // 0-127
        public static let arpChance = 46  // 1-100 (%)

        // Chord（L709-713）
        public static let chordSetNum = 47  // 0-63 = Preset01-32, User01-32
        public static let strumTime = 48  // 0-100
        public static let strumDirection = 49  // 0-4

        // Keyboard（L715-719）
        public static let keyboardOctave = 51  // 0-6 = -3…+3
        public static let keyboardTranspose = 52  // 0-24 = -12…+12
    }

    /// **ボタン 9 個の割当**（実装チャート L751-778、Scene Dump 446-499）。
    ///
    /// ⚠️ **ノブと違ってボタンは CC 番号を持てる**。ノブは「CC# は位置で固定」
    /// （ページ p のノブ k = CC (p-1)×8+(k-1)）で動かせないが、ボタンは自由。
    ///
    /// mako 裁定 2026-08-05「こっちで上書きして、Editor で receive します」—
    /// ladyland が Scene Dump に書き込み、KONTROL EDITOR で読んで確認する。
    ///
    /// 1 ボタン 6 バイト:
    /// | +0 | MIDI Ch（0-15 / 16 = Global） |
    /// | +1 | Assign Type（0=NoAssign / 1=CC / 2=Note） |
    /// | +2 | Behavior（0=Toggle / 1=Momentary） |
    /// | +3 | **CC/Note Number** |
    /// | +4 | Off Value |
    /// | +5 | On Value |
    public enum ButtonOffset {
        public static let start = 446
        public static let bytesPerButton = 6

        /// 並び順（チャートの記載順 = Dump 上の順）
        public enum Button: Int, CaseIterable, Sendable {
            case play, stop, rec, loop, tempo, metro, undo, trackDown, trackUp

            public var label: String {
                switch self {
                case .play: return "Play"
                case .stop: return "Stop"
                case .rec: return "Rec"
                case .loop: return "Loop"
                case .tempo: return "Tempo"
                case .metro: return "Metro"
                case .undo: return "Undo"
                case .trackDown: return "Track Down"
                case .trackUp: return "Track Up"
                }
            }
        }

        /// そのボタンの先頭バイト位置
        public static func base(_ button: Button) -> Int {
            start + button.rawValue * bytesPerButton
        }

        // 6 バイトの内訳（base からの相対）
        public static let midiChannel = 0
        public static let assignType = 1
        public static let behavior = 2
        public static let ccNumber = 3
        public static let offValue = 4
        public static let onValue = 5
    }

    /// **エンコーダー 2 つの割当**（実装チャート L727-741、Scene Dump 56-61）。
    ///
    /// VALUE エンコーダーの回転が Play Position（REW / FF）として飛ぶ。
    /// ボタンと同じく **CC 番号を持てる**（ノブ・ホイールと違う）。
    ///
    /// 1 つ 3 バイト:
    /// | +0 | MIDI Ch（0-15 / 16 = Global） |
    /// | +1 | Assign Type（0=NoAssign / 1=CC / 2=Note） |
    /// | +2 | **CC/Note Number** |
    public enum EncoderOffset {
        public static let start = 56
        public static let bytesPerEncoder = 3

        public enum Encoder: Int, CaseIterable, Sendable {
            case rewind, forward

            public var label: String {
                switch self {
                case .rewind: return "REW"
                case .forward: return "FF"
                }
            }
        }

        public static func base(_ encoder: Encoder) -> Int {
            start + encoder.rawValue * bytesPerEncoder
        }

        public static let midiChannel = 0
        public static let assignType = 1
        public static let ccNumber = 2
    }

    /// **ladyland 用のエンコーダー割当**（mako 指定 2026-08-05「Encoder は
    /// 117-118 にしよう」）。ボタン群と同じく後ろへ寄せる
    public static let ladylandEncoderCCs: [(EncoderOffset.Encoder, UInt8)] = [
        (.rewind, 117),
        (.forward, 118),
    ]

    /// エンコーダーの現在の CC を読む（Assign Type が CC でなければ nil）
    public static func encoderCC(
        _ dump: [UInt8], _ encoder: EncoderOffset.Encoder
    ) -> UInt8? {
        let base = EncoderOffset.base(encoder)
        guard dump.indices.contains(base + EncoderOffset.ccNumber) else { return nil }
        guard dump[base + EncoderOffset.assignType] == 1 else { return nil }
        return dump[base + EncoderOffset.ccNumber]
    }

    /// エンコーダーを「CC を送る」設定に書き換える
    public static func settingEncoder(
        _ dump: [UInt8], _ encoder: EncoderOffset.Encoder, cc: UInt8
    ) -> [UInt8] {
        let base = EncoderOffset.base(encoder)
        guard dump.indices.contains(base + EncoderOffset.ccNumber) else { return dump }
        var out = dump
        out[base + EncoderOffset.assignType] = 1  // CC
        out[base + EncoderOffset.ccNumber] = cc
        return out
    }

    /// Controller Mode の値（実装チャート L628-639）
    public enum ControllerMode: UInt8, Sendable {
        case assignable = 0x00
        case logic = 0x01
        case garageBand = 0x02
        case ableton = 0x04
        case flStudio = 0x05
        case cubase = 0x06
        case studioOne = 0x07
        case digitalPerformer = 0x09
        case proTools = 0x10
        case cakewalk = 0x11

        public var label: String {
            switch self {
            case .assignable: return "Assignable"
            case .logic: return "Logic"
            case .garageBand: return "GarageBand"
            case .ableton: return "Ableton Live"
            case .flStudio: return "FL Studio"
            case .cubase: return "Cubase"
            case .studioOne: return "Studio One"
            case .digitalPerformer: return "Digital Performer"
            case .proTools: return "Pro Tools"
            case .cakewalk: return "Cakewalk"
            }
        }
    }

    /// **ladyland 用のボタン割当**（mako 裁定 2026-08-07 で番号を移した）。
    ///
    /// ## ⚠️ 旧方針は逆向きだった
    ///
    /// 旧: 「CC96-101（NRPN/RPN）と 121-127（Channel Mode）は ladyland が
    /// 『回すと壊れる』として後ろへ回している席で、元から使わない。
    /// そこにボタンを置けば**安全な席が返ってくる**」
    ///
    /// ⚠️ **「ladyland が使っていない席」を「安全な席」と読んでいた。**
    /// その席が空いているのは **MIDI 仕様が予約していて誰も使えないから**で、
    /// 予約は ladyland の都合ではなく**受け取る側すべてに効く**。
    ///
    /// 実測 2026-08-07 — **未割当 CC は楽器へ素通しする**（`MIDIRouter` の
    /// 「割当のない CC はそのまま楽器へ通す」）ので、**AU が仕様どおり
    /// NRPN / RPN / Channel Mode として解釈していた**:
    ///
    /// | | | 実機ログ |
    /// |---|---|---|
    /// | CC98 / 99 | NRPN LSB / MSB | `→ slot 22` |
    /// | CC100 | RPN LSB | `→ slot 5` |
    ///
    /// **98/99 でアドレスを選び 96/97（Data Inc/Dec）で増減する**のが仕様なので、
    /// **AU の任意のパラメータを書き換える完全な手順**が生きていた。
    ///
    /// ⚠️ **`CC120 は使わない` とだけ避けて、隣の 121-123 を使っていた**のが
    /// 見落としだった — **部分的な対処が「全体を点検した」記憶になっていた**。
    ///
    /// ## 新方針: 102-110（仕様で明示的に未定義）
    ///
    /// **受け手が意味を持たない番号へ退避する。** 受け口を信頼するより
    /// **番号自体を無害にする方が守りが厚い** — 受け口が抜けても事故にならない。
    ///
    /// ⚠️ **`Button.allCases` の順に 102 から連番**（mako 裁定 2026-08-07
    /// 「Rec, Loop も Stop と Tempo の間に」）。実機の並びと CC が 1 対 1 で
    /// 揃うので、**次にボタンを足す人がどこへ入れるか迷わない**。
    /// 111-116 は空き（`ladylandEncoderCCs` の 117/118 は据え置き）。
    ///
    /// ⚠️ **横取りは番号ではなく役割で判定する**（`KeystageControls`）。
    /// 今回まさに番号が動いたので、直書きしていたらこの瞬間に保護が外れていた
    public static let ladylandButtonCCs: [(ButtonOffset.Button, UInt8)] = [
        (.play, 102),
        (.stop, 103),
        (.rec, 104),  // ⭐ ROTO のページ −1
        (.loop, 105),  // ⭐ ROTO のページ +1
        (.tempo, 106),
        (.metro, 107),
        (.undo, 108),
        (.trackDown, 109),
        (.trackUp, 110),
    ]

    /// Scene Dump に ladyland の割当を焼く（ボタン 9 個 + エンコーダー 2 つ）
    public static func applyingLadylandButtons(_ dump: [UInt8]) -> [UInt8] {
        let withButtons = ladylandButtonCCs.reduce(dump) { settingButton($0, $1.0, cc: $1.1) }
        return ladylandEncoderCCs.reduce(withButtons) { settingEncoder($0, $1.0, cc: $1.1) }
    }

    /// ボタンの現在の CC 番号を読む（Assign Type が CC でなければ nil）
    public static func buttonCC(_ dump: [UInt8], _ button: ButtonOffset.Button) -> UInt8? {
        let base = ButtonOffset.base(button)
        guard dump.indices.contains(base + ButtonOffset.onValue) else { return nil }
        guard dump[base + ButtonOffset.assignType] == 1 else { return nil }  // 1 = CC
        return dump[base + ButtonOffset.ccNumber]
    }

    /// ボタンを「CC を送る」設定に書き換える。
    ///
    /// **Momentary + Off 0 / On 127** に揃える — ladyland は押した瞬間だけを
    /// 見たいので、Toggle だと状態を持たれて扱いづらい
    public static func settingButton(
        _ dump: [UInt8], _ button: ButtonOffset.Button, cc: UInt8
    ) -> [UInt8] {
        let base = ButtonOffset.base(button)
        guard dump.indices.contains(base + ButtonOffset.onValue) else { return dump }
        var out = dump
        out[base + ButtonOffset.assignType] = 1  // CC
        out[base + ButtonOffset.behavior] = 1  // Momentary
        out[base + ButtonOffset.ccNumber] = cc
        out[base + ButtonOffset.offValue] = 0
        out[base + ButtonOffset.onValue] = 127
        // MIDI Ch は触らない（Global のままにしておく — 実機の設定を尊重する）
        return out
    }

    /// Global Dump 上の User Chord Set の位置（L905-940）。
    /// **12 キー × (Size 1 + Note 8) = 108 バイト**が 1 セット
    public enum GlobalOffset {
        /// User Chord Set 名（6 byte × 32、null terminated）
        public static let userChordSetNameStart = 19
        public static let bytesPerName = 6
        public static let userChordSetDataStart = 211
        public static let keysPerSet = 12
        public static let notesPerKey = 8
        /// 1 キーぶん = Size(1) + Note(8)
        public static let bytesPerKey = 1 + notesPerKey
        public static let bytesPerSet = keysPerSet * bytesPerKey

        /// セット `set`（0-31）のキー `key`（0-11）が始まる位置
        public static func keyOffset(set: Int, key: Int) -> Int {
            userChordSetDataStart + set * bytesPerSet + key * bytesPerKey
        }
    }

    /// Dump の該当バイトを書き換えた新しい配列を返す（純関数 — 元は壊さない）。
    /// 範囲外なら何もしない
    public static func setting(_ data: [UInt8], at offset: Int, to value: UInt8) -> [UInt8] {
        guard data.indices.contains(offset) else { return data }
        var out = data
        out[offset] = value
        return out
    }

    /// User Chord Set の 1 キーぶんの和音を読む（純関数）。
    ///
    /// ⚠️ **Global Dump に入っているのは User セット 32 個だけ**。
    /// Preset（Chord Set Num 0-31）は機器内蔵で Dump に含まれないので読めない。
    /// - Parameter set: **User セットの番号 0-31**（Chord Set Num の 32-63 に対応）
    /// - Returns: ノート番号の配列。空セルなら空配列、範囲外なら nil
    public static func chord(from dump: [UInt8], set: Int, key: Int) -> [UInt8]? {
        let base = GlobalOffset.keyOffset(set: set, key: key)
        guard dump.indices.contains(base + GlobalOffset.bytesPerKey - 1) else { return nil }
        let size = Int(dump[base])
        guard size > 0, size <= GlobalOffset.notesPerKey else { return [] }
        return (0..<size).map { dump[base + 1 + $0] }
    }

    /// User Chord Set の名前を読む（純関数）
    public static func chordSetName(from dump: [UInt8], set: Int) -> String? {
        let base = GlobalOffset.userChordSetNameStart + set * GlobalOffset.bytesPerName
        guard dump.indices.contains(base + GlobalOffset.bytesPerName - 1) else { return nil }
        let bytes = dump[base..<(base + GlobalOffset.bytesPerName)].prefix { $0 != 0 }
        return String(decoding: bytes.filter { (0x20...0x7E).contains($0) }, as: UTF8.self)
    }

    /// User Chord Set の名前を書く（純関数。6 byte に切って 0 終端）
    public static func settingChordSetName(_ dump: [UInt8], set: Int, name: String) -> [UInt8] {
        let base = GlobalOffset.userChordSetNameStart + set * GlobalOffset.bytesPerName
        guard dump.indices.contains(base + GlobalOffset.bytesPerName - 1) else { return dump }
        var out = dump
        let ascii = Array(name.utf8.filter { (0x20...0x7E).contains($0) })
            .prefix(GlobalOffset.bytesPerName - 1)
        for i in 0..<GlobalOffset.bytesPerName {
            out[base + i] = i < ascii.count ? ascii[ascii.startIndex + i] : 0
        }
        return out
    }

    /// User セット間で 12 キーぶんと名前をまるごと写す（純関数）。
    ///
    /// ⚠️ **Preset からは写せない** — Global Dump に入っているのは User 32 個
    /// だけで、Preset は機器内蔵。Preset の中身を User に取り込むには、実機で
    /// Preset を選んで各キーを弾き、鳴った和音を記録するしかない
    /// - Parameters:
    ///   - source: 写し元の **User セット番号 0-31**
    ///   - target: 写し先の User セット番号 0-31
    public static func copyingChordSet(_ dump: [UInt8], from source: Int, to target: Int)
        -> [UInt8]
    {
        guard source != target else { return dump }
        let sourceBase = GlobalOffset.keyOffset(set: source, key: 0)
        let targetBase = GlobalOffset.keyOffset(set: target, key: 0)
        let length = GlobalOffset.bytesPerSet
        guard dump.indices.contains(sourceBase + length - 1),
            dump.indices.contains(targetBase + length - 1)
        else { return dump }

        var out = dump
        out.replaceSubrange(
            targetBase..<(targetBase + length),
            with: dump[sourceBase..<(sourceBase + length)])

        // 名前も一緒に写す（別領域なので個別に）
        let sourceName = GlobalOffset.userChordSetNameStart
            + source * GlobalOffset.bytesPerName
        let targetName = GlobalOffset.userChordSetNameStart
            + target * GlobalOffset.bytesPerName
        if out.indices.contains(sourceName + GlobalOffset.bytesPerName - 1),
            out.indices.contains(targetName + GlobalOffset.bytesPerName - 1) {
            let copied = Array(dump[sourceName..<(sourceName + GlobalOffset.bytesPerName)])
            out.replaceSubrange(
                targetName..<(targetName + GlobalOffset.bytesPerName), with: copied)
        }
        return out
    }

    /// User Chord Set の 1 キーに和音を書く（純関数）。
    /// notes は最大 8 音、超えたぶんは切る
    public static func settingChord(
        _ data: [UInt8], set: Int, key: Int, notes: [UInt8]
    ) -> [UInt8] {
        let base = GlobalOffset.keyOffset(set: set, key: key)
        guard data.indices.contains(base + GlobalOffset.bytesPerKey - 1) else { return data }
        var out = data
        let clipped = Array(notes.prefix(GlobalOffset.notesPerKey))
        out[base] = UInt8(clipped.count)
        for i in 0..<GlobalOffset.notesPerKey {
            out[base + 1 + i] = i < clipped.count ? clipped[i] & 0x7F : 0
        }
        return out
    }
}
