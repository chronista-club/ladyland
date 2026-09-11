//! ノートのキープ（mako 裁定 2026-08-02「ペダルを踏んだら、Keystage の
//! 演奏中のキーボードをキープする。そうすれば音を途切れさせずにつまみがいじれる」）。
//!
//! **プラグインのサスティン解釈に頼らず、ホスト側で Note Off を握る。**
//! トリガーは**ダンパーペダル (CC64)** — 実機確認 2026-08-02 で、Keystage の
//! EXPRESSION ジャックは MIDI を出さず DAMPER ジャックが出た。
//! ペダルを踏んでいる間は鍵盤を離しても Note Off を送らないので、
//! 両手が空いてノブをいじれる。踏み替え（離す）で溜めた分をまとめて消す。
//!
//! 挙動はサスティンペダルと同じ意味論（よく知られた形に合わせる）:
//!   - 踏む前から押していた音 + 踏んでいる間に弾いた音、どちらもキープ
//!   - キープ中に同じ鍵を弾き直したら鳴らし直す（溜め置きから外す）
//!   - 離した瞬間、鍵を離してあった音だけ消す（まだ押している音は残る）
//!
//! しきい値にヒステリシスを入れる — ペダルの微振動で ON/OFF が
//! バタつくと、消える/残るが不安定になり本番で怖い。
//! スイッチ型（0/127 の 2 値）でもハーフダンパー型（連続値）でも同じ形で動く。

import Foundation

/// ノートのキープ — 純関数 state machine（テスト対象）
struct NoteLatch {
    /// 踏んだと見なす値（0-127）
    static let engageAt: UInt8 = 64
    /// 離したと見なす値（ヒステリシス — 一度踏んだらここまで戻さないと解除しない）
    static let releaseAt: UInt8 = 32

    private(set) var isEngaged = false

    /// いま物理的に押されている鍵（note → チャンネル）
    private var held: [UInt8: UInt8] = [:]
    /// 鍵は離されたが、キープで鳴らし続けている音
    private var sustained: [UInt8: UInt8] = [:]

    /// **いま指が乗っている鍵**（和音判定・登録用）。
    /// ⚠️ キープ中（`sustained`）の音は**含めない** — ペダルで溜まった音まで
    /// 拾うと和音が濁り、「今どのコードを押さえているか」が読めなくなる
    var heldNotes: [UInt8] { held.keys.sorted() }

    /// ノートオンを記録する（送出そのものは呼び手が行う）
    mutating func noteOn(_ note: UInt8, channel: UInt8) {
        // キープ中の同じ鍵を弾き直したら、溜め置きから外して押下側へ戻す
        sustained.removeValue(forKey: note)
        held[note] = channel
    }

    /// ノートオフを楽器へ送ってよいか。false = キープ中なので握りつぶす
    mutating func shouldSendNoteOff(_ note: UInt8) -> Bool {
        guard let channel = held.removeValue(forKey: note) else {
            // 押した記録が無い（キープ解除後の取りこぼし等）はそのまま通す
            return true
        }
        guard isEngaged else { return true }
        sustained[note] = channel
        return false
    }

    /// ペダルの値を反映する。**解除された瞬間に消すべきノート**を返す
    /// （返り値が空でも、踏み込み側の変化はここで確定している）
    mutating func pedal(_ value: UInt8) -> [(note: UInt8, channel: UInt8)] {
        if !isEngaged, value >= Self.engageAt {
            isEngaged = true
            return []
        }
        if isEngaged, value <= Self.releaseAt {
            isEngaged = false
            let release = sustained.map { (note: $0.key, channel: $0.value) }
                .sorted { $0.note < $1.note }
            sustained.removeAll()
            return release
        }
        return []
    }

    /// 仕切り直して、**宙に浮くはずだったノート**を返す。
    ///
    /// 返り値を捨てると音が残る: 呼び手は旧スロットへ Note Off を送ること。
    /// 以前は「切替作法の All Notes Off が消してくれる」前提で送出しなかったが、
    /// **送り先が変わらない経路（割当編集・同じタイルの再選択・LPD8 の
    /// プログラム読み込みなど）でも reset が走り、音が残った**（実機 2026-08-02）。
    /// AU が All Notes Off を honor する保証も無いので、自分で消す
    @discardableResult
    mutating func reset() -> [(note: UInt8, channel: UInt8)] {
        let orphaned = sustained.map { (note: $0.key, channel: $0.value) }
            .sorted { $0.note < $1.note }
        held.removeAll()
        sustained.removeAll()
        isEngaged = false
        return orphaned
    }

    /// 診断用: いまキープで鳴らし続けている音の数
    var sustainedCount: Int { sustained.count }
}
