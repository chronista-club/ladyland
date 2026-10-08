import SwiftUI
import CreoUI

struct XTouchSurfaceView: View {
    @Environment(\.creoTheme) private var theme
    @ObservedObject var controller: XTouchController
    @ObservedObject var rack: InstrumentRack

    var body: some View {
        ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(controller.connected ? theme.semanticSuccessText : theme.textTertiary)
                    .frame(width: 7, height: 7)
                Text(controller.greeting ? "X-Touch · 接続中…" : controller.connected ? "X-Touch · 接続済み" : "X-Touch · 未接続 / 使用OFF")
                Spacer()
                Text("8ch + Master").foregroundStyle(theme.textSecondary)
            }.font(LadylandFont.deskCaption)
            navigation
            if let error = controller.error {
                Text(error).font(LadylandFont.deskCaption).foregroundStyle(theme.semanticError)
            }
            HStack(alignment: .top, spacing: 8) {
                GeometryReader { geometry in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(controller.bank.indices(trackCount: rack.slots.count), id: \.self) { index in
                            XTouchChannelStrip(slot: rack.slots[index], selected: rack.selected == index,
                                onSelect: { controller.select(index) },
                                onChange: controller.onChange, width: max(70, (geometry.size.width - 42) / 8))
                        }
                    }.padding(.bottom, 4)
                }
                }.frame(height: 384)
                Divider()
                VStack(spacing: 10) {
                    Text("MASTER").font(LadylandFont.deskHeading)
                    Text("全体").font(LadylandFont.deskCaption).foregroundStyle(theme.textSecondary)
                    Spacer().frame(height: 35)
                    XTouchFader(value: Binding(get: { rack.masterGain }, set: { controller.setMaster($0) }), label: "Master 音量")
                    Text(String(format: "%.0f%%", rack.masterGain * 100)).monospacedDigit()
                }.font(LadylandFont.deskCaption).frame(width: 64)
                    .padding(.vertical, 8)
            }
            if controller.bank.pending != 0 {
                Text("フェーダーから手を離すと担当Trackが切り替わります")
                    .font(LadylandFont.deskCaption).foregroundStyle(theme.textSecondary)
            }
            Text("本体: MC / USB · ノブ: Pan · ノブ押下: 中央へ")
                .font(LadylandFont.deskCaption).foregroundStyle(theme.textSecondary)
            Spacer(minLength: 0)
        }.padding(12)
        }
    }
    private var navigation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("T\(controller.bank.start + 1)–T\(min(controller.bank.start + 8, rack.slots.count)) / \(rack.slots.count) Tracks")
                .font(LadylandFont.deskHeading).monospacedDigit()
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    step("BANK −8", delta: -8)
                    step("BANK +8", delta: 8)
                }
                HStack(spacing: 4) {
                    step("CH −1", delta: -1)
                    step("CH +1", delta: 1)
                }
            }.controlSize(.small)
        }
    }
    private func step(_ title: String, delta: Int) -> some View {
        Button(title) { controller.move(delta) }
            .disabled(delta < 0 ? controller.bank.start + controller.bank.pending == 0 : controller.bank.start + controller.bank.pending >= rack.slots.count - 8)
    }
}

private struct XTouchChannelStrip: View {
    @Environment(\.creoTheme) private var theme
    @ObservedObject var slot: InstrumentSlot
    let selected: Bool
    let onSelect: () -> Void
    let onChange: () -> Void
    var width: CGFloat = 70
    var body: some View {
        VStack(spacing: 8) {
            Rectangle().fill(slot.rotoColor.map(RotoPaletteMap.color) ?? theme.brandPrimary).frame(height: 3)
            Text("T\(slot.index + 1)").font(LadylandFont.deskHeading)
            Text(slot.trackName ?? "空き").lineLimit(1).help(slot.trackName ?? "空き")
            Slider(value: Binding(get: { slot.pan }, set: { slot.pan = $0; onChange() }), in: -1...1)
                .accessibilityLabel("T\(slot.index + 1) Pan")
            Text(abs(slot.pan) < 0.01 ? "C" : String(format: "%@ %.0f", slot.pan < 0 ? "L" : "R", abs(slot.pan) * 100))
                .foregroundStyle(theme.textSecondary).monospacedDigit()
            XTouchFader(value: Binding(get: { slot.gain }, set: { slot.gain = $0; onChange() }), label: "T\(slot.index + 1) 音量")
            Text(String(format: "%.0f%%", slot.gain * 100)).monospacedDigit()
            HStack(spacing: 4) {
                action("M", active: slot.mute) { slot.mute.toggle(); onChange() }
                action("S", active: slot.solo) { slot.solo.toggle(); onChange() }
            }
            action("Select", active: selected, onSelect)
        }
        .font(LadylandFont.deskCaption)
        .padding(.horizontal, 5).padding(.bottom, 8)
        .frame(width: width)
        .background(selected ? theme.surfaceBgEmphasis : theme.surfaceSurface)
    }
    private func action(_ title: String, active: Bool, _ callback: @escaping () -> Void) -> some View {
        Button(action: callback) {
            Text(title).frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(active ? theme.brandPrimary.opacity(0.3) : theme.surfaceBgEmphasis)
        }.buttonStyle(.plain)
            .accessibilityLabel("T\(slot.index + 1) \(title)")
            .accessibilityValue(active ? "ON" : "OFF")
    }
}

private struct XTouchFader: View {
    @Environment(\.creoTheme) private var theme
    @Binding var value: Float
    let label: String
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Capsule().fill(theme.surfaceBgEmphasis).frame(width: 4)
                Capsule().fill(theme.brandPrimary).frame(width: 4, height: geometry.size.height * CGFloat(value))
                RoundedRectangle(cornerRadius: 3).fill(theme.textPrimary)
                    .frame(width: 26, height: 10)
                    .offset(y: -(geometry.size.height - 10) * CGFloat(value))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    value = MixerModel.gain(atY: event.location.y, height: geometry.size.height)
                })
        }.frame(height: 180)
            .accessibilityElement().accessibilityLabel(label)
            .accessibilityValue("\(Int(value * 100))%")
            .accessibilityAdjustableAction { direction in
                value = min(1, max(0, value + (direction == .increment ? 0.01 : -0.01)))
            }
    }
}
