//! トランスポート（mako 裁定 2026-10-09「Aで進めよう」、design/09）。
//!
//! Ladyland に曲は無い。**再生中 = エンジンが回っている**で、Play ボタンは
//! エンジンを動かさない。PLAY = 小節の頭を宣言する（beat 0 から数え直す）、
//! STOP = パニック + beat 0、REC = 録音待機の ON/OFF。
//! 機材（nanoKONTROL2 の CC / X-Touch の MCU Note）は共通の `TransportAction` に
//! 読み替えてから 1 本の口へ流す。

import AudioToolbox
import Testing

@testable import Ladyland

@Suite("トランスポートの読み替え")
struct TransportMappingTests {
    @Test("nanoKONTROL2 の右下 5 つ（押下だけ）")
    func nanoKontrolButtons() {
        #expect(Transport.action(nanoKontrolCC: 43, value: 127) == .rewind)
        #expect(Transport.action(nanoKontrolCC: 44, value: 127) == .fastForward)
        #expect(Transport.action(nanoKontrolCC: 42, value: 127) == .stop)
        #expect(Transport.action(nanoKontrolCC: 41, value: 127) == .play)
        #expect(Transport.action(nanoKontrolCC: 45, value: 127) == .record)
    }

    @Test("解放（value 0）と無関係の CC は何もしない")
    func nanoKontrolIgnoresReleaseAndOthers() {
        #expect(Transport.action(nanoKontrolCC: 41, value: 0) == nil)
        #expect(Transport.action(nanoKontrolCC: 0, value: 127) == nil)   // フェーダー
        #expect(Transport.action(nanoKontrolCC: 46, value: 127) == nil)  // CYCLE は未定義
    }

    @Test("X-Touch（Mackie Control）の Note 0x5B〜0x5F")
    func mackieNotes() {
        #expect(Transport.action(mackieNote: 0x5B, velocity: 127) == .rewind)
        #expect(Transport.action(mackieNote: 0x5C, velocity: 127) == .fastForward)
        #expect(Transport.action(mackieNote: 0x5D, velocity: 127) == .stop)
        #expect(Transport.action(mackieNote: 0x5E, velocity: 127) == .play)
        #expect(Transport.action(mackieNote: 0x5F, velocity: 127) == .record)
        #expect(Transport.action(mackieNote: 0x5E, velocity: 0) == nil)
        #expect(Transport.action(mackieNote: 0x60, velocity: 127) == nil)
    }
}

@Suite("ホストの拍")
struct HostBeatTests {
    /// 時計を差し替えた HostTempo（render スレッドと同じ口を呼ぶ）
    private final class Clock: @unchecked Sendable {
        var now: UInt64 = 1_000_000_000
    }

    /// エンジンは回っている前提（再生中 = running。止まっているときの挙動は別テスト）
    private func make(bpm: Double? = 120, running: Bool = true) -> (HostTempo, Clock) {
        let clock = Clock()
        let tempo = HostTempo(clock: { clock.now })
        tempo.bpm = bpm
        tempo.running = running
        return (tempo, clock)
    }

    private func beats(_ tempo: HostTempo) -> (ok: Bool, beat: Double, downbeat: Double) {
        var beat = 0.0
        var downbeat = 0.0
        let ok = tempo.musicalContextBlock(nil, nil, nil, &beat, nil, &downbeat)
        return (ok, beat, downbeat)
    }

    private func transport(_ tempo: HostTempo) -> (ok: Bool, flags: AUHostTransportStateFlags) {
        var flags = AUHostTransportStateFlags()
        let ok = tempo.transportStateBlock(&flags, nil, nil, nil)
        return (ok, flags)
    }

    @Test("頭を宣言するまで拍は 0 のまま")
    func beatIsZeroUntilDownbeat() {
        let (tempo, clock) = make()
        clock.now += 5_000_000_000
        #expect(beats(tempo).beat == 0)
    }

    @Test("PLAY = 頭を宣言 → 120 BPM で 1 秒後は 2 拍目、2.5 秒後は 5 拍目で小節は 4")
    func beatCountsFromDownbeat() {
        let (tempo, clock) = make(bpm: 120)
        tempo.declareDownbeat()

        clock.now += 1_000_000_000
        let one = beats(tempo)
        #expect(one.ok)
        #expect(abs(one.beat - 2.0) < 1e-9)
        #expect(one.downbeat == 0)

        clock.now += 1_500_000_000
        let two = beats(tempo)
        #expect(abs(two.beat - 5.0) < 1e-9)
        #expect(two.downbeat == 4)
    }

    @Test(">> = 頭を 1 小節ぶん手前へ置き直す → フレーズの中で 1 小節先に進む")
    func fastForwardMovesOneBarAhead() {
        let (tempo, clock) = make(bpm: 120)  // 1 小節 = 4 拍 = 2 秒
        tempo.declareDownbeat()
        clock.now += 1_000_000_000  // 2 拍目
        tempo.shiftDownbeat(bars: 1)
        let r = beats(tempo)
        #expect(abs(r.beat - 6.0) < 1e-9)
        #expect(r.downbeat == 4)
    }

    @Test("<< = 頭を 1 小節ぶん先に置き直す → 1 小節戻る。頭より前には行かない（0 で止まる）")
    func rewindMovesOneBarBackAndClampsAtZero() {
        let (tempo, clock) = make(bpm: 120)
        tempo.declareDownbeat()
        clock.now += 5_000_000_000  // 10 拍目（3 小節目）
        tempo.shiftDownbeat(bars: -1)
        #expect(abs(beats(tempo).beat - 6.0) < 1e-9)

        tempo.shiftDownbeat(bars: -1)
        #expect(abs(beats(tempo).beat - 2.0) < 1e-9)

        // もう 1 小節戻すと頭が未来になる → いま = 頭（拍 0）に揃える
        tempo.shiftDownbeat(bars: -1)
        #expect(beats(tempo).beat == 0)
        clock.now += 500_000_000
        #expect(abs(beats(tempo).beat - 1.0) < 1e-9, "揃えた頭から数え直す")
    }

    @Test("頭が未宣言なら << >> は何もしない")
    func shiftWithoutDownbeatIsNoop() {
        let (tempo, clock) = make()
        tempo.shiftDownbeat(bars: 1)
        clock.now += 1_000_000_000
        #expect(beats(tempo).beat == 0)
    }

    @Test("STOP = 拍を 0 へ戻す")
    func resetReturnsToZero() {
        let (tempo, clock) = make()
        tempo.declareDownbeat()
        clock.now += 3_000_000_000
        tempo.resetBeat()
        clock.now += 3_000_000_000
        #expect(beats(tempo).beat == 0)
    }

    @Test("テンポが分からなければ拍も数えない（口は false）")
    func noTempoNoBeat() {
        let (tempo, clock) = make(bpm: nil)
        tempo.declareDownbeat()
        clock.now += 1_000_000_000
        let r = beats(tempo)
        #expect(r.ok == false)
    }

    @Test("時間軸 = 原点と累積。エンジンが止まっている間は位置が進まず、再開で続きから")
    func positionFreezesWhileEngineStopped() {
        let (tempo, clock) = make(bpm: 120)
        tempo.declareDownbeat()
        clock.now += 1_000_000_000  // 2 拍
        tempo.running = false
        clock.now += 10_000_000_000  // 止まっている 10 秒は数えない
        #expect(abs(beats(tempo).beat - 2.0) < 1e-9)
        #expect(abs((tempo.positionSeconds ?? -1) - 1.0) < 1e-9)
        tempo.running = true
        clock.now += 500_000_000  // さらに 1 拍
        #expect(abs(beats(tempo).beat - 3.0) < 1e-9)
    }

    @Test("位置（秒）は頭を宣言するまで nil、STOP で nil に戻る")
    func positionSecondsLifecycle() {
        let (tempo, clock) = make()
        #expect(tempo.positionSeconds == nil)
        tempo.declareDownbeat()
        clock.now += 2_000_000_000
        #expect(abs((tempo.positionSeconds ?? -1) - 2.0) < 1e-9)
        tempo.resetBeat()
        #expect(tempo.positionSeconds == nil)
    }

    @Test("再生中 = エンジンが回っている。transport の口は moving を返す")
    func movingFollowsEngine() {
        let (tempo, _) = make(running: false)
        #expect(transport(tempo).flags.contains(.moving) == false)
        tempo.running = true
        let r = transport(tempo)
        #expect(r.ok)
        #expect(r.flags.contains(.moving))
        tempo.running = false
        #expect(transport(tempo).flags.contains(.moving) == false)
    }

    @Test("REC = 録音待機。transport の口に recording が立つ（実録音はしない）")
    func recordArmFlag() {
        let (tempo, _) = make()
        #expect(transport(tempo).flags.contains(.recording) == false)
        tempo.recordArmed = true
        #expect(transport(tempo).flags.contains(.recording))
        tempo.recordArmed = false
        #expect(transport(tempo).flags.contains(.recording) == false)
    }
}


@Suite("トランスポートの読み出し（画面 / 7 セグ用）")
struct TransportReadoutTests {
    @Test("頭が無ければ何も出さない")
    func nothingWithoutHead() {
        #expect(TransportReadout.make(positionSeconds: nil, bpm: 120, recordArmed: false) == nil)
    }

    @Test("小節.拍は 1 から数える — 0 秒 = 1.1、120 BPM で 2.5 秒 = 5 拍目 = 2 小節 2 拍目")
    func barsAndBeatsAreOneBased() {
        let a = TransportReadout.make(positionSeconds: 0, bpm: 120, recordArmed: false)
        #expect(a?.bar == 1)
        #expect(a?.beat == 1)
        let b = TransportReadout.make(positionSeconds: 2.5, bpm: 120, recordArmed: true)
        #expect(b?.bar == 2)
        #expect(b?.beat == 2)
        #expect(b?.recordArmed == true)
        #expect(b?.barBeatText == "2.2")
    }

    @Test("テンポが無ければ拍は出さず、経過時間だけ出す")
    func elapsedWithoutTempo() {
        let r = TransportReadout.make(positionSeconds: 125, bpm: nil, recordArmed: false)
        #expect(r?.bar == nil)
        #expect(r?.elapsedText == "2:05")
        #expect(r?.barBeatText == nil)
    }
}
