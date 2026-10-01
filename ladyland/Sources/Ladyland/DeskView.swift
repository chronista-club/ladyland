//! 机の描画 — 2.5D（SwiftUI の `rotation3DEffect` で板を傾ける）。
//! モデルは `Desk.swift`。機材は**いまある部品**をそのまま板に乗せる:
//! Mixer は `MixerView`、LPD8 はパッド 8 + ノブ 8、鍵盤は 2 オクターブ。
//! 操作はすべて**実機と同じ入口**（`MIDIRouter.routeKeyboard` / `routeDrums`）を
//! 通す — latch・和音表示・顔つまみの横取り・trace が全部生きる。
//!
//! 結線の刺し替えは機材の上の札（Jack の担当）から。配置は見出しをドラッグ。

import CreoUI
import SwiftUI

struct DeskView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    /// ドラッグ中の仮の位置（離したら window.json へ）
    @State private var dragging: [DeskGear: DeskPlacement] = [:]

    static let tilt: Double = 48
    static let planeHeight: CGFloat = 520

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: geo.size.width, height: Self.planeHeight)
            ZStack(alignment: .topLeading) {
                DeskGround()
                ForEach(DeskModel.gears(sources: appState.midiConnected)) { gear in
                    let placement =
                        dragging[gear]
                        ?? DeskModel.placement(gear, saved: appState.windowPlacement.deskPlacements)
                    gearCard(gear, size: size)
                        .position(DeskModel.point(placement, in: size))
                }
            }
            .frame(width: size.width, height: size.height)
            .rotation3DEffect(
                .degrees(Self.tilt), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.55)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - 機材の板

    private func gearCard(_ gear: DeskGear, size: CGSize) -> some View {
        VStack(spacing: 4) {
            // 見出し = 掴むところ（ドラッグで配置）+ Jack の札
            HStack(spacing: CreoUITokens.spacingS) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10))
                    .foregroundColor(theme.textTertiary)
                Text(gear.title)
                    .font(LadylandFont.deskHeading)
                Spacer(minLength: 0)
                jackBadge(gear)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let base = DeskModel.placement(gear, saved: appState.windowPlacement.deskPlacements)
                        dragging[gear] = DeskModel.moved(base, by: value.translation, in: size)
                    }
                    .onEnded { value in
                        let base = DeskModel.placement(gear, saved: appState.windowPlacement.deskPlacements)
                        appState.windowPlacement.setDeskPlacement(
                            gear, DeskModel.moved(base, by: value.translation, in: size))
                        dragging[gear] = nil
                    }
            )
            gearBody(gear)
        }
        .padding(CreoUITokens.spacingS)
        .background(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .fill(theme.surfaceSurface)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 6))
        .overlay(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .stroke(theme.surfaceBorderSubtle, lineWidth: 1))
        .fixedSize()
    }

    @ViewBuilder
    private func gearBody(_ gear: DeskGear) -> some View {
        switch gear {
        case .mixer:
            MixerView()
                .scaleEffect(0.72, anchor: .top)
                .frame(width: 8 * (MixerStrip.width + 6) * 0.72, height: 300 * 0.72, alignment: .top)
        case .lpd8:
            Lpd8DeskView()
        case .nanokontrol:
            NanoKontrolDeskView()
        case .keystage, .keyboard:
            DeskKeyboardView(
                onNoteOn: { appState.router.routeKeyboard(0x90, $0, 100) },
                onNoteOff: { appState.router.routeKeyboard(0x80, $0, 0) })
        }
    }

    // MARK: - Jack の札（担当。ここから刺し替える）

    @ViewBuilder
    private func jackBadge(_ gear: DeskGear) -> some View {
        switch gear {
        case .keystage, .keyboard:
            trackMenu(title: "鍵盤 1", slot: appState.synthInput1Slot) { appState.synthInput1Slot = $0 }
        case .nanokontrol:
            badge("鍵盤 2（結線は次段）")
        case .lpd8:
            Picker(
                "",
                selection: Binding(get: { appState.lpd8KnobJack }, set: { appState.lpd8KnobJack = $0 })
            ) {
                Text("ノブ → ドラム").tag(Lpd8KnobJack.drums)
                Text("ノブ → 顔つまみ").tag(Lpd8KnobJack.face)
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 130)
        case .mixer:
            badge("T\(appState.rack.bankStart + 1)-\(appState.rack.bankStart + 8)")
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(LadylandFont.deskCaption)
            .foregroundColor(theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.surfaceBgEmphasis))
    }

    /// 担当 Track を選ぶ札（Jack 面の担当ピッカーと同じ中身）
    private func trackMenu(title: String, slot: Int?, fix: @escaping (Int?) -> Void) -> some View {
        Menu {
            Button("選択に追従") { fix(nil) }
            ForEach(appState.rack.slots, id: \.index) { track in
                Button(JackBoardView.trackLabel(index: track.index, name: track.trackName ?? "")) {
                    fix(track.index)
                }
            }
        } label: {
            badge("\(title) → " + (slot.map { "T\($0 + 1)" } ?? "選択に追従"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// 机の面 — 奥へ向かう格子
private struct DeskGround: View {
    @Environment(\.creoTheme) private var theme

    var body: some View {
        Canvas { context, size in
            let line = theme.surfaceBorderSubtle.opacity(0.7)
            var path = Path()
            let step: CGFloat = 48
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(line), lineWidth: 0.5)
        }
        .background(theme.surfaceBgSubtle)
        .clipShape(RoundedRectangle(cornerRadius: CreoUITokens.radiusM))
    }
}

// MARK: - 鍵盤（2 オクターブ）

struct DeskKeyboardView: View {
    @Environment(\.creoTheme) private var theme
    let onNoteOn: (UInt8) -> Void
    let onNoteOff: (UInt8) -> Void

    @State private var baseNote: UInt8 = 48  // C3 始まり
    @State private var held: Set<UInt8> = []

    static let whiteWidth: CGFloat = 22
    static let whiteHeight: CGFloat = 70
    static let octaves = 2

    var body: some View {
        let keys = DeskKeyboard.keys(baseNote: baseNote, octaves: Self.octaves)
        let whites = keys.filter { !$0.isBlack }
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 1) {
                    ForEach(whites, id: \.note) { key in
                        keyView(key, width: Self.whiteWidth, height: Self.whiteHeight)
                    }
                }
                ForEach(keys.filter(\.isBlack), id: \.note) { key in
                    keyView(key, width: Self.whiteWidth * 0.6, height: Self.whiteHeight * 0.6)
                        .offset(x: CGFloat(key.whiteIndex + 1) * (Self.whiteWidth + 1) - Self.whiteWidth * 0.3)
                }
            }
            HStack(spacing: CreoUITokens.spacingS) {
                Button("−") { shift(-12) }.disabled(baseNote < 12)
                Text(LadySynthView.noteName(baseNote))
                    .font(LadylandFont.deskCaption)
                    .foregroundColor(theme.textTertiary)
                Button("+") { shift(12) }.disabled(baseNote > 127 - 12 * UInt8(Self.octaves))
            }
            .font(LadylandFont.deskCaption)
            .controlSize(.mini)
        }
    }

    private func shift(_ delta: Int) {
        for note in held { onNoteOff(note) }
        held = []
        baseNote = UInt8(min(max(Int(baseNote) + delta, 0), 127 - 12 * Self.octaves))
    }

    private func keyView(_ key: DeskKeyboard.Key, width: CGFloat, height: CGFloat) -> some View {
        let down = held.contains(key.note)
        return RoundedRectangle(cornerRadius: 2)
            .fill(
                down ? theme.brandPrimary
                    : (key.isBlack ? theme.surfaceBgEmphasis : theme.textPrimary.opacity(0.9)))
            .overlay(
                RoundedRectangle(cornerRadius: 2).stroke(theme.surfaceBorderSubtle, lineWidth: 0.5))
            .frame(width: width, height: height)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !held.contains(key.note) else { return }
                        held.insert(key.note)
                        onNoteOn(key.note)
                    }
                    .onEnded { _ in
                        held.remove(key.note)
                        onNoteOff(key.note)
                    }
            )
    }
}

// MARK: - LPD8（パッド 8 + ノブ 8）

struct Lpd8DeskView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    @State private var down: Set<Int> = []
    @State private var knobs: [Int] = Array(repeating: 64, count: 8)

    var body: some View {
        HStack(alignment: .top, spacing: CreoUITokens.spacingM) {
            // パッド: 奥の列 = pad 1-4、手前 = 5-8（実機を見下ろした形）
            VStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { col in
                            pad(row * 4 + col)
                        }
                    }
                }
            }
            // ノブ: K1-K8（2 段）
            VStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { col in
                            knob(row * 4 + col)
                        }
                    }
                }
            }
        }
    }

    private func pad(_ index: Int) -> some View {
        let note = appState.padNotes.indices.contains(index) ? appState.padNotes[index] : UInt8(36 + index)
        let pressed = down.contains(index)
        return RoundedRectangle(cornerRadius: 4)
            .fill(pressed ? theme.brandPrimary : theme.surfaceBgEmphasis)
            .overlay(
                Text("\(index + 1)")
                    .font(LadylandFont.deskCaption)
                    .foregroundColor(pressed ? theme.textPrimary : theme.textTertiary))
            .frame(width: 34, height: 34)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down.contains(index) else { return }
                        down.insert(index)
                        appState.router.routeDrums(0x99, note, 110)
                    }
                    .onEnded { _ in
                        down.remove(index)
                        appState.router.routeDrums(0x89, note, 0)
                    }
            )
    }

    /// ノブ — 上下ドラッグで 0-127。実機と同じ CC を drums 経路へ流す
    /// （刺し先が顔つまみでも drums でも、横取りは router が決める）
    private func knob(_ index: Int) -> some View {
        let value = knobs[index]
        return ZStack {
            Circle().fill(theme.surfaceBgEmphasis)
            Circle()
                .trim(from: 0, to: CGFloat(value) / 127 * 0.75)
                .stroke(theme.brandPrimary, lineWidth: 3)
                .rotationEffect(.degrees(135))
        }
        .frame(width: 24, height: 24)
        .overlay(
            Text("K\(index + 1)")
                .font(.system(size: 7))
                .foregroundColor(theme.textTertiary)
                .offset(y: 16))
        .padding(.bottom, 8)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    let next = min(max(value - Int(drag.translation.height / 2), 0), 127)
                    guard next != knobs[index] else { return }
                    knobs[index] = next
                    let cc = appState.lpd8KnobCCs.indices.contains(index)
                        ? appState.lpd8KnobCCs[index] : Lpd8DefaultKnobCCs.program1[index]
                    appState.router.routeDrums(0xB0, cc, UInt8(next))
                }
        )
    }
}

// MARK: - nanoKONTROL2（結線は次段 — 姿だけ置く）

struct NanoKontrolDeskView: View {
    @Environment(\.creoTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<8, id: \.self) { _ in
                VStack(spacing: 3) {
                    Circle().fill(theme.surfaceBgEmphasis).frame(width: 12, height: 12)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.levelTrack)
                        .frame(width: 8, height: 40)
                }
            }
        }
    }
}
