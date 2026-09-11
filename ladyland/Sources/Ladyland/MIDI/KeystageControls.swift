//! **Keystage の操作子 → ladyland の扱い**（mako 要望 2026-08-07
//! 「Keystage のわりあてというか。そちらをさきに固めてから進めよう」）。
//!
//! ## なぜ 1 か所に集めるか — 今日 3 回同じ形で刺さった
//!
//! この機材は **MIDI 仕様の予約番号にボタンを焼いている**。ladyland が
//! 受け止めていないものは `MIDIRouter` の「**割当のない CC はそのまま楽器へ
//! 通す**」に落ち、**AU が仕様どおり解釈する**。
//!
//! 知識が `AppState` / `MIDIInput` / `KeystageProtocol` のコメントに散っていて、
//! **全体像がどこにも無かった** — だから隣の穴に気づけない。
//!
//! ⚠️ **doc コメントではなく値にする**（`RotoFaceTransitions` と同じ作法）。
//! 画面とテストから見えないと、また同じことが起きる。
//!
//! ## ⚠️ 番号を直書きしない
//!
//! CC 番号は **`Keystage.ladylandButtonCCs`（焼く値）から導く**。
//! 直書きすると、mako が機材側で番号を変えた瞬間に**保護が黙って外れる**。
//! 今日 `as? LadySampler` で 2 か所刺さったのと同じ形
//! — **具体値で条件を書くと、値が動いたときに外れる**。

import Foundation
import KeystageKit

/// 操作子 1 つの素性と、ladyland がどう扱うか
struct KeystageControl: Identifiable {
    /// 何を出すか
    enum Emits: Equatable {
        /// 焼いたボタン（**CC 番号は `ladylandButtonCCs` から引く**）
        case button(Keystage.ButtonOffset.Button)
        /// 位置固定の CC（ノブ・ホイール・ペダル）
        case fixedCC(Int)
        /// Program Change（VALUE エンコーダー）
        case programChange
        /// ⚠️ **単一の CC 番号を持たない**（ノブ列 = 帯 CC0-63 / PB）。
        /// ノブの CC は「デバイスが何ページ目か」で決まる位置固定
        /// （`KeystageKnobs`。設定不要 — KONTROL EDITOR の `KnobSelect` は
        /// 表示切替にすぎない）。帯は割当の有無に関わらず全部飲む
        case deviceAssigned(String)
    }

    /// **捕まえたときの役割**。
    ///
    /// ⚠️ **文字列で判定しない** — 「説明文に『戻す』が入っていたら -1」
    /// のような書き方は、言い回しを直した瞬間に黙って壊れる
    enum Role: Equatable {
        /// ROTO のページを繰る（-1 / +1）
        case pageStep(Int)
        /// トラックを移動する
        case trackMove
        /// 全消音
        case panic
        /// ⚠️ **役割は無いが素通しさせない**（理由つき）
        case held(String)

        var label: String {
            switch self {
            case .pageStep(let d): return d < 0 ? "ページを 1 つ戻す" : "ページを 1 つ進める"
            case .trackMove: return "トラックを移動する"
            case .panic: return "全消音（panic）"
            case .held(let why): return why
            }
        }
    }

    /// ladyland がどうするか
    enum Handling: Equatable {
        /// **捕まえて何かする**。⚠️ 楽器へは流さない
        case captured(Role)
        /// **楽器へ通す**。⚠️ これが正しい既定 — Mod ホイールなどが効くため
        case passThrough
        /// **捕まえたうえで楽器へも流す**（ペダルのキープなど）
        case both(String)

        /// ⚠️ **捕まえる = 楽器へ流さない**
        var isCaptured: Bool {
            if case .captured = self { return true }
            return false
        }
    }

    /// 由来
    enum Provenance: Equatable {
        case measured(String)
        case untested

        var label: String {
            switch self {
            case .measured(let date): return "実測 \(date)"
            case .untested: return "未確認"
            }
        }

        var isMeasured: Bool { self != .untested }
    }

    let name: String
    let emits: Emits
    let handling: Handling
    /// ⚠️ **MIDI 仕様上の予約なら、その意味**。素通しすると AU がこの意味で
    /// 解釈する — 「使っていない番号」ではなく「**誰もが解釈する番号**」
    let reserved: String?
    let provenance: Provenance

    var id: String { name }

    /// **実際に飛ぶ CC 番号**（`ladylandButtonCCs` から引く。⚠️ 直書きしない）
    var cc: Int? {
        switch emits {
        case .button(let button):
            return Keystage.ladylandButtonCCs.first { $0.0 == button }.map { Int($0.1) }
        case .fixedCC(let number):
            return number
        case .programChange, .deviceAssigned:
            return nil
        }
    }
}

enum KeystageControls {
    /// **操作子の全体像**。
    ///
    /// ⚠️ **ページ送りの割当はここが正典**。`MIDIRouter` は番号ではなく
    /// **この表から引く**ので、焼き直しても保護が付いてくる。
    static let all: [KeystageControl] = [
        // ── ladyland が焼いたボタン（⚠️ 全部 MIDI 予約番号） ──────────
        //
        // ⚠️ **危険牌への配置は意図的で正しい**（`FaceKnobAssignment.unsafeCCs`）—
        // パラメータに使える良い CC を空けるため。**焼く値は変えない**。
        // 変えるのは「受けたときどうするか」だけ
        KeystageControl(
            name: "Rec", emits: .button(.rec),
            handling: .captured(.pageStep(-1)),
            reserved: "NRPN LSB", provenance: .measured("2026-08-07")),
        KeystageControl(
            name: "Loop", emits: .button(.loop),
            handling: .captured(.pageStep(1)),
            reserved: "NRPN MSB", provenance: .measured("2026-08-07")),

        // ⚠️ **役割は無いが捕まえる。** mako がペダルのモード切替に使う予定で
        // 空けてあるが、**素通しさせてはいけない** — Data Inc/Dec は
        // NRPN のアドレスを立てた後に**任意のパラメータを増減する**命令で、
        // ladyland 自身がその番号へ焼いている以上、通す理由が無い
        KeystageControl(
            name: "Play", emits: .button(.play),
            handling: .captured(.held("予約（ペダルのモード切替用に確保）")),
            reserved: "Data Increment", provenance: .measured("2026-08-07")),
        KeystageControl(
            name: "Stop", emits: .button(.stop),
            handling: .captured(.held("予約（ペダルのモード切替用に確保）")),
            reserved: "Data Decrement", provenance: .measured("2026-08-07")),

        // ⚠️ **ここから下は素通ししている**（実機ログで slot へ届くのを確認）。
        // **今回は塞いでいない** — 「役割を持たせた操作子だけ捕まえる」が原則で、
        // 勝手に全部塞ぐと Mod ホイールのような正しい素通しまで巻き込む。
        // ⚠️ **危険度は残る**ので、役割を決めるか塞ぐかの判断が要る
        KeystageControl(
            name: "Tempo", emits: .button(.tempo), handling: .passThrough,
            reserved: "RPN LSB", provenance: .measured("2026-08-07")),
        KeystageControl(
            name: "Metro", emits: .button(.metro), handling: .passThrough,
            reserved: "RPN MSB", provenance: .untested),
        KeystageControl(
            name: "Undo", emits: .button(.undo), handling: .passThrough,
            reserved: "Reset All Controllers", provenance: .untested),
        KeystageControl(
            name: "Track ↓", emits: .button(.trackDown), handling: .passThrough,
            reserved: "Local Control On/Off", provenance: .untested),
        KeystageControl(
            name: "Track ↑", emits: .button(.trackUp), handling: .passThrough,
            reserved: "All Notes Off", provenance: .untested),

        // ── 位置固定の操作子 ──────────────────────────────
        // ⭐ **VALUE エンコーダーは Program Change を送る**（実測 2026-08-07、
        // 実機ログ `ch1 Program Change 29,30,31…`）。
        //
        // ⚠️ **一度「REW/FF と同じコントロール」と書き換えたが誤りだった** —
        // EDITOR で `Encoder` を選ぶと VALUE が光る、を根拠にしたが、
        // **実際に飛んでいるのは PC**。表示より実測が強い。
        //
        // ⚠️ **ch1 で来る**（焼いたボタンは ch10）。⭐ **ch を見込むな** —
        // mako が機材側を触ると揃わなくなる
        KeystageControl(
            name: "VALUE エンコーダー", emits: .programChange,
            handling: .captured(.trackMove),
            reserved: nil, provenance: .measured("2026-08-07")),
        // REW / FF は**別のコントロール**（焼いた Encoder）。届けば同じく使う
        KeystageControl(
            name: "REW", emits: .fixedCC(117), handling: .captured(.trackMove),
            reserved: nil, provenance: .measured("2026-08-05")),
        KeystageControl(
            name: "FF", emits: .fixedCC(118), handling: .captured(.trackMove),
            reserved: nil, provenance: .measured("2026-08-05")),
        KeystageControl(
            name: "Mod ホイール", emits: .fixedCC(FaceKnobAssignment.modWheelCC),
            handling: .passThrough,
            reserved: nil, provenance: .measured("2026-08-05")),
        // Expression は CC115 へ焼いた（2026-08-07。ネイティブの CC11 は帯の
        // 中なので退かせた）。この個体の EXPRESSION ジャックは無反応と実測済み
        // だが、番号としては Mod と同じ素通し席
        KeystageControl(
            name: "Expression ペダル", emits: .fixedCC(FaceKnobAssignment.expressionCC),
            handling: .passThrough,
            reserved: nil, provenance: .measured("2026-08-07")),
        KeystageControl(
            name: "Damper ペダル", emits: .fixedCC(FaceKnobAssignment.damperCC),
            handling: .both("踏んでいる間ノートを保持する"),
            reserved: "Sustain", provenance: .measured("2026-08-02")),
        KeystageControl(
            name: "EXIT", emits: .fixedCC(120), handling: .captured(.panic),
            reserved: "All Sound Off", provenance: .measured("2026-08-05")),

        // ── ノブ列（⚠️ 2026-08-07 まで表に無く、だから見落としていた） ──────
        //
        // ⭐ **位置固定の帯 CC0-63**（`KeystageKnobs`。ページ = CC ÷ 8 が正典）。
        // ノブは CC 番号フィールドを持たず、「デバイスが何ページ目か」で
        // 送る番号が決まる — **機材側の設定は要らない**。
        //
        // ⚠️ **帯は割当の有無に関わらず全部飲む**（#75）。番号の意味
        // （0=Bank Select MSB / 6=Data Entry MSB / 7=**Channel Volume**）は
        // **届かなければ無関係**になる。かつては「割当のある CC だけ横取り」で、
        // 素通しした CC7 が**回した瞬間に楽器の音量を飛ばした**
        // （実測 2026-08-07）。CC20-27 へ移す案はこの帯の確定で撤回済み
        KeystageControl(
            name: "ノブ 1-8", emits: .deviceAssigned("位置固定 CC0-63 = ページ × 8 + 位置（設定不要）"),
            handling: .captured(
                .held("帯は割当の有無に関わらず全部飲む — 割当があれば顔つまみを駆動、未割当はどこへも流さない")),
            reserved: "帯の中に Bank Select(0/32)・Data Entry(6)・Channel Volume(7) 等を含む（飲むので楽器へは届かない）",
            provenance: .measured("2026-08-07")),
        KeystageControl(
            name: "Pitch Bend ホイール", emits: .deviceAssigned("PB（CC ではない）"),
            handling: .both("割当があれば顔つまみへ / 無ければ楽器へ"),
            reserved: nil, provenance: .measured("2026-08-05")),
    ]

    /// **ページ送りに割り当てている CC → 向き**。
    ///
    /// ⚠️ **`MIDIRouter` はここを引く**（番号を直書きしない）。焼き直しても、
    /// 役割を別のボタンへ移しても、**保護が自動で付いてくる**
    static var pageStep: [Int: Int] {
        var out: [Int: Int] = [:]
        for control in all {
            guard case .captured(.pageStep(let direction)) = control.handling,
                let cc = control.cc
            else { continue }
            out[cc] = direction
        }
        return out
    }

    /// **楽器へ流さない CC**（`captured` のもの）。
    ///
    /// ⚠️ `passThrough` と `both` は含めない — 素通しは**正しい既定**で、
    /// Mod ホイールやペダルはそれで効いている
    static var interceptedCCs: Set<Int> {
        Set(all.filter(\.handling.isCaptured).compactMap(\.cc))
    }

    /// ⚠️ **素通ししている予約番号**（残っている危険）。画面と報告に出す
    static var passedThroughReserved: [KeystageControl] {
        all.filter { $0.handling == .passThrough && $0.reserved != nil }
    }

    static var measuredCount: Int { all.filter(\.provenance.isMeasured).count }
}
