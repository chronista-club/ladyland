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
    /// **時間軸の原点**（ナノ秒、`clock` の目盛り、`Int64` のビット列）— 位置が
    /// 最後に進み始めた時刻。エンジンが止まると `accumulatedNanos` へ畳む
    /// （design/11: 時間軸 = 原点と累積だけ。Pause は作らない）
    private let originNanos: UnsafeMutablePointer<UInt64>
    /// 原点より前に積んだ位置（ナノ秒、`Int64` のビット列）。<< >> もここを動かす
    private let accumulatedNanos: UnsafeMutablePointer<UInt64>
    /// transport の状態語。bit0 = エンジン稼働中（= 再生中）、bit1 = 録音待機
    private let stateBits: UnsafeMutablePointer<UInt64>
    private static let movingBit: UInt64 = 1 << 0
    private static let recordingBit: UInt64 = 1 << 1
    /// PLAY で頭を宣言済み（= 時間軸がある）
    private static let declaredBit: UInt64 = 1 << 2

    /// いまの時刻（ナノ秒）。render スレッドから呼ばれるので mach 時計
    /// （`DispatchTime` = mach_absolute_time 由来）。テストは差し替える
    private let clock: @Sendable () -> UInt64

    init(clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        bits = .allocate(capacity: 1)
        bits.initialize(to: 0)
        originNanos = .allocate(capacity: 1)
        originNanos.initialize(to: 0)
        accumulatedNanos = .allocate(capacity: 1)
        accumulatedNanos.initialize(to: 0)
        stateBits = .allocate(capacity: 1)
        stateBits.initialize(to: 0)
        self.clock = clock
    }

    deinit {
        bits.deallocate()
        originNanos.deallocate()
        accumulatedNanos.deallocate()
        stateBits.deallocate()
    }

    // MARK: - トランスポート（design/11）

    /// **再生中 = エンジンが回っている**。`InstrumentRack` が `engine.start()` の後 /
    /// `engine.stop()` の前に書く。Play ボタンはここを触らない
    var running: Bool {
        get { stateBits.pointee & Self.movingBit != 0 }
        set {
            guard newValue != running else { return }
            // 止まる: 進んだぶんを累積へ畳む。動く: 原点をいまに置く
            let now = Int64(clock())
            if declared {
                if newValue {
                    origin = now
                } else {
                    accumulated += now - origin
                    origin = now
                }
            }
            setState(Self.movingBit, newValue)
        }
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

    /// **PLAY = 小節の頭を宣言する**。いまを位置 0 とし、以後エンジンが回っている
    /// 間だけ進む
    func declareDownbeat() {
        accumulated = 0
        origin = Int64(clock())
        setState(Self.declaredBit, true)
    }

    /// **<< / >> = 頭を小節単位で置き直す**（mako 裁定 2026-10-10「それでいこう」）。
    /// 曲は無いので動かせるのは頭の位置だけ — >> は 1 小節先へ（フレーズの中で
    /// 1 小節進む）、<< は 1 小節戻る。位置は負にしない（0 で止まる）。
    /// 頭が未宣言 / テンポ不明なら何もしない。1 小節 = 4 拍（design/11、4/4 固定）
    func shiftDownbeat(bars: Int) {
        let raw = bits.pointee
        guard declared, raw != 0 else { return }
        let barNanos = Int64(4 * 60 / Double(bitPattern: raw) * 1_000_000_000)
        let now = Int64(clock())
        let live = running ? now - origin : 0
        accumulated = max(-live, accumulated + Int64(bars) * barNanos)
    }

    /// **STOP = 拍を 0 へ**（頭は未宣言に戻る = 時間軸を捨てる）
    func resetBeat() {
        setState(Self.declaredBit, false)
        accumulated = 0
    }

    /// 頭からの位置（秒）。未宣言なら nil。画面と 7 セグはここを読む
    var positionSeconds: Double? {
        guard declared else { return nil }
        return Double(positionNanos(now: Int64(clock()))) / 1_000_000_000
    }

    private var declared: Bool { stateBits.pointee & Self.declaredBit != 0 }
    private var origin: Int64 {
        get { Int64(bitPattern: originNanos.pointee) }
        set { originNanos.pointee = UInt64(bitPattern: newValue) }
    }
    private var accumulated: Int64 {
        get { Int64(bitPattern: accumulatedNanos.pointee) }
        set { accumulatedNanos.pointee = UInt64(bitPattern: newValue) }
    }

    /// 位置（ナノ秒）= 累積 + 動いている間の経過。render から呼ばれる —
    /// 語を 2 つ読むので最悪 1 ブロックぶん古い組み合わせを見るが、ロックは取らない
    private func positionNanos(now: Int64) -> Int64 {
        let raw = stateBits.pointee
        guard raw & Self.declaredBit != 0 else { return 0 }
        let live = raw & Self.movingBit != 0 ? now - origin : 0
        return max(0, accumulated + live)
    }

    /// 頭からの拍数（テンポ不明 / 未宣言なら 0）
    private func beatPosition(bpm: Double, now: UInt64) -> Double {
        Double(positionNanos(now: Int64(now))) / 1_000_000_000 * bpm / 60
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
    /// 拍位置は **PLAY で宣言した小節の頭**から数える（design/11）。Clock からは
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
