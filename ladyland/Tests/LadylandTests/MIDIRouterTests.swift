//! MIDIRouter の顔つまみ CC 横取りのテスト（P4）。
//!
//! Keystage のノブ CC は鍵盤と同じポートに届く（ページ = CC ÷ 8、位置固定）。
//! ⭐ **現在の契約: ノブ帯（CC0-63）は割当の有無に関わらず全部飲む**
//! （#75、`KeystageKnobs`）— 未割当ノブは楽器に届かない。素通しは帯の外だけ
//! （Mod = CC116 / Damper = CC64 など）。
//! ⚠️ かつては「割当のある CC だけ横取りし、CC1 = Mod は素通し」という
//! 逆向きの契約だった — Mod を CC116 へ焼いて帯の外へ退かせたことで反転した。

import Testing

@testable import Ladyland

/// handler 呼び出しの記録箱（routeKeyboard は同期呼び出しなのでロック不要)
private final class Received: @unchecked Sendable {
    var events: [(cc: UInt8, value: UInt8)] = []
}

@Suite("MIDIRouter 顔つまみ分岐")
struct MIDIRouterTests {
    @Test("割当のある CC は横取りされ handler に届く")
    func mappedCCGoesToHandler() {
        let router = MIDIRouter()
        let received = Received()
        router.setKnobRouting(ccs: [0, 3]) { received.events.append((cc: $0, value: $1)) }

        router.routeKeyboard(0xB0, 3, 100)

        #expect(received.events.count == 1)
        #expect(received.events.first?.cc == 3)
        #expect(received.events.first?.value == 100)
    }

    /// ⚠️ **契約は 2026-08-07 に反転した**（#75）。かつては「割当のない CC は
    /// 楽器へ素通し — CC1 = Mod を生かす」だったが、Mod を CC116 へ焼いて
    /// 帯の外へ退かせ、**帯は割当が無くても飲む**が現在の契約
    @Test("帯は割当が無くても飲む / 帯の外（Mod CC116）は楽器へ通る")
    func unmappedCCPassesThrough() {
        let router = MIDIRouter()
        let received = Received()
        final class Sink: @unchecked Sendable { var toInstrument: [(UInt8, UInt8)] = [] }
        let sink = Sink()
        router.setKnobRouting(ccs: [0]) { received.events.append((cc: $0, value: $1)) }
        router.setTraceHandler { route in
            if case .keyboard(_, let d1, let d2, _) = route {
                sink.toInstrument.append((d1, d2))
            }
        }

        router.routeKeyboard(0xB0, 1, 64)  // 帯の席（割当なし。かつての Mod 番号）
        #expect(received.events.isEmpty, "割当が無ければ顔つまみへは行かない")
        #expect(sink.toInstrument.isEmpty, "帯は飲む — 楽器へも行かない")

        // 帯の外 = 素通しが正しい既定（Mod ホイールはここで効く）
        router.routeKeyboard(0xB0, UInt8(FaceKnobAssignment.modWheelCC), 64)
        #expect(received.events.isEmpty)
        #expect(sink.toInstrument.count == 1, "Mod（CC116）は楽器へ素通し")
    }

    @Test("CC 以外（ノートオン）は割当番号と同じ data1 でも横取りされない")
    func noteOnIsNeverIntercepted() {
        let router = MIDIRouter()
        let received = Received()
        router.setKnobRouting(ccs: [60]) { received.events.append((cc: $0, value: $1)) }

        router.routeKeyboard(0x90, 60, 100)  // ノート C4 — data1 が割当番号と一致しても素通り

        #expect(received.events.isEmpty)
    }

    @Test("チャンネル不問で横取りする（Keystage のノブ ch は Scene 設定次第）")
    func interceptsOnAnyChannel() {
        let router = MIDIRouter()
        let received = Received()
        router.setKnobRouting(ccs: [5]) { received.events.append((cc: $0, value: $1)) }

        router.routeKeyboard(0xB0, 5, 10)  // ch1
        router.routeKeyboard(0xBF, 5, 20)  // ch16

        #expect(received.events.count == 2)
    }

    @Test("割当を空にすると横取りが止まる")
    func clearingStopsInterception() {
        let router = MIDIRouter()
        let received = Received()
        router.setKnobRouting(ccs: [0]) { received.events.append((cc: $0, value: $1)) }
        router.routeKeyboard(0xB0, 0, 1)
        #expect(received.events.count == 1)

        router.setKnobRouting(ccs: [], handler: nil)
        router.routeKeyboard(0xB0, 0, 2)
        #expect(received.events.count == 1)
    }
}

/// **ページ送りの CC が楽器へ届かないこと**（mako 2026-08-07
/// 「ページ送りの素通しは、こちら直さないとだね」）。
///
/// ⚠️ 実バグは `data2 > 0` を条件に入れていたせいで**解放（値 0）だけ
/// 素通し**していたこと。実機ログに `CC96 = 0 → slot 22` が出ていた。
/// **これらは MIDI 予約番号**（Data Inc/Dec・NRPN）なので、素通しは
/// AU のパラメータを書き換えうる。
@Suite("ページ送りの素通し")
struct PageStepPassThroughTests {
    private final class Sink: @unchecked Sendable {
        var steps: [Int] = []
        var toInstrument: [(UInt8, UInt8)] = []
    }

    private func router(_ sink: Sink) -> MIDIRouter {
        let router = MIDIRouter()
        router.setPageStepHandler { sink.steps.append($0) }
        router.setTraceHandler { route in
            if case .keyboard(_, let data1, let data2, _) = route {
                sink.toInstrument.append((data1, data2))
            }
        }
        return router
    }

    /// ⭐ **本題** — 横取り対象は押下も解放も楽器へ行かない
    @Test("横取りする CC は楽器へ届かない（押下も解放も）")
    func interceptedNeverReachInstrument() {
        let sink = Sink()
        let midi = router(sink)
        for cc in KeystageControls.interceptedCCs {
            midi.routeKeyboard(0xB9, UInt8(cc), 127)
            midi.routeKeyboard(0xB9, UInt8(cc), 0)
        }
        #expect(sink.toInstrument.isEmpty, "楽器へ流れた: \(sink.toInstrument)")
    }

    /// ⚠️ **横取りしすぎていない** — 未割当 CC が通るのは正しい既定
    @Test("表に無い CC は今まで通り楽器へ届く")
    func unlistedCCsStillPassThrough() {
        let sink = Sink()
        let midi = router(sink)
        // ⚠️ 表に無い番号を選ぶ（固定値ではなく、表から外れているものを探す）。
        // ⚠️ **ノブ帯も外す** — 帯は割当が無くても飲むので、ここに混ざると
        // 「素通しが死んだ」に見えてしまう（2026-08-07 に base=0 で踏んだ）
        let free = (1...127).filter {
            !KeystageControls.interceptedCCs.contains($0)
                && !KeystageKnobs.intercepted.contains($0)
        }
        for cc in free.prefix(5) {
            midi.routeKeyboard(0xB0, UInt8(cc), 64)
        }
        #expect(sink.toInstrument.count >= 3, "未割当が届かない = 横取りしすぎ")
    }

    /// **押下 + 解放で 1 ページだけ**（一度踏んだ罠）
    @Test("押下と解放を流しても 1 つしか動かない")
    func releaseDoesNotStepAgain() {
        let sink = Sink()
        let midi = router(sink)
        let cc = try! #require(KeystageControls.pageStep.first?.key)
        midi.routeKeyboard(0xB9, UInt8(cc), 127)
        midi.routeKeyboard(0xB9, UInt8(cc), 0)
        #expect(sink.steps.count == 1, "解放では動かない")
    }

    /// ⚠️ **チャンネルを見ない**（実測 2026-08-07: 同じ列でも Play だけ ch3
    /// という状態が起きていた。揃っている前提で書くと次にずれたとき黙って死ぬ）
    @Test("チャンネルが違っても効く")
    func channelAgnostic() {
        let sink = Sink()
        let midi = router(sink)
        let cc = try! #require(KeystageControls.pageStep.first?.key)
        midi.routeKeyboard(0xB2, UInt8(cc), 127)  // ch3
        midi.routeKeyboard(0xB9, UInt8(cc), 127)  // ch10
        #expect(sink.steps.count == 2)
    }

    /// **役割が無くても捕まえる席は動かさない**（Play/Stop = Data Inc/Dec）
    @Test("役割の無い横取り席はページを動かさない")
    func heldControlsDoNotStep() {
        let sink = Sink()
        let midi = router(sink)
        let held = KeystageControls.all.filter {
            if case .captured(.held) = $0.handling { return true }
            return false
        }
        #expect(!held.isEmpty, "確保している席が表に無い")
        for control in held {
            guard let cc = control.cc else { continue }
            midi.routeKeyboard(0xB9, UInt8(cc), 127)
        }
        #expect(sink.steps.isEmpty, "確保しているだけの席でページが動いた")
        #expect(sink.toInstrument.isEmpty, "確保している席が楽器へ流れた")
    }
}

@Suite("トラックナビ（VALUE エンコーダー）")
struct TrackNavTests {
    @Test("役割の振り分け — ロータリー(PC)=トラック / 焼いた CC96,97=ページ")
    func navInterception() {
        let router = MIDIRouter()
        final class Received: @unchecked Sendable {
            var directions: [Int] = []
        }
        let received = Received()
        // **ch16 の Native 通知で役割が分かれている**（実装チャート L1070-1083）:
        //   3A / 3B = NEXT / PREVIOUS TRACK  → ROTO のページ送り
        //   3C / 3D = VALUE の上下ボタン      → 使わない
        //   3E / 3F = VALUE ノブの回転        → トラック移動
        //
        // ⚠️ 3E/3F を「上下ボタン」と読んで捨てていたが、チャートには
        // **「turn VALUE KNOB left / right」**と明記されている
        final class Nav: @unchecked Sendable { var directions: [Int] = [] }
        let nav = Nav()
        router.setPageStepHandler { received.directions.append($0) }
        router.setNavHandler { direction, _ in nav.directions.append(direction) }

        // **ロータリーは Program Change**（Assignable では ch16 通知が来ない）。
        // 初回は基準取りで動かさない
        for program: UInt8 in [70, 71, 72, 71] {
            router.routeKeyboard(0xC9, program, 0)
        }
        #expect(nav.directions == [+1, +1, -1], "ロータリーはトラック移動")

        // **ページ送りは焼いた CC**。⚠️ **番号を直書きしない** —
        // `KeystageControls` から引く（2026-08-07 に実際に番号が動いた。
        // 直書きしていたらこの瞬間に壊れていた）。
        // ⚠️ ch16 の Native 通知（3A/3B = NEXT/PREV TRACK）は **Native Mode
        // 専用で来ない** — Assignable では焼いた CC しか出ない
        let forward = try! #require(KeystageControls.pageStep.first { $0.value == 1 }?.key)
        let back = try! #require(KeystageControls.pageStep.first { $0.value == -1 }?.key)
        router.routeKeyboard(0xB2, UInt8(forward), 127)  // 次のページ（ch はまちまち）
        router.routeKeyboard(0xB9, UInt8(back), 127)  // 前のページ
        router.routeKeyboard(0xB2, UInt8(forward), 0)  // 解放は無視
        #expect(received.directions == [+1, -1], "焼いたボタンがページ送り")

        router.routeKeyboard(0xBF, 0x3C, 0x7F)  // VALUE の上下ボタンは使わない
        router.routeKeyboard(0xBF, 0x3D, 0x7F)
        #expect(received.directions == [+1, -1], "上下ボタンでは何も起きない")
    }

    @Test("ch16 以外の CC62/63 はページ送りにならない（楽器の通常 CC）")
    func otherChannelsPassThrough() {
        let router = MIDIRouter()
        final class Received: @unchecked Sendable {
            var directions: [Int] = []
        }
        let received = Received()
        router.setPageStepHandler { received.directions.append($0) }

        router.routeKeyboard(0xB0, 0x3E, 0x7F)  // ch1 の CC62 — ページ送りではない
        #expect(received.directions.isEmpty)
    }

    @Test("スロットルは最小間隔未満のパルスを捨てる")
    func throttle() {
        var throttle = TrackNavThrottle(minIntervalNs: 150_000_000)
        let first = throttle.shouldStep(nowNs: 1_000_000_000)
        let after50ms = throttle.shouldStep(nowNs: 1_050_000_000)
        let after149ms = throttle.shouldStep(nowNs: 1_149_000_000)
        let after151ms = throttle.shouldStep(nowNs: 1_151_000_000)
        let rightAfter = throttle.shouldStep(nowNs: 1_200_000_000)
        #expect(first)
        #expect(!after50ms, "50ms 後は捨てる")
        #expect(!after149ms, "149ms 後も捨てる")
        #expect(after151ms, "151ms 後は 1 歩")
        #expect(!rightAfter, "直後はまた捨てる")
    }

    // MARK: - Program Change は使わない（mako 裁定 2026-08-05）

    @Test("受け口が無ければ Program Change は捨てる — 楽器へも流さない")
    func programChangeDiscarded() {
        // ⚠️ 楽器へ流すと回すたびにプラグインのプリセットが変わる
        // （実測 2026-08-05: Firenze が勝手に切り替わった）。
        // **受け口が無いときも食い止める**
        let router = MIDIRouter()
        final class Received: @unchecked Sendable {
            var routes: [MidiRoute] = []
        }
        let received = Received()
        router.setTraceHandler { received.routes.append($0) }

        for program: UInt8 in [72, 71, 70, 127, 0] {
            router.routeKeyboard(0xC9, program, 0)
        }
        #expect(received.routes.isEmpty, "トレースにも出ない（黙って捨てる）")
    }

    // MARK: - キープの取りこぼし（実機 2026-08-02「音が一度のこりました」）

    @Test("送り先が変わらない updateRouting ではキープの帳簿を消さない")
    func repeatedTargetSetKeepsLatch() {
        let router = MIDIRouter()
        final class Seen: @unchecked Sendable { var held = 0 }
        let seen = Seen()
        router.setTraceHandler { route in
            if case .latchHold = route { seen.held += 1 }
        }

        router.routeKeyboard(0x90, 60, 100)      // 押す
        router.routeKeyboard(0xB0, 64, 127)      // ダンパーを踏む
        router.routeKeyboard(0x80, 60, 0)        // 鍵を離す → キープされる
        #expect(seen.held == 1)

        // 割当編集・同じタイルの再選択などで updateRouting が走る状況。
        // 送り先は変わっていないので帳簿は生きているべき
        router.setKeyboardTarget(nil)
        router.setKeyboardTarget(nil)

        // ペダルを離せばちゃんと消える（帳簿が生きている証拠）
        router.routeKeyboard(0x90, 62, 100)
        router.routeKeyboard(0x80, 62, 0)
        #expect(seen.held == 2, "キープが継続していること")
    }
}

/// **VALUE エンコーダーのトラック移動**（mako 実機報告 2026-08-07
/// 「現在は動かないね」）。
///
/// ⚠️ 実機ログは **ch1** で来ている:
///
///     keystage: [受信] ch1 Program Change 29
///     keystage: [受信] ch1 Program Change 30 …
///
/// 他のボタン（102-110）は ch10 なのに **VALUE だけ ch1**。
/// ⚠️ **ch を見込むと、mako が機材側を触ったときにまた壊れる**
@Suite("VALUE エンコーダー（Program Change）")
struct ValueNavTests {
    private final class Sink: @unchecked Sendable {
        var directions: [Int] = []
        var throttledFlags: [Bool] = []
        var instrumentEvents = 0
    }

    /// ⭐ **実機の並びをそのまま流す**
    @Test("ch1 の Program Change でトラックが移動する")
    func programChangeOnChannel1Moves() {
        let router = MIDIRouter()
        let sink = Sink()
        router.setNavHandler { direction, _ in sink.directions.append(direction) }

        // ⚠️ **初回は基準取り**（いきなり飛ばさない）
        for program: UInt8 in [29, 30, 31, 32] {
            router.routeKeyboard(0xC0, program, 0)  // ch1
        }
        #expect(sink.directions == [+1, +1, +1], "29 → 32 で 3 歩進む")
    }

    /// 逆回し
    @Test("逆に回すと逆方向へ動く")
    func reverseMovesBack() {
        let router = MIDIRouter()
        let sink = Sink()
        router.setNavHandler { direction, _ in sink.directions.append(direction) }
        for program: UInt8 in [32, 31, 30, 29] {
            router.routeKeyboard(0xC0, program, 0)
        }
        #expect(sink.directions == [-1, -1, -1])
    }

    /// ⚠️ **ch を限定していないこと**を固定する。
    /// mako が機材側の ch を変えられるので、**見込むとまた壊れる**
    @Test("どのチャンネルの Program Change でも効く", arguments: [
        UInt8(0xC0), UInt8(0xC9), UInt8(0xCF),
    ])
    func anyChannelWorks(status: UInt8) {
        let router = MIDIRouter()
        let sink = Sink()
        router.setNavHandler { direction, _ in sink.directions.append(direction) }
        router.routeKeyboard(status, 10, 0)  // 基準
        router.routeKeyboard(status, 11, 0)
        #expect(sink.directions == [+1], "ch \(status & 0x0F) で動かない")
    }

    /// ⭐ **これが実機で「動かない」の正体**（mako 報告 2026-08-07）。
    ///
    /// Program Change は **1 メッセージ = 1 クリック**で、差分がそのまま
    /// 歩数（`programDelta`）。⚠️ **間引くと速く回したぶんが丸ごと消える** —
    /// 150ms のスロットルに掛かって、実機ではまったく動かなく見えていた
    @Test("Program Change は「間引かない」と申告する")
    func programChangeIsNotThrottled() {
        let router = MIDIRouter()
        let sink = Sink()
        router.setNavHandler { _, throttled in sink.throttledFlags.append(throttled) }
        router.routeKeyboard(0xC0, 29, 0)  // 基準
        router.routeKeyboard(0xC0, 30, 0)
        router.routeKeyboard(0xC0, 31, 0)
        #expect(sink.throttledFlags == [false, false], "PC を間引く側に回している")
    }

    /// ⚠️ **CC117/118 は押しっぱなしで連打しうる**ので、そちらは間引く
    @Test("CC117/118 は「間引く」と申告する")
    func encoderIsThrottled() {
        let router = MIDIRouter()
        let sink = Sink()
        router.setNavHandler { _, throttled in sink.throttledFlags.append(throttled) }
        router.routeKeyboard(0xB9, 118, 127)
        router.routeKeyboard(0xB9, 117, 127)
        #expect(sink.throttledFlags == [true, true])
    }

    /// ⚠️ **PC は楽器へ流さない** — 流すと回すたびにプリセットが変わる
    /// （実測 2026-08-05: Firenze が勝手に切り替わった）
    @Test("Program Change は楽器へ届かない")
    func programChangeNeverReachesInstrument() {
        let router = MIDIRouter()
        let sink = Sink()
        router.setNavHandler { direction, _ in sink.directions.append(direction) }
        router.setTraceHandler { route in
            if case .keyboard = route { sink.instrumentEvents += 1 }
        }
        router.routeKeyboard(0xC0, 29, 0)
        router.routeKeyboard(0xC0, 30, 0)
        #expect(sink.instrumentEvents == 0, "PC が楽器へ流れた")
    }

    /// ⚠️ **受け口が無くても楽器へは流さない**（素通しの方が害が大きい）
    @Test("受け口が無くても素通ししない")
    func swallowsEvenWithoutHandler() {
        let router = MIDIRouter()
        let sink = Sink()
        router.setTraceHandler { route in
            if case .keyboard = route { sink.instrumentEvents += 1 }
        }
        router.routeKeyboard(0xC0, 29, 0)
        #expect(sink.instrumentEvents == 0)
    }
}

@Suite("MIDI Clock から BPM")
struct MidiClockTrackerTests {
    /// 24 tick = 四分音符 1 つ。BPM から 1 tick の間隔（ナノ秒）を出す
    private func tickInterval(bpm: Double) -> UInt64 {
        UInt64(60 / bpm / Double(MidiClockTracker.ticksPerBeat) * 1_000_000_000)
    }

    /// 等間隔で n 個流して、最後に返った BPM を得る。
    /// ⚠️ **捨て拍（warmup）を超えるだけの数を流すこと** — 足りないと必ず nil
    private func feed(_ tracker: MidiClockTracker, count: Int, interval: UInt64) -> Double? {
        var now: UInt64 = 1_000_000_000  // 0 始まりを避ける（&- の桁溢れ回避）
        var last: Double?
        for _ in 0..<count {
            if let bpm = tracker.tick(atNanos: now) { last = bpm }
            now &+= interval
        }
        return last
    }

    /// 捨て拍と測定窓を超える tick 数。
    /// **窓は 4 拍**（`measureBeats`）なので、それを跨がないと BPM は返らない
    private var enoughTicks: Int {
        (MidiClockTracker.warmupBeats + MidiClockTracker.measureBeats + 1)
            * MidiClockTracker.ticksPerBeat
    }

    @Test("測り始めは捨てる — 起動直後の負荷で伸びた間隔を掴まない")
    func warmupDiscarded() {
        let tracker = MidiClockTracker()
        // 捨て拍のあいだは何を流しても報告しない
        let early = feed(
            tracker, count: MidiClockTracker.warmupBeats * MidiClockTracker.ticksPerBeat,
            interval: tickInterval(bpm: 120))
        #expect(early == nil, "warmup 中は nil")
        #expect(tracker.latestBPM == nil)
    }

    @Test("等間隔の Clock で BPM が出る（窓は 4 拍）")
    func steadyClock() {
        let tracker = MidiClockTracker()
        let bpm = feed(tracker, count: enoughTicks, interval: tickInterval(bpm: 120))
        #expect(bpm != nil)
        #expect(abs((bpm ?? 0) - 120) < 1, "120 BPM 相当を流したら 120 前後")
    }

    @Test("1 BPM 未満の揺れは報告しない — 表示が震え続けるのを防ぐ")
    func hysteresis() {
        let tracker = MidiClockTracker()
        _ = feed(tracker, count: enoughTicks, interval: tickInterval(bpm: 120))
        // ほぼ同じテンポで流し直しても、差が 0.5 未満なら nil のまま
        let again = feed(tracker, count: enoughTicks, interval: tickInterval(bpm: 120.1))
        #expect(again == nil, "1 BPM 未満の差では報告しない")
    }

    @Test("現実的でない値は捨てる — 起動直後や取りこぼしの跳ね")
    func rangeGuard() {
        let tracker = MidiClockTracker()
        // 1 tick 1 秒 = 2.5 BPM。下限 20 を割るので通さない
        #expect(feed(tracker, count: enoughTicks, interval: 1_000_000_000) == nil)
        // 1 tick 10 マイクロ秒 = 250000 BPM。上限 300 を超える
        #expect(feed(MidiClockTracker(), count: enoughTicks, interval: 10_000) == nil)
    }

    @Test("⚠️ 2 本のソースが同時に送ると 2 倍に読める（既知の未修正）")
    func doubledWhenTwoSources() {
        // `Keystage KBD/CTRL` と `Keystage DAW IN` が同じポートに繋がっている。
        // 両方が F8 を出すと 1 拍 48 tick になり、120 BPM が 240 と読める。
        // **これは仕様ではなくバグ** — 直したらこのテストが落ちるので、
        // そのとき「ソースを 1 本に絞った」という意図に書き換えること
        let tracker = MidiClockTracker()
        let bpm = feed(tracker, count: enoughTicks * 2, interval: tickInterval(bpm: 120) / 2)
        #expect(abs((bpm ?? 0) - 240) < 2, "tick が倍で届くと BPM も倍に見える")
    }

    @Test("reset で忘れる — 抜き差ししたら測り直す")
    func resetForgets() {
        let tracker = MidiClockTracker()
        _ = feed(tracker, count: enoughTicks, interval: tickInterval(bpm: 120))
        #expect(tracker.latestBPM != nil)
        tracker.reset()
        #expect(tracker.latestBPM == nil, "reset 後は値を持たない")
    }
}
