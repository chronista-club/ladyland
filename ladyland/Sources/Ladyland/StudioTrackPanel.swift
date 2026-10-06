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
        VStack(spacing: 10) {
            HStack {
                Text("TRACK \((bank.first ?? 0) + 1)–\((bank.last ?? 7) + 1)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Button { appState.stepStudioBank(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled((bank.first ?? 0) == 0).accessibilityLabel("前の 8 Track")
                Button { appState.stepStudioBank(1) } label: { Image(systemName: "chevron.right") }
                    .disabled((bank.last ?? 0) >= appState.rack.slots.count - 1).accessibilityLabel("次の 8 Track")
                Spacer()
                if attached {
                    Text("nanoKONTROL2 · S → ノブ → S").font(.system(size: 11))
                } else {
                    Button("nanoKONTROL2 に割り当て") { appState.windowPlacement.setDock(.mixer, on: "nanokontrol.faders") }
                }
            }
            if let pending = appState.studioSelection.pending {
                HStack(spacing: 10) {
                    Text("T\(pending.slot + 1) の入力元").font(.system(size: 13, weight: .medium))
                    ForEach(StudioKeyboard.allCases) { keyboard in
                        Button(keyboard.title) {
                            let value: UInt8 = keyboard == .numa ? 0 : keyboard == .keystage ? 64 : 127
                            appState.studioSelection.turn(slot: pending.slot, value: value)
                        }
                        .tint(pending.keyboard == keyboard ? Color.accentColor : .secondary)
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer(minLength: 0)
                    Button("接続する") { appState.pressStudioSelect(pending.slot) }
                    Button("取消") { appState.studioSelection.cancel() }
                }
                Text("\(pending.keyboard.title) → Track \(pending.slot + 1)  ·  S でも確定")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 6) {
                ForEach(bank, id: \.self) { index in
                    StudioTrackStrip(slot: appState.rack.slots[index])
                }
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.textPrimary)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorderSubtle))
        .padding(14)
    }
}

private struct StudioTrackStrip: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.creoTheme) private var theme
    @ObservedObject var slot: InstrumentSlot

    var body: some View {
        let selected = appState.rack.selected == slot.index
        let sources = appState.studioInputs(for: slot.index)
        VStack(spacing: 7) {
            Button { appState.pressStudioSelect(slot.index) } label: {
                VStack(spacing: 3) {
                    Text("T\(slot.index + 1)").font(.system(size: 12, weight: .bold, design: .monospaced))
                    Text(slot.trackName ?? slot.displayName ?? "空の Track")
                        .font(.system(size: 10)).lineLimit(1)
                }.frame(maxWidth: .infinity)
            }.accessibilityLabel("Track \(slot.index + 1) 入力元を選択")
            Text(sources.isEmpty ? "—" : sources.map { keyboard in
                keyboard.title + (appState.studioKeyboardSlot(keyboard) == nil ? " ↗" : "")
            }.joined(separator: " / "))
                .font(.system(size: 10)).lineLimit(2).frame(height: 26)
                .help("↗ は選択 Track に追従。S で担当を固定できます")
            Slider(value: Binding(get: { Double(slot.gain) }, set: { appState.setGain(slot, to: Float($0)) }), in: 0...1)
                .accessibilityLabel("Track \(slot.index + 1) 音量")
            HStack {
                Button("S") { appState.pressStudioSelect(slot.index) }
                    .accessibilityLabel("Track \(slot.index + 1) S")
                Spacer()
                Button("M") { appState.toggleMute(slot) }
                    .foregroundStyle(slot.mute ? Color.orange : theme.textSecondary)
                    .accessibilityLabel("Track \(slot.index + 1) ミュート")
            }.font(.system(size: 12, weight: .semibold))
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : theme.surfaceBorderSubtle))
    }
}
