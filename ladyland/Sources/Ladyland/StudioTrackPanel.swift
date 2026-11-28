//! スタジオの手元に置く 8 Track の操作面。実機と画面は同じ操作を呼ぶ。
import CreoUI
import SwiftUI

struct StudioTrackPanel: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.creoTheme) private var theme
    private var bank: [Int] {
        MixerModel.bankIndices(selected: appState.rack.selected, trackCount: appState.rack.slots.count)
    }
    private var attached: Bool { appState.windowPlacement.docks?["mixer"] == "nanokontrol.faders" }

    var body: some View {
        VStack(spacing: CreoUITokens.spacingS) {
            HStack {
                Text("TRACK \((bank.first ?? 0) + 1)–\((bank.last ?? 7) + 1)")
                    .font(LadylandFont.deskHeading.monospacedDigit())
                Button { appState.stepStudioBank(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled((bank.first ?? 0) == 0).accessibilityLabel("前の 8 Track")
                Button { appState.stepStudioBank(1) } label: { Image(systemName: "chevron.right") }
                    .disabled((bank.last ?? 0) >= appState.rack.slots.count - 1).accessibilityLabel("次の 8 Track")
                Spacer()
                if attached {
                    Text("nanoKONTROL2 · S → ノブ → S")
                        .font(LadylandFont.deskCaption)
                        .foregroundStyle(theme.textSecondary)
                } else {
                    Button("nanoKONTROL2 に割り当て") { appState.windowPlacement.setDock(.mixer, on: "nanokontrol.faders") }
                }
            }
            if let pending = appState.studioSelection.pending {
                HStack(spacing: CreoUITokens.spacingS) {
                    Text("T\(pending.slot + 1) の入力元").font(LadylandFont.deskBody)
                    ForEach(StudioKeyboard.allCases) { keyboard in
                        Button(keyboard.title) {
                            let value: UInt8 = keyboard == .numa ? 0 : keyboard == .keystage ? 64 : 127
                            appState.studioSelection.turn(slot: pending.slot, value: value)
                        }
                        .tint(pending.keyboard == keyboard ? theme.brandPrimary : theme.textSecondary)
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer(minLength: 0)
                    Button("接続する") { appState.pressStudioSelect(pending.slot) }
                    Button("取消") { appState.studioSelection.cancel() }
                }
                Text("\(pending.keyboard.title) → Track \(pending.slot + 1)  ·  S でも確定")
                    .font(LadylandFont.bodyBold)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: CreoUITokens.spacingS) {
                ForEach(bank, id: \.self) { index in
                    StudioTrackStrip(slot: appState.rack.slots[index])
                }
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.textPrimary)
        .padding(CreoUITokens.spacingM)
        .background(theme.surfaceSurface.opacity(0.92), in: RoundedRectangle(cornerRadius: CreoUITokens.radiusL))
        .overlay(RoundedRectangle(cornerRadius: CreoUITokens.radiusL).stroke(theme.surfaceBorderSubtle))
        .padding(CreoUITokens.spacingM)
    }
}

private struct StudioTrackStrip: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.creoTheme) private var theme
    @ObservedObject var slot: InstrumentSlot

    var body: some View {
        let selected = appState.rack.selected == slot.index
        let sources = appState.studioInputs(for: slot.index)
        VStack(spacing: CreoUITokens.spacingS) {
            Button { appState.pressStudioSelect(slot.index) } label: {
                VStack(spacing: CreoUITokens.spacingXs) {
                    Text("T\(slot.index + 1)").font(LadylandFont.deskHeading.monospacedDigit())
                    Text(slot.trackName ?? slot.displayName ?? "空の Track")
                        .font(LadylandFont.matrixCell).lineLimit(1)
                }.frame(maxWidth: .infinity)
            }.accessibilityLabel("Track \(slot.index + 1) 入力元を選択")
            Text(sources.isEmpty ? "—" : sources.map { keyboard in
                keyboard.title + (appState.studioKeyboardSlot(keyboard) == nil ? " ↗" : "")
            }.joined(separator: " / "))
                .font(LadylandFont.matrixCell).lineLimit(2).frame(height: 26)
                .help("↗ は選択 Track に追従。S で担当を固定できます")
            Slider(value: Binding(get: { Double(slot.gain) }, set: { appState.setGain(slot, to: Float($0)) }), in: 0...1)
                .accessibilityLabel("Track \(slot.index + 1) 音量")
            HStack {
                Button("S") { appState.pressStudioSelect(slot.index) }
                    .accessibilityLabel("Track \(slot.index + 1) S")
                Spacer()
                Button("M") { appState.toggleMute(slot) }
                    .foregroundStyle(slot.mute ? theme.semanticWarningText : theme.textSecondary)
                    .accessibilityLabel("Track \(slot.index + 1) ミュート")
            }.font(LadylandFont.deskHeading)
        }
        .padding(CreoUITokens.spacingS)
        .frame(maxWidth: .infinity)
        .background(selected ? theme.brandPrimarySubtle : Color.clear,
                    in: RoundedRectangle(cornerRadius: CreoUITokens.radiusM))
        .overlay(RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
            .stroke(selected ? theme.brandPrimary : theme.surfaceBorderSubtle))
    }
}
