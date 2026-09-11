//! 差分抑制の影 — 「最後に何を送ったか」の帳簿。
//!
//! RotoService から切り出した理由は**寿命の違いを見えるようにする**ため。
//! 表示の影（ここ）と PLUGIN 面の帳簿（`mappedCells` / `mappedNames`）は
//! 捨てる契機が別で、一緒に捨てると壊れる（RotoService の
//! `invalidateMappedCells` に実測の記録あり）。
//!
//! ⚠️ デバイスはモード切替のたびに表示を捨てる。そのときは影も捨てて
//! **全部送り直す** — 差分送信のままだと「変わっていない」と判断して
//! 何も送らず、空の面が残る。

import Foundation

/// 最後に送った表示内容の影（差分送信のための帳簿）。
///
/// 影が持つのは**送信を省く根拠**だけ。何を送るかは投影側が決める。
struct RotoShadow {
    /// 直近に送った/受けたモーター位置（14bit raw）。
    /// 自分の setValue が観測器で跳ね返る「自分の声のこだま」を抑止する
    var motorRaw: [Int: Int] = [:]

    /// **その値の出どころが「受信」であるセル**（mako 要望 2026-08-07）。
    ///
    /// ⚠️ `motorRaw` は**送信でも受信でも進む**（上の doc のとおり）ので、
    /// それだけでは「実機がそこに居る」のか「そこへ送っただけ」のかが
    /// **区別できない** — 今日 `FaceBelief` で向き合った病気と同じ形。
    ///
    /// 受信で裏が取れたセルだけここに入れる。⚠️ **送ったら外す**
    /// （送った時点で推定へ戻る）。表示専用で、送信の判断には使わない
    var motorObserved: Set<Int> = []

    /// 最後に送ったラベル（LedBus の shadow と同じ考え）。128 セルを毎回
    /// 送ると track 切替のたびに 640ms ぶんの SysEx が流れるので、**変わった
    /// セルだけ**送る。⚠️ デバイスはモード切替で表示を捨てるため、そのときは
    /// 影を破棄して全部送り直す（`invalidate`）
    var label: [Int: String] = [:]

    /// トラック表示の影（Logic 方言 = セル単位の直接書き込み）。
    /// **名前と色をまとめて**覚える — 名前だけだと選択が移ったときに
    /// 前の席の強調色が残る（色も表示の一部）
    var track: [Int: String] = [:]

    /// トラック表示の影（Bitwig 方言 = 枠付きバッチ）。
    /// バッチは分割できず**まとめて送るか送らないか**なので、影も 1 本で持つ
    var trackBatch: String?

    /// MENU 窓（左の LCD）に最後に送ったテキスト。0A 16 は未検証なので、
    /// 効かなくても他の投影を巻き込まないよう独立して持つ
    var menu: String?

    /// 影を捨てる = 次の投影で全セルを送り直す。
    ///
    /// ⚠️ PLUGIN 面の帳簿（RotoService の `mappedCells` / `mappedNames`）は
    /// **ここでは捨てない**。寿命が違う — 一緒に捨てていたときは、PLUGIN 面に
    /// いる最中に届く `0C 01`（MIXER 更新）で帳簿が消え、**名前の追従が一度も
    /// 走らなかった**（実測 2026-08-04）
    mutating func invalidate() {
        label.removeAll()
        track.removeAll()
        trackBatch = nil
        menu = nil
        motorRaw.removeAll()
    }

    /// SMART 面のページを繰ったときの部分破棄 — **中身が総入れ替えになる**ので
    /// ノブのラベルとモーター位置だけ捨てる。トラック / MENU の影は生きたまま
    mutating func invalidateSmartPage() {
        label.removeAll()
        motorRaw.removeAll()
    }

    /// モーター位置の差分判定（14bit raw で比べる — 丸めた後で同じなら送らない）。
    /// **判定と同時に影を進める**ので、false を返したときは何も動いていない
    mutating func motorChanged(_ ctrl: Int, _ value: Double, force: Bool) -> Bool {
        let raw = Int((min(max(value, 0), 1) * Double(RotoValue14.maximum)).rounded())
        guard force || motorRaw[ctrl] != raw else { return false }
        motorRaw[ctrl] = raw
        // ⚠️ **送ったら推定へ戻す** — 送信は「実機がそうなった」証拠にならない
        motorObserved.remove(ctrl)
        return true
    }
}
