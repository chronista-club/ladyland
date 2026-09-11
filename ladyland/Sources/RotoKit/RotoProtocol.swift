//! ROTO-CONTROL の SysEx 語彙（ladyland 側の一次実装）。
//!
//! 出典（2026-08-03 に一次資料で全面裏取り済み）:
//!   1. ROTO-SETUP.app 同梱の Ableton スクリプト
//!      `/Applications/ROTO-SETUP.app/Contents/Resources/app.asar.unpacked/ableton/ROTO_CONTROL.py`
//!      — 全コマンド定数・hash 実装・recall フローの完全なリファレンス（Python、素で読める）
//!   2. Melbourne 公式 Bitwig 拡張の javap 逆アセンブル（DeviceState.toSysExUpdate ほか）
//!   3. 実機 Export All の JSON（docs/roto-control/backups/）と hash の突合 —
//!      `SHA-1("Phase Plant")[:8] & 0x7F == 290a3e1d09597d01` を確認
//!   （VP doc 20 は先行調査。0B 05 を「name 2 回 + colorIdx」と誤読していたので注意）
//!
//! ⚠️ **握手が済むまで ROTO はモード通知以外を喋らない**（実機確認 2026-08-02）。
//! さらに **hello への応答を止めると切断扱い**になるので、観測中はずっと
//! 応答ループを回し続ける必要がある。
//!
//! フレーム: `F0 00 22 03 02 <type> <id> <payload…> F7`
//!   type 0A = GENERAL（DAW 制御・track・LCD）
//!        0B = PLUGIN（device / parameter learn）
//!        0C = MIXER
//!
//! ## PLUGIN モードの recall フロー（ROTO_CONTROL.py で確定）
//!
//! ```
//! DAW:    0B 02 [台数] → 0B 03 [先頭] → 0B 05 details×N → 0B 06 終了
//! device: （details の hash8 で保存済み割当を照合）
//! device: 0B 0B CONTROL_MAPPED（param番号 + hash6 + knob/switch + control番号 + macro）
//! DAW:    0B 0A LEARN_PARAM で応答（hash6 echo + 現在値 + 表示名）
//!         → ここで初めて LCD 表示 + モーター移動 + knob CC が返り始める
//! ```
//!
//! learn の index14 は **knob 番号ではなくプラグイン内のパラメータ番号**。
//! どの knob に付くかはデバイス側の保存済み割当（or 実機 LEARN 操作）が決める。

import CryptoKit
import Foundation

public enum Roto {
    /// 全メッセージ共通の前置き（F0 + 製造者 ID + 製品 prefix）
    public static let header: [UInt8] = [0xF0, 0x00, 0x22, 0x03, 0x02]

    public static func frame(_ type: UInt8, _ id: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
        header + [type, id] + payload + [0xF7]
    }

    // MARK: - 握手

    /// 握手の口火。これを送ると device が hello を送ってくる
    public static let dawStart = frame(0x0A, 0x01)
    /// hello への応答 1: ping。payload は **DAW 種別**（1 = Ableton, 2 = Bitwig）。
    /// ladyland は Bitwig を名乗る — 実機の検証資産（Phase Plant 割当）が Bitwig 名義のため
    public static let ping = frame(0x0A, 0x03, [0x02])
    /// hello への応答 2: VU メーターの閾値（`SET_MIX_VU_METER_POINTS`）。
    /// **hello には 2 通セットで返す**。
    ///
    /// ⚠️ 以前はここだけ `[0x2F, 0x73]`（47/115）で、`logicInit` の
    /// `meterPoints()`（87/113）と**同じメッセージに別の値**を積んでいた。
    /// 切り分け中に「payload が毎回変わる = セッショントークンか？」と
    /// 誤読させた実害があったので（2026-08-11）、`meterPoints()` に一本化
    public static let meterThreshold = meterPoints()
    /// device からの ROTO_DAW_CONNECTED（02 0A 0C）への応答（Bitwig 拡張の作法）
    public static let inquiryReply = frame(0x0A, 0x0D)

    // MARK: - hash（実機 export と突合検証済み）

    /// `SHA-1(text)` の先頭 count byte を各 `& 0x7F`（MIDI data byte 化）
    public static func hash(_ text: String, count: Int) -> [UInt8] {
        let digest = Insecure.SHA1.hash(data: Data(text.utf8))
        return digest.prefix(count).map { $0 & 0x7F }
    }

    /// parameter 識別 hash（6 byte）。入力は DAW が決める安定 ID —
    /// Ableton は param.name、Bitwig は fullId（パス）。**DAW ごとの名前空間**になる
    public static func hash6(_ fullId: String) -> [UInt8] { hash(fullId, count: 6) }

    /// plugin 識別 hash（8 byte）。Bitwig はプラグイン名そのまま
    /// （検証: "Phase Plant" → 29 0A 3E 1D 09 59 7D 01）。
    /// Ableton は 3rd party のとき 4+4 の合成だが、ladyland は名前 8 byte で良い
    public static func hash8(_ pluginName: String) -> [UInt8] { hash(pluginName, count: 8) }

    // MARK: - 受信の識別

    /// ROTO 由来の SysEx か（他機材の SysEx と混ざらないよう製造者 ID で見る）
    public static func isRoto(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 7 && Array(bytes.prefix(5)) == header
    }

    /// device → DAW の CONTROL_MAPPED（02 0B 0B）。recall の心臓部 —
    /// これを受けたら learn で応答する義務がある
    public struct ControlMapped {
        public let paramIndex: Int  // プラグイン内のパラメータ番号（14bit）
        public let hash6: [UInt8]  // 保存されていた parameter hash
        public let isSwitch: Bool  // 0 = knob, 1 = switch
        public let controlIndex: Int  // どの knob / button に付いたか
        public let isMacro: Bool
    }

    public static func parseControlMapped(_ bytes: [UInt8]) -> ControlMapped? {
        guard isRoto(bytes), bytes.count >= 19, bytes[5] == 0x0B, bytes[6] == 0x0B else {
            return nil
        }
        let data = Array(bytes.dropFirst(7).dropLast())
        guard data.count >= 11 else { return nil }
        return ControlMapped(
            paramIndex: Int(data[0] & 0x7F) << 7 | Int(data[1] & 0x7F),
            hash6: Array(data[2..<8]),
            isSwitch: data[8] == 1,
            controlIndex: Int(data[9]),
            isMacro: data[10] == 1)
    }

    /// 受信 SysEx を人が読める形に。**未知のものは「未知」と明示する** —
    /// 黙って捨てると仕様の穴に気づけない
    public static func describe(_ bytes: [UInt8]) -> String {
        guard isRoto(bytes) else {
            return "（ROTO 以外）\(hex(bytes))"
        }
        let type = bytes[5]
        let id = bytes[6]
        let payload = Array(bytes.dropFirst(7).dropLast())

        switch (type, id) {
        case (0x0A, 0x02):
            return "hello / keepalive（応答が要る）"
        case (0x0A, 0x06):
            return "SET_FIRST_TRACK — track 表示窓のスクロール payload=\(hex(payload))"
        case (0x0A, 0x0C):
            return "ROTO_DAW_CONNECTED → 定型応答 02 0A 0D を返す"
        case (0x0A, 0x0E):
            return "firmware \(firmwareText(payload))"
        case (0x0A, 0x0A):
            return "TRANSPORT モード切替（トグル）"
        case (0x0A, 0x09):
            // knob touch のたびに来る「その track を選べ」
            let index = payload.last.map(Int.init) ?? -1
            return "selectTrack — knob \(index) に触れた → track \(index) を選べ"
        case (0x0A, 0x14):
            return "PAGE ← payload=\(hex(payload))"
        case (0x0A, 0x15):
            return "PAGE → payload=\(hex(payload))"
        case (0x0A, 0x18):
            return "PARAM_VALUES 要求 payload=\(hex(payload))"
        case (0x0B, 0x01):
            return "PLUGIN モードへ"
        case (0x0B, 0x04):
            return "SET_FIRST_DEVICE — plugin 表示窓のスクロール payload=\(hex(payload))"
        case (0x0B, 0x07):
            return "SELECT_DEVICE — device 上で plugin \(payload.last.map(Int.init) ?? -1) を選択"
        case (0x0B, 0x09):
            return "SET_DEVICE_LEARN — 実機 LEARN モード \(payload.first == 1 ? "ON" : "OFF")"
        case (0x0B, 0x0B):
            if let m = parseControlMapped(bytes) {
                return "CONTROL_MAPPED — param#\(m.paramIndex) hash=\(hex(m.hash6)) → "
                    + "\(m.isSwitch ? "button" : "knob") \(m.controlIndex)"
                    + "\(m.isMacro ? " (macro)" : "")【learn で応答せよ】"
            }
            return "CONTROL_MAPPED（短すぎ）payload=\(hex(payload))"
        case (0x0B, 0x0C):
            return "SET_PLUGIN_ENABLE payload=\(hex(payload))"
        case (0x0B, 0x0D):
            return "SET_PLUGIN_LOCK payload=\(hex(payload))"
        case (0x0B, 0x0E):
            return "UNMAP_CTL — 割当クリア payload=\(hex(payload))"
        case (0x0C, 0x01):
            return "MIXER 更新（= initialized の引き金）payload=\(hex(payload))"
        case (0x0C, 0x02):
            return "MIX モードへ payload=\(hex(payload))"
        case (0x0C, 0x05):
            return "SET_MIXER_CHANNEL_MODE payload=\(hex(payload))"
        default:
            return "未知 type=\(pad(type)) id=\(pad(id)) payload=\(hex(payload))"
        }
    }

    /// `02 0A 0E <maj> <min> <patch> <build ASCII…>`
    private static func firmwareText(_ payload: [UInt8]) -> String {
        guard payload.count >= 3 else { return hex(payload) }
        let version = "\(payload[0]).\(payload[1]).\(payload[2])"
        let build = String(decoding: payload.dropFirst(3).filter { $0 >= 0x20 }, as: UTF8.self)
        return build.isEmpty ? version : "\(version) (build \(build))"
    }

    /// hello / 問い合わせに対する定型応答（返すべきものが無ければ空）。
    /// dawType で名乗りを変えられる（1 = Ableton, 2 = Bitwig, 3 = Logic —
    /// **方言が変わる**。3 を名乗ると 0x11+ の直接 setter 群が使える、の検証中）
    public static func autoResponse(to bytes: [UInt8], dawType: UInt8 = 2) -> [[UInt8]] {
        guard isRoto(bytes), bytes.count >= 7 else { return [] }
        switch (bytes[5], bytes[6]) {
        case (0x0A, 0x02): return [frame(0x0A, 0x03, [dawType]), meterThreshold]
        case (0x0A, 0x0C): return [inquiryReply]
        default: return []
        }
    }

    // MARK: - Logic 方言（config.lua 3.2.10 — hash も learn も無い直接 setter 群）

    /// track セル 1 個の直接更新（バッチ枠不要）。`0A 11 <0> <idx> <name13> <color> <0>`
    public static func setTrackDetails(_ index: UInt8, name: String, color: UInt8 = 22) -> [UInt8] {
        frame(0x0A, 0x11, [0, index] + name13(name) + [color, 0])
    }

    /// track セルのクリア。`0A 12 <0> <idx>`
    public static func resetTrackDetails(_ index: UInt8) -> [UInt8] {
        frame(0x0A, 0x12, [0, index])
    }

    /// **MAIN LCD（左の大きい窓）へフォーカストラックを据える**（Logic 方言）。
    /// `0C 0A DAW_SELECT_FOCUS_TRACK` = `<0> <idx> <name13> <RGB6>`
    ///
    /// 公式 `config.lua` L1508-1540 の読み解き（2026-08-05）:
    /// **これを送るまで名前の更新は始まらない**。config.lua は `filter_track_name`
    /// というフラグで自制していて、`0C 0A` を撃った直後にだけ false へ落とす
    /// （コメント: "Once we set up the track name and color we can allow
    /// track name updates via feedback"）。**名前と色を一度セットで据えるのが先**、
    /// 以降の差分は `setMenuText`（`0A 16`）で送る、という二段構え。
    ///
    /// ⚠️ 色は**パレット index ではなく RGB**（`0A 17` と同じ MSB + 下位 7bit の割り方）。
    /// MAIN LCD は 83 色に縛られない
    public static func selectFocusTrack(
        _ index: UInt8, name: String, red: UInt8, green: UInt8, blue: UInt8
    ) -> [UInt8] {
        frame(
            0x0C, 0x0A,
            [0, index] + name13(name) + [
                (red & 0x80) >> 7, red & 0x7F,
                (green & 0x80) >> 7, green & 0x7F,
                (blue & 0x80) >> 7, blue & 0x7F,
            ])
    }

    /// **MAIN LCD の名前だけを更新する**（Logic 方言）。`0A 16 <name13>`
    ///
    /// ⚠️ **payload は名前 13 バイトだけ** — インデックスも前置きも付かない
    /// （`config.lua` L2092-2101 は `bytestring_append(track_details, disp_name)`
    /// しか積んでいない）。8/4 に「LCD が消える」と観測したときは
    /// **`<0> <0>` を 2 バイト余計に付けていた**ので、その解釈違いが原因の可能性が高い。
    ///
    /// 公式は SMART 面でもこれを送る（送らないのは PLUGIN 面で名前が変わらないときだけ）。
    /// ⚠️ ただし `selectFocusTrack` を先に撃つこと — 順序が逆だと公式も送らない
    public static func setMenuText(_ text: String) -> [UInt8] {
        frame(0x0A, 0x16, name13(text))
    }

    /// **MAIN LCD の色だけを更新する**（Logic 方言）。
    /// `0A 17 SET_CURRENT_TRACK_COLOR` = `<RGB6>`
    ///
    /// 公式 `config.lua`（L1685-1702）は `CONTROL_ID_COLOR_0`（Display Color 1）の
    /// フィードバックとして、**SMART / PLUGIN 面**でこれを送る:
    /// ```lua
    /// elseif (controlID == CONTROL_ID_COLOR_0)
    ///     and ((current_mode == MODE_SMART) or (current_mode == MODE_PLUGIN)) then
    /// ```
    ///
    /// ⚠️ **パレットの 83 色に縛られない** — 各色を「MSB 1bit + 下位 7bit」の
    /// 2 バイトに割って送る（SysEx は 7bit しか運べないため）。
    /// **インデックスは付かない**（付くのは兄弟の `0A 13 SET_TRACK_COLOR`）。
    ///
    /// ⚠️ 8/5 に単独で撃って無反応だったが、そのとき **`selectFocusTrack` を
    /// 先に送っていなかった**。公式は「名前と色を `0C 0A` で据えてから差分を送る」
    /// 二段構えなので、据える前の差分は行き先が無かった可能性がある
    public static func setMenuColor(red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
        frame(
            0x0A, 0x17,
            [
                (red & 0x80) >> 7, red & 0x7F,
                (green & 0x80) >> 7, green & 0x7F,
                (blue & 0x80) >> 7, blue & 0x7F,
            ])
    }

    /// パレット index を面の色として塗る（RGB へ展開して送る）
    public static func setMenuColor(paletteIndex: UInt8) -> [UInt8] {
        let rgb = Color.palette[Int(paletteIndex)]
        return setMenuColor(
            red: UInt8((rgb >> 16) & 0xFF),
            green: UInt8((rgb >> 8) & 0xFF),
            blue: UInt8(rgb & 0xFF))
    }

    /// knob LCD へラベルを直接書く（learn 不要、のはず）。`0B 13 <0> <idx> <name13> <color>`
    /// knob LCD へラベルと色を直書きする（SMART 面）。
    ///
    /// ⚠️ **色は 1 つしか受けない**（実測 2026-08-05）。兄弟の
    /// `0A 11 SET_TRACK_DETAILS` が `<color> <0>` と色の後にもう 1 バイト持つので
    /// 2 色目を試したが、**LCD は 2 色にならなかった**（上半分だけが変わる）。
    /// 「下半分をページ固定、上半分をユーザー設定」は成立しない
    public static func setPluginControlDetails(_ index: UInt8, name: String, color: UInt8 = 21)
        -> [UInt8]
    {
        frame(0x0B, 0x13, [0, index] + name13(name) + [color])
    }

    /// SMART/PLUGIN 面のパラメータ CC 配置（Logic 方言、config.lua の動的生成規則）:
    /// param N → ch `0xBE - N/32`、CC `N%32` (MSB) / `+0x20` (LSB)、touch `0x40 + N%32`。
    /// 物理 8 knob = param 0-7 = **ch15 (0xBE) の CC0-7**（実測一致 2026-08-03）。
    /// モーターはこの同じ CC への echo で動かす
    public static func smartMotor(param: Int, value: Double) -> [[UInt8]] {
        let clamped = min(max(value, 0), 1)
        let raw = Int((clamped * 16383).rounded())
        let status = UInt8(0xBE - param / 32)
        let cc = UInt8(param % 32)
        return [
            [status, cc, UInt8((raw >> 7) & 0x7F)],
            [status, cc + 0x20, UInt8(raw & 0x7F)],
        ]
    }

    // MARK: - 色（固定パレット 83 色）

    /// ROTO は**任意 RGB を受け付けない**。83 色の固定パレットの index を
    /// `colorIndex` として渡す。
    ///
    /// 出典: `Roto-Control.bwextension`（Melbourne 公式 Bitwig 拡張）の
    /// `ColorUtil.COLORS` を decompile して抽出（2026-06-12、vantage-point
    /// `roto_palette.rs` 経由で転記）。**index がそのまま `colorIndex`**。
    public enum Color {
        /// index → `0xRRGGBB`（83 色）
        public static let palette: [UInt32] = [
            0xFF94A6, 0xFFA529, 0xCC9926, 0xF6F47D, 0xBFFB00, 0x1EFF2E, 0x28FFA8, 0x5CFFE8,
            0x8BC5FF, 0x5480E4, 0x92A7FF, 0xD86CE4, 0xE553A0, 0xFFFFFF, 0xFF3536, 0xF66C03,
            0x99614B, 0xE1D52D, 0x87FF68, 0x3EC303, 0x02BFAF, 0x18E9FF, 0x0FA4EE, 0x027DC0,
            0x896CE4, 0xB677C6, 0xFF39D4, 0xD0D0D0, 0xE4685A, 0xFFA374, 0xD3AD71, 0xEDFFAE,
            0xD2E498, 0xBAD074, 0x9BC48D, 0xD4FDE1, 0xCDF1F8, 0xB8C1E3, 0xCDBBE4, 0xAE98E5,
            0xE5DCE1, 0xA9A9A9, 0xE6928B, 0xB78256, 0x98836A, 0xBFBA6A, 0xA7BE00, 0x89C2BA,
            0x96C1BA, 0x9CB3C4, 0x85A5C7, 0x8392CD, 0xA595B5, 0xBF9FBE, 0xBC7195, 0x7B7B7B,
            0xAF3333, 0xA95131, 0x724F41, 0xDBC300, 0x85951F, 0x539F31, 0x089C8E, 0x226384,
            0x1A2E96, 0x2F52A2, 0x614BAD, 0xA34BAD, 0xCC2E6D, 0x3C3C3C, 0x000000, 0xFF0000,
            0x03FF00, 0xFFFF00, 0x0000FF, 0xFF00FF, 0x03FFFF, 0x800000, 0x808000, 0x008002,
            0x008080, 0x000080, 0x800080,
        ]

        // ── 用途で使う色（名前で引けるように）──

        /// 黒（`0x000000`）。**未割当セルの地**
        public static let black: UInt8 = 70
        /// 暗いグレー（`0x3C3C3C`）
        public static let darkGray: UInt8 = 69
        /// 中間グレー（`0x7B7B7B`）
        public static let gray: UInt8 = 55
        /// 明るいグレー（`0xA9A9A9`）
        public static let lightGray: UInt8 = 41
        /// 白（`0xFFFFFF`）。**割当ありのセル**
        public static let white: UInt8 = 13
        /// 割当ありの既定（mako 2026-08-04「白じゃなくて別の青系に」）。
        /// `navy` は選択トラックが使っているので**別系統の明るい青**にする —
        /// 暗い LCD の地から浮き上がり、赤/緑の警告色とも当たらない
        public static let azure: UInt8 = 22
        /// 濃い青（`0x000080`）
        public static let navy: UInt8 = 81
        /// 暗い赤（`0x800000`）
        public static let maroon: UInt8 = 77
        /// 赤（`0xFF0000`）
        public static let red: UInt8 = 71
        /// 緑（`0x03FF00`）
        public static let green: UInt8 = 72
        /// 暗い緑（`0x008002`）— MIXER 冊の選択ボタンの既定地
        public static let darkGreen: UInt8 = 79
        /// 青（`0x0000FF`）
        public static let blue: UInt8 = 74
        /// 黄（`0xFFFF00`）
        public static let yellow: UInt8 = 73
        /// 水色（`0x18E9FF`）
        public static let cyan: UInt8 = 21
        /// マゼンタ（`0xFF00FF`）
        public static let magenta: UInt8 = 75

        // MARK: - OKLCH（知覚的に均等な色空間）

        /// OKLCH 座標。**知覚的に均等**なので、明度で並べると人の目の順序と一致する
        /// （sRGB の単純な明度計算だと、同じ数値でも色相によって見え方がずれる）
        public struct OKLCH: Sendable, Equatable {
            /// 明度 0（黒）〜 1（白）
            public let lightness: Double
            /// 彩度 0（無彩色）〜 0.4 程度
            public let chroma: Double
            /// 色相 0〜360 度（彩度が 0 に近いときは意味を持たない）
            public let hue: Double
        }

        /// パレットの色を OKLCH に変換する（sRGB → linear → LMS → OKLab → OKLCH）
        public static func oklch(_ index: UInt8) -> OKLCH {
            let color = palette[Int(index) % palette.count]
            func linear(_ channel: UInt32) -> Double {
                let value = Double(channel) / 255
                return value <= 0.04045
                    ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            let r = linear((color >> 16) & 0xFF)
            let g = linear((color >> 8) & 0xFF)
            let b = linear(color & 0xFF)

            // linear sRGB → LMS → 立方根（OKLab の定義）
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)

            let okL = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
            let okA = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
            let okB = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s

            var hue = atan2(okB, okA) * 180 / .pi
            if hue < 0 { hue += 360 }
            return OKLCH(lightness: okL, chroma: (okA * okA + okB * okB).squareRoot(), hue: hue)
        }

        /// **明度で段階分けした index の並び**（暗い順）。
        /// 「地は 1 段目、文字は 5 段目」のように段で指定したいとき用
                /// **無彩色**（彩度が閾値未満）を暗い順に並べる。
        /// ダーク系の地・グレー階調を組むときはここから選ぶ
        public static func neutrals(maxChroma: Double = 0.02) -> [UInt8] {
            (0..<UInt8(palette.count))
                .filter { oklch($0).chroma < maxChroma }
                .sorted { oklch($0).lightness < oklch($1).lightness }
        }

        /// **色相で 12 分割**（30 度ずつ）。彩度が低いものは無彩色として除く。
        /// パラメータの種類ごとに色を割り振るとき用
        public static func byHue(minChroma: Double = 0.02) -> [[UInt8]] {
            var buckets = [[UInt8]](repeating: [], count: 12)
            for index in 0..<UInt8(palette.count) {
                let color = oklch(index)
                guard color.chroma >= minChroma else { continue }
                buckets[min(11, Int(color.hue / 30))].append(index)
            }
            // 各色相の中は暗い順（段階として使えるように）
            return buckets.map { $0.sorted { oklch($0).lightness < oklch($1).lightness } }
        }

        /// **白への近さ** — OKLCH の白は「明度 1・彩度 0」なので、
        /// **明るいほど / 淡いほど**大きくなる。単なる明度順と違い、
        /// 「鮮やかで明るい黄」より「くすんだ明るい灰青」を上に置く
        public static func whiteness(_ index: UInt8) -> Double {
            let color = oklch(index)
            return color.lightness - color.chroma
        }

        /// **色相ごとの「一番白っぽい」1 色**（mako 要望 2026-08-06「色相順の
        /// パレット、一番白っぽいのを抜き出して、セットにできる？」）。
        ///
        /// 12 色相から 1 つずつ拾うので**最大 12 色**。色相は揃っているのに
        /// 明度が近いので、**並べると面の識別に使える**（濃い色は文字が沈む）
                /// **パレットの「淡色の行」そのもの**（index 28-40）。
        ///
        /// 83 色は **14 色 × 5 行 + 原色**で、**行末が必ず無彩色**
        /// （13=白 / 27 / 41 / 55 / 69）。行ごとにトーンの帯になっている。
        ///
        /// **実測 2026-08-07**（無彩色を除いた 13 色ずつの平均）:
        ///
        /// | 行 | L | C | W = L−C |
        /// |---|---|---|---|
        /// | 1 | .796 | .170 | .626 |
        /// | 2 | .705 | .174 | .531 |
        /// | **3** | **.834** | .086 | **.749** |
        /// | 4 | .716 | **.078** | .638 |
        /// | 5 | .548 | .140 | .408 |
        ///
        /// ⚠️ **「行 3 が最も彩度が低い」は誤り** — それは行 4。
        /// 行 3 を淡色たらしめているのは **whiteness（L−C）が最大**であることで、
        /// 「明るさ」の方が効いている（`whiteness(_:)` と同じ尺度）。
        ///
        /// Bitwig の `ColorUtil.COLORS` は**行単位で設計されている** — 機械的な
        /// HSV グリッドではなく、デザイナーが組んだトーンの表（実測 2026-08-06）。
        /// 末尾の 41（`#A9A9A9`）は無彩色なので外す
                /// **行 3 を基本に、その行が持たない色相だけ他の行から補う**。
        ///
        /// 行 3 は 12 色相を均等にカバーしていない（120° 付近に 3 色ある一方、
        /// **180°（シアン）と 240°（青）が空く**）。そこだけ全体から拾う。
        ///
        /// ⚠️ **これは採用されなかった**（mako 裁定 2026-08-07、実機で A/B/C を
        /// 見比べた上で B を選択）。**空きは埋めるべき欠損ではなく、見せるべき
        /// 事実**だという判断 — 「この帯には青系の淡色が無い」は役に立つ。
        /// `toneMap` が空きを詰めていないのはこの裁定に従っている。
        ///
        /// **UI からは外したが実装は残す** — また要るかもしれないし、
        /// 「補うとどうなるか」を確かめ直せる形にしておく方が安い
                /// **彩度順**（淡い順 → 鮮やか順。mako 「彩度っていうの、それで
        /// ならべたら規則性出そうだなと」）。
        ///
        /// 明度順・色相順では散っていた「同じ濃さの色」が一列に並ぶので、
        /// **地に使える色 / 文字に使える色**の境目が見える
                /// **縦＝明度 / 横＝色相のマトリクス**（mako 要望 2026-08-05
        /// 「縦軸に明度、横軸に色相で並べてみてほしい」）。
        ///
        /// 色相 30 度ずつ 12 列。各列を**明るい順**に上から積む（列によって
        /// 色数が違うので、足りないところは nil で埋めて格子を保つ）。
        ///
        /// 83 色は等間隔に配られているわけではないので、**格子は歯抜けになる**。
        /// そこを詰めて並べると「隣の色が近い」という手掛かりが消えるので、
        /// 空きは空きのまま置く
        public static func matrix(minChroma: Double = 0.02) -> [[UInt8?]] {
            // byHue は暗い順。上から明るい方が目で追いやすいので反転する
            let columns = byHue(minChroma: minChroma).map { Array($0.reversed()) }
            let rows = columns.map(\.count).max() ?? 0
            return (0..<rows).map { row in
                columns.map { column in row < column.count ? column[row] : nil }
            }
        }

        // MARK: - トーンマップ（横 = 色相 / 縦 = 帯。mako 裁定 2026-08-07）

        /// **1 本のトーンの帯**（`ColorUtil.COLORS` の 1 行）。
        ///
        /// 83 色は **14 色 × 5 行 + 原色 13**で、**行末が必ず無彩色**
        /// （13 / 27 / 41 / 55 / 69）。デザイナーが組んだトーンの表であって、
        /// 機械的な HSV グリッドではない（実測 2026-08-06）
        public struct ToneBand: Sendable {
            public let name: String
            /// この帯に属する色（無彩色も含む全部）
            public let indices: [UInt8]
            /// 帯の平均（無彩色を除く。⚠️ **軸の意味を画面に出すため**に持つ）
            public let lightness: Double
            public let chroma: Double
            /// **whiteness = L − C**。⚠️ **帯の順序はこれで決まる**
            public var whiteness: Double { lightness - chroma }
            /// 色相 12 区画 + 無彩の 13 列に割り付けた格子。
            /// **同じ区画に複数あれば行が増える**（列 = 色相の対応を保ったまま
            /// 全色に居場所を与えるため）
            public let grid: [[UInt8?]]
        }

        /// 色相の列数（30° 刻み 12 区画）。
        /// ⚠️ **無彩は含めない**（2026-08-07）— 無彩色に色相は無いので、
        /// 色相軸の右端に置くのは嘘だった。`neutralRow` として最下部へ分ける
        public static let toneMapColumns = 12

        /// **83 色を 1 枚の 2 次元マップに開く**（mako 裁定 2026-08-07
        /// 「B でまとめつつ、縦に彩度・明るさで分けて、全色振り分けたいね」）。
        ///
        /// - **横 = 色相**（30° 刻み 12 区画 + 右端に無彩）
        /// - **縦 = 帯**。⚠️ **順序は whiteness（L−C）の降順**
        ///
        /// ⚠️ **L や C 単体で並べてはいけない。** 実測（2026-08-07）:
        ///
        /// | 行 | L | C | W = L−C |
        /// |---|---|---|---|
        /// | 1 | .796 | .170 | .626 |
        /// | 2 | .705 | .174 | .531 |
        /// | **3** | **.834** | .086 | **.749** |
        /// | 4 | .716 | **.078** | .638 |
        /// | 5 | .548 | .140 | .408 |
        ///
        /// **最も彩度が低いのは行 4** なので、C で並べると行 4 が一番上に来て
        /// 実感とずれる。行 3 を淡色たらしめているのは **W の大きさ**。
        ///
        /// ⚠️ **83 色すべてに居場所を与える**（間引かない）。
        /// **空いた色相は空いたまま見せる** — 「この帯には青系の淡色が無い」は
        /// 役に立つ事実で、埋めると消えてしまう（C 案が埋めていたのを
        /// mako は選ばなかった）
        /// **パレット原典の行構造**（mako 要望 2026-08-13「無彩色とか
        /// プリセットから判断できるグルーピングで一度並べてみて」）。
        ///
        /// 83 色は **14 色 × 5 行 + 原色 13** で、**各行の末尾が必ず無彩色**
        /// （13=白 / 27 / 41 / 55 / 69。原色行の頭にも黒 70）。この区切りで
        /// 並べると無彩色が右端の縦に揃い、メーカーの設計がそのまま見える —
        /// toneMap（OKLCH で再構成した帯）と違い、**何も計算しない生の構造**
        public static func presetRows() -> [[UInt8]] {
            stride(from: 0, to: palette.count, by: 14).map { start in
                (start..<min(start + 14, palette.count)).map(UInt8.init)
            }
        }

        /// **色相順のフラットな並び**（H 昇順。無彩色は含まない — `neutralRow`
        /// を末尾に置く。mako 所見 2026-08-13 board の「色相順」に「いいね」）。
        /// 帯（toneMap）と違い明度・彩度で仕分けない — 虹の一本道
        public static func hueOrdered() -> [UInt8] {
            (0..<UInt8(palette.count))
                .filter { !isNeutral($0) }
                .sorted { oklch($0).hue < oklch($1).hue }
        }

        /// **明度順のフラットな並び**（L 降順、全 83 色 — 白が先頭・黒が最後。
        /// mako 所見 2026-08-13「明度順もいいね。暗い背景選びたい時に」）
        public static func lightnessOrdered() -> [UInt8] {
            (0..<UInt8(palette.count))
                .sorted { oklch($0).lightness > oklch($1).lightness }
        }

        /// **プリセット行の mako 並び**（原典の行 2, 5, 1, 3, 4, 6 の順 =
        /// ビビッド → ダーク → ソフト → 淡 → くすみ → 原色）。
        ///
        /// 経緯: 有彩平均 L の降順（淡→濃→暗）で自動整列した版を実機で見て、
        /// mako が 2 回手調整して決着（2026-08-13）。**計算順ではなく裁定の
        /// 固定順** — 見た目の気持ち良さは数式では出なかった。行の中身は
        /// 原典のまま（行末の無彩色も右端の縦に揃ったまま）
        public static func presetRowsCustom() -> [[UInt8]] {
            let rows = presetRows()
            return [rows[1], rows[4], rows[0], rows[2], rows[3], rows[5]]
        }

        /// **真の無彩色**（R = G = B）— 原典で行末に置かれた 13/27/41/55/69 +
        /// 黒 70 の 6 個。
        /// ⚠️ 閾値判定（C < 0.02）は使わない — #40 E5DCE1（ごく淡いピンク、
        /// 原典では有彩の席）を巻き込んでいた（mako 指摘 2026-08-13
        /// 「#40 って無彩色でよいの？」）。原典の設計 = R=G=B が答え
        public static func isNeutral(_ index: UInt8) -> Bool {
            let rgb = palette[Int(index) % palette.count]
            let red = (rgb >> 16) & 0xFF
            let green = (rgb >> 8) & 0xFF
            return red == green && green == (rgb & 0xFF)
        }

        /// **最下部に置く無彩色の 1 セット**（mako 要望 2026-08-07
        /// 「無彩色のセットが暗黙的に含まれてるから、それを抽出して、
        /// 最下部に１セットとしておいて」）。
        ///
        /// 83 色は 14 色 × 5 行 + 原色で、**各行の末尾が無彩色**
        /// （13=白 / 27 / 41 / 55 / 69）+ 原色帯にも黒がある。
        /// ⚠️ **帯からは抜く**（両方に出すとどちらが本物か分からなくなる）。
        ///
        /// **白 → 黒**（whiteness 降順）— 帯の順序と同じ向きに揃える
        public static func neutralRow() -> [UInt8] {
            (0..<UInt8(palette.count))
                .filter { isNeutral($0) }
                .sorted { whiteness($0) > whiteness($1) }
        }

        public static func toneMap() -> [ToneBand] {
            // 14 色 × 5 行 + 残り（原色）。⚠️ **端数は捨てず最後の帯にまとめる**
            let rowLength = 14
            let fullRows = palette.count / rowLength
            var bands: [ToneBand] = []

            for row in 0..<fullRows {
                let start = UInt8(row * rowLength)
                let indices = (0..<rowLength).map { start + UInt8($0) }
                bands.append(band(name: "帯\(row + 1)", indices: indices))
            }
            let rest = (fullRows * rowLength..<palette.count).map { UInt8($0) }
            if !rest.isEmpty {
                bands.append(band(name: "原色", indices: rest))
            }
            // **淡い帯が上**（whiteness の降順）
            return bands.sorted { $0.whiteness > $1.whiteness }
        }

        private static func band(name: String, indices: [UInt8]) -> ToneBand {
            // 列 0-11 = 色相 30° 刻み。
            // ⚠️ **無彩色はここに入れない** — `neutralRow` が最下部でまとめて
            // 引き受ける（2026-08-07）。色相を持たないものを色相軸へ置くと
            // 「0°（赤）」の隣に灰色が並んで、列を縦に読めなくなる
            var columns = [[UInt8]](repeating: [], count: toneMapColumns)
            for index in indices where !isNeutral(index) {
                columns[min(11, Int(oklch(index).hue / 30))].append(index)
            }
            // 同じ区画に複数あるときは**白に近い方を上**へ（帯の中でも淡い順）
            columns = columns.map { $0.sorted { whiteness($0) > whiteness($1) } }

            let rows = columns.map(\.count).max() ?? 0
            let grid = (0..<rows).map { row in
                columns.map { column in row < column.count ? column[row] : nil }
            }

            // 平均は**無彩色を除く**（無彩を混ぜると帯の性格がぼやける）
            let chromatic = indices.filter { !isNeutral($0) }
            let count = Double(max(chromatic.count, 1))
            return ToneBand(
                name: name, indices: indices,
                lightness: chromatic.reduce(0) { $0 + oklch($1).lightness } / count,
                chroma: chromatic.reduce(0) { $0 + oklch($1).chroma } / count,
                grid: grid)
        }

        /// **ページ色の既定**（16 ページぶん）。
        ///
        /// 色相を一周させる — **隣のページと色がはっきり違う**ことが要点で、
        /// 「今どこに居るか」より「動いたかどうか」が分かる方が実用的。
        /// 暗すぎる色は LCD で読めないので、明度が中〜高のものから選ぶ。
        ///
        /// mako 要望 2026-08-05「それぞれの P1 毎に色を選んで、LCD の色に使いたい」
        public static let defaultPageColors: [UInt8] = {
            let buckets = byHue()
            // 色相 12 区画から明るめを 1 つずつ拾い、足りない分は詰めて 16 個に
            var picked: [UInt8] = buckets.compactMap { bucket in
                // 各区画の中は暗い順なので、後ろ寄り（明るめ）を取る
                bucket.isEmpty ? nil : bucket[min(bucket.count - 1, bucket.count * 2 / 3)]
            }
            // 12 区画では足りないので、2 周目は各区画の別の明度から
            for bucket in buckets where picked.count < 16 {
                guard bucket.count > 1 else { continue }
                picked.append(bucket[bucket.count / 3])
            }
            // それでも足りなければ白で埋める（16 ページに満たない機体は無いはず）
            while picked.count < 16 { picked.append(white) }
            return Array(picked.prefix(16))
        }()

        /// **席ごとに色相をずらすときの歩幅**（`defaultPageColors` を何個ぶん回すか）。
        ///
        /// 16 と**互いに素**な 3 を選ぶ — 隣の席とは 3 色相ぶん（≒67 度）離れ、
        /// 同じ配色に戻るのは **16 席先**になる。2 や 4 だと数席で一周してしまう
        public static let trackHueStep = 3

        /// **席ごとのページ既定色**（mako 要望 2026-08-05「Page 毎の配色を
        /// Track の Page 毎にしたい」）。
        ///
        /// `defaultPageColors`（色相を一周する 16 色）を**席番号ぶん回した**もの。
        /// 新しいパレットを作らないので、**ページを繰れば色が大きく変わる**という
        /// 元の性質はそのまま残り、そのうえで**席が変われば同じ P1 でも別の色**になる。
        ///
        /// ページが 16 を超えたら畳んで一周させる（`assignableCCs` は 8 で割って
        /// 16 ページ未満なので、通常は起こらない）
        public static func pageColor(track: Int, page: Int) -> UInt8 {
            let colors = defaultPageColors
            guard !colors.isEmpty, page >= 0 else { return white }
            let shifted = page + track * trackHueStep
            // track が負でも落ちないように正へ寄せる（席番号は 0 以上のはずだが、
            // 色の計算で落ちるのは割に合わない）
            return colors[((shifted % colors.count) + colors.count) % colors.count]
        }

        /// RGB（各 0-255）を**最近傍のパレット index** に量子化する。
        /// `ColorUtil.findClosestColor` 等価 — 元実装はユークリッド距離だが、
        /// 最小値を取る index は二乗距離でも同じなので `sqrt` を省く
        public static func closest(red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
            var bestIndex = 0
            var bestDistance = Int.max
            for (index, color) in palette.enumerated() {
                let dr = Int((color >> 16) & 0xFF) - Int(red)
                let dg = Int((color >> 8) & 0xFF) - Int(green)
                let db = Int(color & 0xFF) - Int(blue)
                let distance = dr * dr + dg * dg + db * db
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            return UInt8(bestIndex)
        }
    }

    /// ROTO の配色（用途ごとにパレット index を持つ）。
    ///
    /// ROTO は任意 RGB を受けないので、**設定できるのは 83 色から選ぶことだけ**。
    /// 既定はダーク系（mako 2026-08-04「LCD の背景もダーク系で。割当ありは明るめで」）
    public struct Colors: Codable, Equatable, Sendable {
        /// SMART 面 — 割当があるノブ。
        ///
        /// ⚠️ **いまは実機に出ない**。席ごとのページ既定（`Color.pageColor`）が
        /// 全ページを埋めるので、ここまで落ちてこない。設定 UI（`slots`）からも
        /// 外してある — 効かない設定を並べておく方が害が大きい。
        /// 旧 Snapshot を読めるようにフィールドだけ残す
        public var assigned: UInt8
        /// SMART 面 — 空きノブ。
        /// **既定は暗いグレー**（mako 裁定 2026-08-06「未割り当てはグレー背景で
        /// `-`」）。⚠️ **明るいグレーにしてはいけない** — LCD の文字色は
        /// デバイスが白で固定していて変えられないので、明るい地だと `-` が消える
        public var empty: UInt8
        /// MIX 面 — 選択中のトラック
        public var trackSelected: UInt8
        /// MIX 面 — その他のトラック
        public var track: UInt8
        /// **MAIN LCD（左の大窓）の地**（mako 要望 2026-08-06「SMART の背景を
        /// 設定で変えたい」）。
        ///
        /// ⚠️ **文字色はデバイスが握っていて白固定** — 明るい色を選ぶと
        /// 白地に白文字になって読めない（実測 2026-08-06）。暗い色から選ぶこと
        public var menu: UInt8

        /// **MIXER 冊の選択ボタン（下段）の地**（mako 裁定 2026-08-13
        /// 「設定項目にしよう」— 決め打ちの暗緑 79 から設定へ昇格）
        public var selectButton: UInt8

        /// **席ごとのページ色**（キー = トラック番号 = ラックの席）。
        ///
        /// ⚠️ LCD は **1 色・1 行しか受けない**（実測 2026-08-05、docs/roto-control/protocol.md）。
        /// 「下半分をページ固定、上半分をユーザー設定」の 2 色表示は成立しないので、
        /// **この 1 色がページと席の手がかりを兼ねる**。
        ///
        /// 既定は `Color.pageColor(track:page:)` に委ね、**手を入れた席だけ**持つ。
        /// 32 席 × 16 ページを常に抱えると、色を 1 つ変えるたびに 512 要素を
        /// 書き出すことになる
        public var trackPages: [Int: [UInt8]] = [:]

        /// **席ごとの、セルごとの色**（mako 裁定 2026-08-05）。
        /// キーは トラック番号 → Ctrl 番号（= CC）。
        ///
        /// 「Cutoff は赤、Reso は青」のように**役割で分けられる**。**席ごとに独立**
        /// なのは、同じ CC でも載っている楽器が違えば別のパラメータを指すため
        public var trackCells: [Int: [Int: UInt8]] = [:]

        /// **席ごとの MAIN LCD の地**（mako 要望 2026-08-06「MAIN LCD の色ページ
        /// カラー同様に、プラグイン側に持たせて、それを Main 表示に使いたい」）。
        ///
        /// ページ色（`trackPages`）と同じ作法で、**手を入れた席だけ**持つ。
        /// 決めていない席は設定の `menu` に落ちる — 全席を手で決めるのは現実的でない
        public var trackMainLcd: [Int: UInt8] = [:]

        /// その席の MAIN LCD に出す地の色。**席指定 > 設定の既定** の順
        public func mainLcdColor(track: Int) -> UInt8 {
            trackMainLcd[track] ?? menu
        }

        /// 席の MAIN LCD 色を上書きする（`nil` で設定の既定へ戻す）
        public mutating func setMainLcdColor(track: Int, to color: UInt8?) {
            trackMainLcd[track] = color
        }

        /// そのセルの LCD に出る色。**セル指定 > 席のページ色 > 席ごとの既定** の順。
        ///
        /// LCD は 1 色しか受けないので（実測 2026-08-05）、この 1 色に
        /// 「どのページか」と「どの席か」の両方を載せている。
        ///
        /// ⚠️ 名前を `assigned` にしない — 同名の**プロパティ**があると
        /// SourceKit が `Cannot call value of non-function type 'UInt8'` を
        /// 出し続ける（コンパイルは通るのでエディタにだけ赤線が残る）
        public func lcdColor(track: Int, page: Int, cell: Int? = nil) -> UInt8 {
            if let cell, let specific = trackCells[track]?[cell] { return specific }
            if let pages = trackPages[track], pages.indices.contains(page) { return pages[page] }
            return Color.pageColor(track: track, page: page)
        }

        /// その席のページ色を 1 つ上書きする（`nil` で既定へ戻す）。
        /// 上書きが 1 つも無くなった席は**丸ごと落とす** — 既定に戻った席が
        /// 空配列として残ると、次に既定を変えたときに追従しない
        public mutating func setPageColor(track: Int, page: Int, to color: UInt8?) {
            guard page >= 0 else { return }
            var pages = trackPages[track] ?? []
            // 上書きは飛び番になりうる（P5 だけ変える等）ので、そこまで既定で埋める
            while pages.count <= page {
                pages.append(Color.pageColor(track: track, page: pages.count))
            }
            pages[page] = color ?? Color.pageColor(track: track, page: page)
            let untouched = pages.enumerated().allSatisfy { index, value in
                value == Color.pageColor(track: track, page: index)
            }
            trackPages[track] = untouched ? nil : pages
        }

        /// その席のセル色を 1 つ上書きする（`nil` で既定へ戻す）
        public mutating func setCellColor(track: Int, cell: Int, to color: UInt8?) {
            var cells = trackCells[track] ?? [:]
            if let color {
                cells[cell] = color
            } else {
                cells.removeValue(forKey: cell)
            }
            trackCells[track] = cells.isEmpty ? nil : cells
        }

        public init(
            assigned: UInt8 = Color.azure,
            empty: UInt8 = Color.darkGray,
            trackSelected: UInt8 = Color.navy,
            track: UInt8 = Color.black,
            menu: UInt8 = Color.darkGray,
            selectButton: UInt8 = Color.darkGreen,
            // 空 = 席ごとの既定（`Color.pageColor`）に委ねる。
            // LCD は 1 色なので、その色がページと席を示す唯一の手がかりになる
            trackPages: [Int: [UInt8]] = [:],
            trackCells: [Int: [Int: UInt8]] = [:]
        ) {
            self.assigned = assigned
            self.empty = empty
            self.trackSelected = trackSelected
            self.track = track
            self.menu = menu
            self.selectButton = selectButton
            self.trackPages = trackPages
            self.trackCells = trackCells
        }

        // MARK: - Codable — **キー欠落を落とさない**
        //
        // ⚠️ 合成の `init(from:)` は知らないキーこそ無視するが、**足りないキーでは
        // 落ちる**。フィールドを 1 つ増やすたびに既存 Snapshot の decode が丸ごと
        // 失敗し、`try?` に握り潰されて**配色が全部既定へ戻る**。8/5 に
        // `pages`/`cells` を足したときに一度それが起きている（DB に残った JSON が証拠）。
        //
        // 全部 `decodeIfPresent` にして、**増やしても壊れない**ようにする。
        // 旧 `pages`（席共通のページ色）と旧 `cells` は鍵を持たないので読み捨てになる —
        // 前者は編集する UI が無いまま既定の写しが入っていただけ、後者は空だった

        private enum CodingKeys: String, CodingKey {
            case assigned, empty, trackSelected, track, menu, selectButton
            case trackPages, trackCells, trackMainLcd
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func color(_ key: CodingKeys, _ fallback: UInt8) throws -> UInt8 {
                try container.decodeIfPresent(UInt8.self, forKey: key) ?? fallback
            }
            assigned = try color(.assigned, Color.azure)
            empty = try color(.empty, Color.black)
            trackSelected = try color(.trackSelected, Color.navy)
            track = try color(.track, Color.black)
            menu = try color(.menu, Color.darkGray)
            selectButton = try color(.selectButton, Color.darkGreen)
            trackPages =
                try container.decodeIfPresent([Int: [UInt8]].self, forKey: .trackPages) ?? [:]
            trackCells =
                try container.decodeIfPresent([Int: [Int: UInt8]].self, forKey: .trackCells) ?? [:]
            trackMainLcd =
                try container.decodeIfPresent([Int: UInt8].self, forKey: .trackMainLcd) ?? [:]
        }

        /// 設定 UI の並び（表示名とキーパス）。
        ///
        /// `assigned` は載せない — 席ごとのページ既定が全ページを埋めるので、
        /// ここに置いても**動かないつまみ**になる
        /// 2026-08-13 の整理で **MIDI モードの焼きに効くものだけ**に絞った
        /// （面の責務原則 — ROTO 面は「焼き」と実機の色だけ）。empty /
        /// trackSelected / track / menu は DAW モードの遺物で実機に効かない —
        /// フィールドは旧 Snapshot 互換のため残すが、UI には並べない
        /// （「効かない設定を並べておく方が害が大きい」— assigned と同じ扱い）
        public static let slots: [(name: String, keyPath: WritableKeyPath<Colors, UInt8>)] = [
            ("選択ボタン", \.selectButton),
        ]
    }

    // MARK: - 面の切替（Logic 方言 — **ホストが指示する**）

    /// Logic 方言では **MODE キーではなくホストが面を選ぶ**。
    /// `config.lua` の `SEL Smart / SEL Plugin` が ch7（COMMAND）の CC を投げている:
    ///
    /// ```lua
    /// MIXER_VOLUME_COMMAND = 0x51 … FOCUS_COMMAND = 99 / SMART = 100 / PLUGIN = 101
    /// [CONTROL_ID_SEL_SMART] = { midi = {MIDI_CHANNELS.COMMAND, SMART_COMMAND, 0x01} }
    /// ```
    ///
    /// これを送らないと **MIX 面から動けない**（実測 2026-08-04: 種別 3 を
    /// 名乗って握手しても、MODE キーでは SMART へ行けなかった）
    public enum Face: UInt8, Sendable {
        case focus = 99
        case smart = 100
        case plugin = 101
    }

    /// 面を切り替える。ch7 (0xB6) の CC を**押して離す**（ボタン扱い）。
    /// config.lua の定義は `{COMMAND, SMART_COMMAND, 0x01}` で押下値だけだが、
    /// 実機は解放（0x00）まで見ている可能性がある
    public static func selectFace(_ face: Face) -> [[UInt8]] {
        [[0xB6, face.rawValue, 0x01], [0xB6, face.rawValue, 0x00]]
    }

    // MARK: - VU メーター（未検証 — 専用の表示器は無く LCD に描かれるはず）

    /// メーターの有効化。`0C 0C <8×bool>` — トラックごとに on/off
    public static func meterStates(_ enabled: [Bool]) -> [UInt8] {
        frame(0x0C, 0x0C, enabled.prefix(8).map { $0 ? 1 : 0 })
    }

    /// メーターの色が変わる閾値。`0C 0B <yellow> <red>`（既定 87 / 113）
    public static func meterPoints(yellow: UInt8 = 87, red: UInt8 = 113) -> [UInt8] {
        frame(0x0C, 0x0B, [yellow, red])
    }

    /// レベルを流す。**ch16 の CC65 から L/R 交互に 16 本**
    /// （`METERS_FIRST_CC = 65` / config.lua の `METERS_0 = 0x41`）。
    /// 公式は毎秒 12 回（AUDIO_METER_FPS）
    public static func meter(track: Int, left: Double, right: Double) -> [[UInt8]] {
        func level(_ value: Double) -> UInt8 {
            UInt8((min(max(value, 0), 1) * 127).rounded())
        }
        return [
            [0xBF, UInt8(65 + track * 2), level(left)],
            [0xBF, UInt8(65 + track * 2 + 1), level(right)],
        ]
    }

    /// ⭐ **RK1-8 の LED を「current だけ点灯」に全塗りする 8 通**
    /// （ch16 CC20-27 のエコー。127 = 点灯 / 0 = 消灯）。
    ///
    /// 押下なしの一方的送信でも点灯・消灯とも完全に効く（実測 2026-08-11。
    /// 同日午前の「消せない」は注入毒で半死にの実機を相手にした誤測定 —
    /// Creo `mem_1CdvSucMFyzZ4BEpFgJVpX`）。**毎回 8 個を置き直す**前提の
    /// 形にしてある — 実機保存のミュート染みがいつ復活しても、次の一塗りで
    /// 正しい形に均される（差分方式だと堆積の嘘が残る）
    public static func pageLights(current: Int) -> [[UInt8]] {
        (0..<8).map { [0xBF, UInt8(20 + $0), $0 == current ? 127 : 0] }
    }

    /// NUM_TRACKS（0A 04）単独。
    ///
    /// ⚠️ **バイト順は未解決**（2026-08-11）。公式スクリプトは両方向とも
    /// **MSB 先**（official-scripts-map.md）だが、実機 A/B では下位先
    /// `[16,0]`（= MSB 先で読めば 2048）だけが効き、正値 `[0,16]` は
    /// 無視された。ただしこの A/B は**送信タイミングと交絡していた疑い**
    /// （正値をセッション中盤に注入する対照が欠けている）。作り直しの
    /// 実測で決着させること — それまで実測で効いた下位先を維持
    public static func numTracks(_ tracks: Int) -> [UInt8] {
        frame(0x0A, 0x04, [UInt8(tracks & 0x7F), UInt8((tracks >> 7) & 0x7F)])
    }

    /// FIRST_TRACK（0A 05）= 常に 0（窓スライドはホスト側の仕事）
    public static let firstTrack = frame(0x0A, 0x05, [0, 0])

    /// Logic 版の init シーケンス（config.lua の DAW_STARTED 直後を再現）
    /// - Parameter tracks: 宣言するトラック数（**実際の総数**。14bit、64 まで）。
    ///   ⚠️ **Logic 方言では ← → を押しても実機は自分でページを繰らない** —
    ///   16 席宣言しても表示は 8 枠のまま不動で、ch16 CC60/61（値 2）を
    ///   DAW へ送ってくるだけ（実測 2026-08-11。「デバイスが繰る」は
    ///   2026-08-03 の別方言時代の測定）。
    ///   ⚠️ かといって**見えている枠数（8）だけの宣言もダメ** —
    ///   「スクロール先が無い」と実機が判断し、← → を 1 通も送らなくなる
    ///   （同日実測）。総数を宣言し、窓スライドをホストがやる、が正解
    public static func logicInit(tracks: Int = 8, devices: UInt8 = 8) -> [[UInt8]] {
        [
            frame(0x0C, 0x03, [2]),  // NUM_SENDS
            numTracks(tracks),  // ⚠️ 下位バイト先でしか効かない（numTracks の doc）
            frame(0x0A, 0x05, [0, 0]),  // FIRST_TRACK
            frame(0x0B, 0x02, [devices]),  // NUM_DEVICES
            frame(0x0B, 0x03, [0]),  // FIRST_DEVICE
            frame(0x0C, 0x0B, [87, 113]),  // VU meter points（yellow / red）
        ]
    }

    // MARK: - モーター（SysEx ではなく 14bit CC）

    /// knob のモーター位置。**ch16 の 14bit hi-res CC**（hi → lo の順）。
    /// ⚠️ **learn/recall で active になった knob しか動かない**（実測 2026-08-03:
    /// 割当ありの knob 0 だけ動き、不活性の 7 本は無反応）。入力の
    /// ccInsBlocked ガードと同じ門がモーター出力にも掛かっている
    public static func motor(knob: Int, value: Double) -> [[UInt8]] {
        let clamped = min(max(value, 0), 1)
        let raw = Int((clamped * 16383).rounded())
        return [
            [0xBF, UInt8(12 + knob), UInt8((raw >> 7) & 0x7F)],
            [0xBF, UInt8(44 + knob), UInt8(raw & 0x7F)],
        ]
    }

    // MARK: - 表示

    /// 13 スロットの name（12 文字に切り、末尾は必ず 00 終端）。
    /// 非 ASCII は落とす — ROTO は ASCII しか出せない
    public static func name13(_ text: String) -> [UInt8] {
        var bytes = Array(text.utf8.filter { $0 >= 0x20 && $0 < 0x80 }.prefix(12))
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 13 - bytes.count))
        return bytes
    }

    public static func index14(_ value: Int) -> [UInt8] {
        [UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }

    /// トラック表示の**枠付きバッチ**。⚠️ `07` 単発では表示されない —
    /// 総数 → offset → 更新×N → コミット を必ずセットで送る（実機検証済）
    public static func trackBatch(_ names: [String], colorIndex: UInt8 = 40) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        messages.append(frame(0x0A, 0x04, index14(names.count)))  // 総数
        messages.append(frame(0x0A, 0x05, index14(0)))  // 先頭 offset
        for (i, name) in names.enumerated() {
            messages.append(
                frame(0x0A, 0x07, index14(i) + name13(name) + [colorIndex, 0]))
        }
        messages.append(frame(0x0A, 0x08))  // 表示コミット
        return messages
    }

    /// 選択中トラックの表示（MIXER 面）
    public static func selectedTrack(_ index: Int, name: String, colorIndex: UInt8 = 40) -> [UInt8] {
        frame(0x0C, 0x04, index14(index) + name13(name) + [colorIndex, 0])
    }

    // MARK: - PLUGIN 告知（recall の起点）

    /// 告知する 1 プラグインの記述
    public struct PluginInfo {
        public let name: String
        public var enabled: Bool
        /// 0 = 通常 / 1 = macro rack / 2 = 3rd party plugin（Ableton の語彙。Bitwig は 0/1 のみ）
        public var rackKind: UInt8
        public var pages: UInt8
        /// 省略時は hash8(name)。Bitwig 資産と照合するときは名前をそのまま使う
        public var hash: [UInt8]?

        public init(
            name: String, enabled: Bool = true, rackKind: UInt8 = 0, pages: UInt8 = 1,
            hash: [UInt8]? = nil
        ) {
            self.name = name
            self.enabled = enabled
            self.rackKind = rackKind
            self.pages = pages
            self.hash = hash
        }
    }

    /// プラグイン一覧の**枠付きバッチ**（track と同型）:
    /// `0B 02 [台数] → 0B 03 [先頭] → 0B 05 details×N → 0B 06 終了`。
    /// details = `<idx> <hash8> <enabled> <name13> <rackKind> <pages>`。
    /// これを送るとデバイスが保存済み割当を照合し、CONTROL_MAPPED を返してくる
    public static func pluginBatch(_ plugins: [PluginInfo], firstIndex: UInt8 = 0) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        messages.append(frame(0x0B, 0x02, [UInt8(plugins.count)]))
        messages.append(frame(0x0B, 0x03, [firstIndex]))
        for (i, plugin) in plugins.enumerated() {
            let digest = plugin.hash ?? hash8(plugin.name)
            messages.append(
                frame(
                    0x0B, 0x05,
                    [UInt8(i) + firstIndex] + digest + [plugin.enabled ? 1 : 0]
                        + name13(plugin.name) + [plugin.rackKind, plugin.pages]))
        }
        messages.append(pluginCommit)
        return messages
    }

    // MARK: - parameter learn

    /// パラメータの「意味」を teach / recall 応答する。
    /// `02 0B 0A <idxHi> <idxLo> <hash6> <isMacro> <detent> <steps> <posHi> <posLo> <name13>`
    ///
    /// ⚠️ `paramIndex` は **プラグイン内のパラメータ番号**（knob 番号ではない）。
    /// CONTROL_MAPPED への応答では受信した paramIndex と hash6 をそのまま echo する
    public static func learn(
        paramIndex: Int, name: String, value: Double,
        hash: [UInt8]? = nil, steps: UInt8 = 0, centerDetent: Bool = false,
        isMacro: Bool = false
    ) -> [UInt8] {
        let raw = Int((min(max(value, 0), 1) * 16383).rounded())
        return frame(
            0x0B, 0x0A,
            index14(paramIndex) + (hash ?? hash6(name))
                + [isMacro ? 1 : 0, centerDetent ? 1 : 0, steps]
                + index14(raw) + name13(name))
    }

    /// plugin detail 終了（= 0B 05 バッチのコミット）
    public static let pluginCommit = frame(0x0B, 0x06)

    /// 割当済みコントロールの**名前だけ**を差し替える（PLUGIN 面）。
    /// `0B 0F <00> <idx+1> <hash6> <name13>` — index は **1 始まり**。
    ///
    /// PLUGIN 面のラベルは learn 応答でしか付かず、learn は CONTROL_MAPPED が
    /// 来たとき = 面に入った瞬間しか送れない（押し込みの learn は効かない —
    /// 実測 2026-08-03）。**割当や選択が変わったあとに LCD を追従させる経路が
    /// これ**。hash6 は CONTROL_MAPPED で受けたものをそのまま使う
    ///
    /// ⚠️ 未検証。カタログ（ROTO_CONTROL.py の定数）には DAW→機器とあるが、
    /// 実トラフィックでは**機器から来ている**のも観測されている（protocol.md）
    public static func setMappedControlName(control index: Int, hash: [UInt8], name: String)
        -> [UInt8]
    {
        frame(0x0B, 0x0F, [0, UInt8(clamping: index + 1)] + hash + name13(name))
    }

    /// DAW_SELECT_PLUGIN — 「index のプラグインが今フォーカス」を宣言する。
    /// **バッチ（0B 02〜06）の後にこれを送って初めて**デバイスが保存済み割当を
    /// 照合し CONTROL_MAPPED を返してくる（ROTO_CONTROL.py `_send_selected_device_update`）
    public static func selectPlugin(_ index: UInt8, pages: UInt8 = 0, force: Bool = false)
        -> [UInt8]
    {
        frame(0x0B, 0x08, [index, pages, force ? 1 : 0])
    }

    // MARK: - 表示補助

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map(pad).joined(separator: " ")
    }

    private static func pad(_ byte: UInt8) -> String {
        String(format: "%02X", byte)
    }
}
