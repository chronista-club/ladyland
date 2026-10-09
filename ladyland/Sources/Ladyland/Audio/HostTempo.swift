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
    /// **小節の頭を宣言した時刻**（ナノ秒、`clock` の目盛り。**`Int64` のビット列** —
    /// << >> で頭を時計の 0 より前に置くことがある）。0 = 未宣言 → 拍は 0
    /// （design/09: PLAY = 小節の頭を宣言する）
    private let downbeatNanos: UnsafeMutablePointer<UInt64>
    /// transport の状態語。bit0 = エンジン稼働中（= 再生中）、bit1 = 録音待機
    private let stateBits: UnsafeMutablePointer<UInt64>
    private static let movingBit: UInt64 = 1 << 0
    private static let recordingBit: UInt64 = 1 << 1

    /// いまの時刻（ナノ秒）。render スレッドから呼ばれるので mach 時計
    /// （`DispatchTime` = mach_absolute_time 由来）。テストは差し替える
    private let clock: @Sendable () -> UInt64

    init(clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        bits = .allocate(capacity: 1)
        bits.initialize(to: 0)
        downbeatNanos = .allocate(capacity: 1)
        downbeatNanos.initialize(to: 0)
        stateBits = .allocate(capacity: 1)
        stateBits.initialize(to: 0)
        self.clock = clock
    }

    deinit {
        bits.deallocate()
        downbeatNanos.deallocate()
        stateBits.deallocate()
    }

    // MARK: - トランスポート（design/09）

    /// **再生中 = エンジンが回っている**。`InstrumentRack` が `engine.start()` の後 /
    /// `engine.stop()` の前に書く。Play ボタンはここを触らない
    var running: Bool {
        get { stateBits.pointee & Self.movingBit != 0 }
        set { setState(Self.movingBit, newValue) }
    }

    /// **録音待機**（REC のトグル。実録音はしない — mako 裁定 2026-10-09）
    var recordArmed: Bool {
        get { stateBits.pointee & Self.recordingBit != 0 }
        set { setState(Self.recordingBit, newValue) }
    }

    private func setState(_ bit: UInt64, _ on: Bool) {
        let raw = stateBits.pointee
        stateBits.pointee = on ? raw | bit : raw & ~bit
    }

    /// **PLAY = 小節の頭を宣言する**。いまを beat 0 とし、以後テンポで数える
    func declareDownbeat() {
        setDownbeat(Int64(clock()))
    }

    private var downbeat: Int64 { Int64(bitPattern: downbeatNanos.pointee) }
    /// 0 は「未宣言」の印なので、ちょうど 0 なら 1 ナノ秒ずらす
    private func setDownbeat(_ nanos: Int64) {
        downbeatNanos.pointee = UInt64(bitPattern: nanos == 0 ? 1 : nanos)
    }

    /// **<< / >> = 頭を小節単位で置き直す**（mako 裁定 2026-10-10「それでいこう」）。
    /// 曲は無いので動かせるのは頭の位置だけ — >> は頭を 1 小節ぶん手前へ
    /// （フレーズの中で 1 小節先へ進む）、<< は 1 小節ぶん先へ（1 小節戻る）。
    /// 頭が未来に行くなら「いま」に揃える（拍 0。負の拍は作らない）。
    /// 未宣言なら何もしない。1 小節 = 4 拍（design/09、4/4 固定）
    func shiftDownbeat(bars: Int) {
        let raw = bits.pointee
        guard downbeatNanos.pointee != 0, raw != 0 else { return }
        let bpm = Double(bitPattern: raw)
        let barNanos = Int64(4 * 60 / bpm * 1_000_000_000)
        let now = Int64(clock())
        setDownbeat(min(now, downbeat - Int64(bars) * barNanos))
    }

    /// **STOP = 拍を 0 へ**（頭は未宣言に戻る）
    func resetBeat() {
        downbeatNanos.pointee = 0
    }

    /// 頭からの拍数（テンポが分からない / 頭が未宣言なら 0）
    private func beatPosition(bpm: Double, now: UInt64) -> Double {
        guard downbeatNanos.pointee != 0 else { return 0 }
        let elapsed = Int64(now) - downbeat
        guard elapsed > 0 else { return 0 }
        return Double(elapsed) / 1_000_000_000 * bpm / 60
    }

    /// AU へ渡す transport の口。**差し替えない**（`musicalContextBlock` と同じ理由）。
    /// サンプル位置は渡さない（拍で足りる。レートを render から読まずに済む）
    var transportStateBlock: AUHostTransportStateBlock {
        { [self] flags, currentSamplePosition, cycleStart, cycleEnd in
            let raw = stateBits.pointee
            var out = AUHostTransportStateFlags()
            if raw & Self.movingBit != 0 { out.insert(.moving) }
            if raw & Self.recordingBit != 0 { out.insert(.recording) }
            flags?.pointee = out
            currentSamplePosition?.pointee = 0
            cycleStart?.pointee = 0
            cycleEnd?.pointee = 0
            return true
        }
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
    /// 拍位置は **PLAY で宣言した小節の頭**から数える（design/09）。Clock からは
    /// テンポしか取れないので、頭は手で教える。未宣言なら 0（従来どおり）。
    /// 拍子は 4/4 固定
    var musicalContextBlock: AUHostMusicalContextBlock {
        // self を強く掴む — 口を持つ AU が居る限り bits は解放されない
        { [self] currentTempo, numerator, denominator, beatPosition, sampleOffset,
            downbeatPosition in
            let raw = bits.pointee
            guard raw != 0 else { return false }
            let bpm = Double(bitPattern: raw)
            let beat = self.beatPosition(bpm: bpm, now: clock())
            currentTempo?.pointee = bpm
            numerator?.pointee = 4
            denominator?.pointee = 4
            beatPosition?.pointee = beat
            sampleOffset?.pointee = 0
            downbeatPosition?.pointee = (beat / 4).rounded(.down) * 4
            return true
        }
    }
}
