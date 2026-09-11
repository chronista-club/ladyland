//! MIDI モードのモーター同期 — ladyland → ROTO の送信レーン（2026-08-12 起工）。
//!
//! 受信（ROTO のノブ → 席 CC → 顔つまみ経路）は開通済み。こちらは逆向き:
//! **パラメータの現在値を席 CC（ch1・7bit）で送り返し、モーターを追従させる**。
//! 追従自体は実機確認済み（2026-08-11 — 素の CC で動く。14bit 不要）。
//!
//! 発生源を選ばないのが要点 — Keystage / LPD8 / UI ドラッグ / スナップショット
//! 復元 / プラグイン UI、どこで値が変わってもモーターに出る。そのため
//! 変更箇所へのフックではなく **64 席の現在値を定期 diff** する
//! （`RotoSettingsView` の影ライブ表示と同じ、読むだけのポーリング作法）。
//!
//! ## 手と喧嘩しない
//!
//! 実機がいま喋った席（= 誰かが回している）へ送り返すと、モーターが手に
//! 逆らう。受信を帳簿に記録し、**その席は 0.3 秒黙る**。ホールドが明けても
//! バイトが一致していれば送らない — 連続パラメータは往復が正確
//! （byte → v/127 → ×127 → 同じ byte）なので通常は沈黙のまま。
//! 段付きパラメータは適用時に量子化されるので、明けた瞬間に**補正 1 発**が
//! 出てモーターが実際の値へ吸い付く（これは望む挙動）。
//!
//! ⚠️ 未検証: 表示中でないページ（矢印の先）の席へ送った CC を実機が
//! 覚えているか。忘れる個体挙動なら、ページを繰った直後のモーターが
//! 古い位置に見える — 実機で要確認（次回のプローブ課題）

import Foundation

/// 送受共通の「最後に見たバイト」帳簿と差分抽出。純粋ロジック（テスト対象）。
/// **レーン = チャンネル 1 本ぶんの帳簿** — 席レーン（ch1、CC0-63）と
/// ミキサーレーン（ch2、CC = スロット番号）でインスタンスを分けて使う
struct RotoMidiSync {
    /// 実機が喋った席を黙らせる長さ。ノブの値ストリームは ~11ms 間隔なので、
    /// 回している間はホールドが更新され続け、離してから明ける
    static let holdSeconds: TimeInterval = 0.3

    /// このレーンが扱う CC の集合
    private let seats: [Int]

    /// 席 CC → 最後に見たバイト（送信・受信の区別なし — どちらも「実機と
    /// 一致しているはずの値」で、違うときだけ送る）
    private var lastByte: [Int: UInt8] = [:]
    private var holdUntil: [Int: Date] = [:]

    init(seats: [Int] = KnobPages.all) {
        self.seats = seats
    }

    /// 実機から席 CC が届いた（= その席は実機側の手が持っている）
    mutating func noteReceived(cc: Int, value: UInt8, at now: Date = Date()) {
        guard seats.contains(cc) else { return }
        lastByte[cc] = value
        holdUntil[cc] = now.addingTimeInterval(Self.holdSeconds)
    }

    /// いま送るべき差分（席 CC とバイト）。
    /// - Parameter values: 席 CC → 正規化値 0-1（割当なし・レンジなしは nil）
    mutating func pendingSends(
        at now: Date = Date(), values: (Int) -> Double?
    ) -> [(cc: Int, byte: UInt8)] {
        var sends: [(cc: Int, byte: UInt8)] = []
        for cc in seats {
            if let hold = holdUntil[cc], hold > now { continue }
            guard let normalized = values(cc) else { continue }
            let byte = UInt8((min(max(normalized, 0), 1) * 127).rounded())
            guard lastByte[cc] != byte else { continue }
            lastByte[cc] = byte
            sends.append((cc, byte))
        }
        return sends
    }

    /// 送信済みの記憶だけ捨てる（定期リフレッシュ用）。**hold は残す** —
    /// 回し中の席へ古い値を送り返して手と喧嘩しないため。
    /// SEL 切替は無音なので、実機が「表示中の冊にしか受信 CC を適用しない」
    /// 挙動でも、これで冊を替えてから一巡でモーターが揃う
    mutating func forgetSent() {
        lastByte.removeAll()
    }

    /// 帳簿を破棄する（差し直し・切断時 — 実機の状態が信用できなくなった）
    mutating func reset() {
        lastByte.removeAll()
        holdUntil.removeAll()
    }
}
