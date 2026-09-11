//! LPD8 mk2 プログラムエディタ UI（design/06 §8、設定ウィンドウ LPD8 タブ内）。
//!
//! 実機の物理配置に合わせたパッドグリッド（上段 = Pad 5-8 / 下段 = Pad 1-4）、
//! ノブ 8 行、グローバル設定、プリセット保存/適用。
//! 「読み込み → 目視 → 編集 → 書き込み（確認 + GET-back 照合）」の一方向フロー。

import AppKit
import CreoUI
import Lpd8Kit
import SwiftUI

struct Lpd8EditorView: View {
    @Environment(\.creoTheme) private var theme
    /// 4 プログラム一括書き込みの確認ダイアログ
    @State private var burnAll = false

    @ObservedObject var editor: Lpd8EditorModel
    @State private var presetName = ""
    @State private var selectedPreset = ""
    @State private var confirmWrite = false

    var body: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
            header

            if editor.program != nil {
                padGrid
                knobRows
                globalRow
                presetRow
                writeRow
            } else {
                Text("「読み込み」で実機の今の設定を取得（実機バイトが正）")
                    .font(LadylandFont.deskCaption)
                    .foregroundColor(theme.textTertiary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: CreoUITokens.spacingM) {
            Text("プログラムエディタ")
                .font(LadylandFont.deskHeading)
                .foregroundColor(theme.textPrimary)

            Picker("プログラム", selection: $editor.selectedProgram) {
                ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 160)
            .labelsHidden()

            Button("読み込み") { editor.read() }

            // **プログラムごとに番号をばらす**（mako 裁定 2026-08-04）。
            // LPD8 は切替を MIDI で通知しないので、番号が重なっていると
            // どのプログラムから来たか分からない。当てた後に書き込む
            Button("ladyland の番号を当てる") { editor.applyLadylandNumbers() }
                .disabled(editor.program == nil)
                .help("PROG \(editor.selectedProgram) 用の CC / ノートに差し替える"
                    + "（書き込みは別ボタン）")

            // **4 プログラムまとめて焼く** — GET → 当てる → SET を 1-4 で回す
            Button("4 プログラムに焼く", role: .destructive) { burnAll = true }
                .confirmationDialog(
                    "PROG 1-4 をまとめて書き換える", isPresented: $burnAll, titleVisibility: .visible
                ) {
                    Button("焼く", role: .destructive) { editor.burnAllPrograms() }
                    Button("やめる", role: .cancel) {}
                } message: {
                    Text("各プログラムのノート番号と CC が ladyland の規約で上書きされます。"
                        + "色やチャンネルは実機の設定を引き継ぎます。\n"
                        + "PROG1 ノブ CC79-86 / PROG2 87-94 / PROG3 102-109 / PROG4 110-117")
                }

            phaseLabel
            Spacer()
        }
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch editor.phase {
        case .idle:
            if editor.isDirty, editor.program != nil {
                Text("未書き込みの変更あり")
                    .font(LadylandFont.deskCaption)
                    .foregroundColor(theme.semanticWarningText)
            }
        case .reading: Text("読み込み中…").font(LadylandFont.deskCaption)
        case .writing: Text("書き込み中…").font(LadylandFont.deskCaption)
        case .verifying: Text("照合中…").font(LadylandFont.deskCaption)
        case .verified:
            Text("✓ 書き込み照合 OK")
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textSecondary)
        case .error(let message):
            Text(message)
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.semanticWarningText)
        }
    }

    /// 実機の物理配置: 上段 = Pad 5-8（entry 4-7）、下段 = Pad 1-4（entry 0-3）
    private var padGrid: some View {
        VStack(spacing: CreoUITokens.spacingS) {
            HStack(spacing: CreoUITokens.spacingS) {
                ForEach(4..<8, id: \.self) { padCell($0) }
            }
            HStack(spacing: CreoUITokens.spacingS) {
                ForEach(0..<4, id: \.self) { padCell($0) }
            }
        }
    }

    private func padCell(_ index: Int) -> some View {
        let pad = padBinding(index)
        return VStack(spacing: 2) {
            Text("Pad \(index + 1)")
                .font(LadylandFont.deskCaption.bold())
                .foregroundColor(theme.textSecondary)
            stepper("note", value: pad.note, in: 0...127)
            stepper("CC", value: pad.cc, in: 0...127)
            stepper("PC", value: pad.programChange, in: 0...127)
            channelStepper(value: pad.channel)
            HStack(spacing: CreoUITokens.spacingS) {
                colorWell("off", value: pad.offColor)
                colorWell("on", value: pad.onColor)
            }
        }
        .padding(CreoUITokens.spacingS)
        .background(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .fill(theme.surfaceSurface)
        )
    }

    private var knobRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<8, id: \.self) { index in
                let knob = knobBinding(index)
                HStack(spacing: CreoUITokens.spacingM) {
                    Text("K\(index + 1)")
                        .font(LadylandFont.deskNumber.bold())
                        .frame(width: 24, alignment: .leading)
                    stepper("CC", value: knob.cc, in: 0...127)
                    channelStepper(value: knob.channel)
                    stepper("min", value: knob.min, in: 0...127)
                    stepper("max", value: knob.max, in: 0...127)
                }
            }
        }
        .foregroundColor(theme.textSecondary)
    }

    private var globalRow: some View {
        HStack(spacing: CreoUITokens.spacingM) {
            if let program = editor.program {
                Stepper(
                    "グローバル ch \(Int(program.globalChannel) + 1)",
                    value: Binding(
                        get: { Int(editor.program?.globalChannel ?? 0) },
                        set: { editor.program?.globalChannel = UInt8($0) }
                    ), in: 0...15
                )
                Picker("プレッシャー", selection: Binding(
                    get: { Int(editor.program?.pressureMessage ?? 0) },
                    set: { editor.program?.pressureMessage = UInt8($0) }
                )) {
                    Text("off").tag(0)
                    Text("channel").tag(1)
                    Text("poly").tag(2)
                }
                .frame(maxWidth: 180)
                Toggle("full level", isOn: Binding(
                    get: { editor.program?.fullLevel ?? false },
                    set: { editor.program?.fullLevel = $0 }
                ))
                Toggle("toggle", isOn: Binding(
                    get: { editor.program?.toggle ?? false },
                    set: { editor.program?.toggle = $0 }
                ))
            }
        }
        .font(LadylandFont.deskCaption)
    }

    private var presetRow: some View {
        HStack(spacing: CreoUITokens.spacingM) {
            TextField("プリセット名", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
            Button("保存") {
                editor.savePreset(name: presetName)
                presetName = ""
            }
            .disabled(presetName.isEmpty || editor.program == nil)

            if !editor.presets.isEmpty {
                Picker("プリセット", selection: $selectedPreset) {
                    Text("(プリセット)").tag("")
                    ForEach(editor.presets, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 180)
                .labelsHidden()
                Button("適用") { editor.applyPreset(name: selectedPreset) }
                    .disabled(selectedPreset.isEmpty)
                    .help("working copy に読み込む（実機には「書き込み」で反映）")
            }
        }
    }

    private var writeRow: some View {
        HStack {
            Spacer()
            Button("プログラム \(editor.selectedProgram) へ書き込み", role: .destructive) {
                confirmWrite = true
            }
            .disabled(!editor.isDirty)
            .confirmationDialog(
                "プログラム \(editor.selectedProgram) を本体に書き込みます。実機側の設定は上書きされます。",
                isPresented: $confirmWrite, titleVisibility: .visible
            ) {
                Button("書き込む", role: .destructive) { editor.write() }
                Button("やめる", role: .cancel) {}
            }
        }
    }

    // MARK: - Binding ヘルパー

    private func padBinding(_ index: Int) -> Binding<Lpd8Pad> {
        Binding(
            get: {
                editor.program?.pads[index]
                    ?? Lpd8Pad(note: 0, cc: 0, programChange: 0, channel: 0x10,
                               offColor: .off, onColor: .off)
            },
            set: { editor.program?.pads[index] = $0 }
        )
    }

    private func knobBinding(_ index: Int) -> Binding<Lpd8Knob> {
        Binding(
            get: { editor.knobs(index) },
            set: { editor.program?.knobs[index] = $0 }
        )
    }

    private func stepper(_ label: String, value: Binding<UInt8>, in range: ClosedRange<Int>)
        -> some View {
        Stepper(
            "\(label) \(value.wrappedValue)",
            value: Binding(get: { Int(value.wrappedValue) }, set: { value.wrappedValue = UInt8($0) }),
            in: range
        )
        .font(LadylandFont.deskNumber)
    }

    /// チャンネル: ワイヤ 0-15 = ch1-16、0x10 = グローバルに従う（GL）
    private func channelStepper(value: Binding<UInt8>) -> some View {
        Stepper(
            "ch \(value.wrappedValue == 0x10 ? "GL" : String(value.wrappedValue + 1))",
            value: Binding(get: { Int(value.wrappedValue) }, set: { value.wrappedValue = UInt8($0) }),
            in: 0...16
        )
        .font(LadylandFont.deskNumber)
    }

    private func colorWell(_ label: String, value: Binding<Rgb8>) -> some View {
        ColorPicker(label, selection: Binding(
            get: { Color(rgb8: value.wrappedValue) },
            set: { value.wrappedValue = Rgb8(color: $0) }
        ), supportsOpacity: false)
        .font(LadylandFont.deskCaption)
    }
}

extension Lpd8EditorModel {
    /// View 用の安全な knob アクセス
    func knobs(_ index: Int) -> Lpd8Knob {
        program?.knobs[index] ?? Lpd8Knob(cc: 0, channel: 0x10, min: 0, max: 127)
    }
}

// MARK: - Rgb8 ⇄ SwiftUI Color

extension Color {
    init(rgb8: Rgb8) {
        self.init(
            red: Double(rgb8.r) / 255,
            green: Double(rgb8.g) / 255,
            blue: Double(rgb8.b) / 255
        )
    }
}

extension Rgb8 {
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            UInt8(max(0, min(255, ns.redComponent * 255))),
            UInt8(max(0, min(255, ns.greenComponent * 255))),
            UInt8(max(0, min(255, ns.blueComponent * 255)))
        )
    }
}
