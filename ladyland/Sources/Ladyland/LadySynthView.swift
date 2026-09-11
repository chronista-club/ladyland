//! **Lady MPE のプラグイン画面**（mako 要望 2026-08-07「Lady MPE プラグイン
//! 画面を準備しよう」）。
//!
//! ## ⚠️ この楽器に「つまみ」は 1 つも無い
//!
//! `LadySynth` は `parameterTree` を持たない — `AUParameter` が 1 つも定義
//! されていない。**だからつまみを並べる画面は作れないし、作ってはいけない。**
//! 偽のつまみを置くと「回したのに何も起きない」を生む。
//!
//! 代わりに **16 ボイスの表現を live で見せる面**にする。MPE 楽器で本当に
//! 見たいのは「**いまどの音がどれだけ曲がって・押されて・音色が動いているか**」で、
//! それはパラメータではなく**演奏そのもの**。
//!
//! ## ⚠️ シンプルに（mako 2026-08-07「MPE は、シンプルな感じで」）
//!
//! **凝った可視化は作らない。** MPE の 3 次元（bend / pressure / timbre）は
//! **短いバーと数値**で足りる。地味でよい。
//!
//! ## ⚠️ 16 個は常に同じ場所に居る
//!
//! 鳴っている音だけを詰めて並べると、**押すたびに行が動いて目で追えない**。
//! 空きボイスは**沈める**（サンプラーの空席と同じ考え方）が、場所は空けたまま。
//!
//! ## ⚠️ リアルタイム側には何も足していない
//!
//! `voiceStates()` は既存の `lock` を短く取って値をコピーするだけ。
//! `handleMIDI` にも `internalRenderBlock` にも手を入れていない。

import CreoUI
import SwiftUI

struct LadySynthView: View {
    @Environment(\.creoTheme) private var theme
    let synth: LadySynth

    /// ⚠️ **描画のたびに AU を読む**（`SamplerFieldView` と同じ作法）。
    /// 20Hz — MPE の表情は速いが、目で追えるのはこの程度。
    /// 上げても読み取りが増えるだけで、見え方は変わらない
    @State private var voices: [LadySynth.VoiceState] = []
    @State private var rate: Double = 0
    private let poll = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            header
            ForEach(voices) { voice in
                voiceRow(voice)
            }
            Spacer(minLength: 0)
        }
        .padding(CreoUITokens.spacingM)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surfaceBgBase)
        .onAppear { refresh() }
        .onReceive(poll) { _ in refresh() }
    }

    private func refresh() {
        let next = synth.voiceStates()
        if next != voices { voices = next }
        let nextRate = synth.engineRate
        if nextRate != rate { rate = nextRate }
    }

    // MARK: - 見出し

    /// ⚠️ **エンジンのレートを出す**。2026-08-07 に丸 1 日
    /// 「synth だけ 44100 のまま」で音程が 4.35 倍ずれていた — **画面に出て
    /// いれば即座に分かった**。`d130658` で直したが、再発を目で捕まえるために置く
    private var header: some View {
        HStack(spacing: CreoUITokens.spacingS) {
            Text(LadySynth.displayName)
                .font(LadylandFont.bodyBold)
                .foregroundColor(theme.textPrimary)
            CreoBadge(String(format: "%.0f Hz", rate), variant: .neutral, size: .s)
            CreoBadge("MPE ±\(Int(LadySynth.bendRangeSemitones))", variant: .neutral, size: .s)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 1 ボイス

    /// ⚠️ **空きも同じ高さで置く** — 詰めると押すたびに行が動いて目で追えない
    private func voiceRow(_ voice: LadySynth.VoiceState) -> some View {
        let live = voice.isAudible
        return HStack(spacing: CreoUITokens.spacingS) {
            // ch は MPE の鍵の識別子。⚠️ **ch1 は Master だが ladyland は
            // ここでも鳴らす**（非 MPE 鍵盤が全部 ch1 に来るため。LadySynth の doc）
            Text("ch\(voice.channel)")
                .font(LadylandFont.deskNumber)
                .foregroundColor(theme.textTertiary)
                .frame(width: 30, alignment: .trailing)

            // 音名 — ⚠️ **番号だけでは読めない**
            Text(live ? Self.noteName(voice.note) : "‐")
                .font(LadylandFont.deskNumber)
                .foregroundColor(live ? theme.textPrimary : theme.textTertiary)
                .frame(width: 34, alignment: .leading)

            // ⚠️ **半音で出す** — 0...1 では「どれだけ曲がったか」が
            // 演奏の言葉にならない（±48 半音は 4 オクターブ）
            value(live ? String(format: "%+.1f", voice.bend * LadySynth.bendRangeSemitones) : "")
            bar(abs(voice.bend), live: live)

            value(live ? String(format: "%.2f", voice.pressure) : "")
            bar(voice.pressure, live: live)

            value(live ? String(format: "%.2f", voice.timbre) : "")
            bar(voice.timbre, live: live)

            // ⚠️ **鳴り終わりも見せる** — `isOn` が折れても減衰中は音が出ている
            Text(live ? String(format: "%3.0f%%", voice.envelope * 100) : "")
                .font(LadylandFont.chip)
                .foregroundColor(voice.isOn ? theme.textSecondary : theme.textTertiary)
                .frame(width: 34, alignment: .trailing)
                .monospacedDigit()
        }
        .opacity(live ? 1 : 0.32)  // 空きは沈める（場所は空けたまま）
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(LadylandFont.chip)
            .foregroundColor(theme.textSecondary)
            .frame(width: 34, alignment: .trailing)
            .monospacedDigit()
    }

    /// 0...1 の短いバー
    private func bar(_ value: Double, live: Bool) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(theme.surfaceBgEmphasis)
            Rectangle()
                .fill(live ? theme.brandPrimary : theme.textTertiary)
                .frame(width: 28 * min(1, max(0, value)))
        }
        .frame(width: 28, height: 5)
    }

    // MARK: - 音名

    /// MIDI ノート番号 → 音名（`C4` = 60。Yamaha 式）。
    /// ⚠️ **番号のままでは演奏の言葉にならない** — 60 と書かれても鍵が分からない
    static func noteName(_ note: UInt8) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = Int(note) / 12 - 1
        return "\(names[Int(note) % 12])\(octave)"
    }
}
