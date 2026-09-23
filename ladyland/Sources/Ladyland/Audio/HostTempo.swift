//! **ホストのテンポをプラグインへ渡す口**（mako 裁定 2026-08-05 / 修正 2026-09-23）。
//!
//! ## 口は 1 本、載せる前に 1 回だけ渡す
//!
//! 以前はテンポが変わるたびに `musicalContextBlock` を丸ごと差し替えていた
//! （「AU 側が差し替えを同期する」という前提）。**別プロセスの AUv3 は同期しない** —
//! スタジオ練習（2026-09-23）で 1 時間に約 10 回、MediSynth が render 中に
//! 解放済みの口を呼んで落ちた（`AUAudioUnit_XPC internalRenderBlock` → PC 0）。
//! Keystage の Clock から BPM を拾うので、差し替えは 0.1 秒おきに起きうる。
//!
//! いまは**ラックで 1 つの口**を、AU をエンジンへ繋ぐ前に渡すだけ。テンポは口の
//! 中から毎回読む。並べ替え・昇格で AU が席を移っても口はそのまま。
//!
//! ## render スレッドからの読み方
//!
//! 口は render スレッドから呼ばれるのでロックを取らない（優先度逆転）。BPM は
//! **64bit 1 語**（`Double` のビット列、0 = 同期なし）で持つ — 整列した 64bit の
//! 読み書きは arm64 / x86_64 で分断されないので、最悪でも 1 ブロック古い値を
//! 読むだけ（`Synchronization.Atomic` は macOS 15 から。最低ラインは 14）。

import AudioToolbox

final class HostTempo: @unchecked Sendable {
    /// `Double` のビット列。0 = 同期なし（プラグインは自前の既定で動く）
    private let bits: UnsafeMutablePointer<UInt64>

    init() {
        bits = .allocate(capacity: 1)
        bits.initialize(to: 0)
    }

    deinit {
        bits.deallocate()
    }

    /// いま渡しているテンポ。nil = 同期を切る
    var bpm: Double? {
        get {
            let raw = bits.pointee
            return raw == 0 ? nil : Double(bitPattern: raw)
        }
        set { bits.pointee = newValue.map(\.bitPattern) ?? 0 }
    }

    /// AU へ渡す口。**差し替えない**（上記）。同期なしのときは false を返し、
    /// プラグインに「ホストは知らない」と伝える。
    ///
    /// 拍位置は渡さない（Clock からは「テンポ」しか取れない — 小節の頭が
    /// どこかは分からない）。tempo だけでもディレイと LFO は同期する
    var musicalContextBlock: AUHostMusicalContextBlock {
        // self を強く掴む — 口を持つ AU が居る限り bits は解放されない
        { [self] currentTempo, numerator, denominator, beatPosition, sampleOffset,
            downbeatPosition in
            let raw = bits.pointee
            guard raw != 0 else { return false }
            currentTempo?.pointee = Double(bitPattern: raw)
            numerator?.pointee = 4
            denominator?.pointee = 4
            beatPosition?.pointee = 0
            sampleOffset?.pointee = 0
            downbeatPosition?.pointee = 0
            return true
        }
    }
}
