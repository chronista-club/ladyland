//! 机の描画 — 2.5D（床を遠近で描き、機材は奥ほど小さく。板は傾けない —
//! `DeskModel.scale` のコメント参照）。
//!
//! **物理層の上に仮想層を重ねる**（mako 2026-10-04「動かせないもの(MIDIコン)を、
//! 仮想的に配置して、そこにヴァーチャルなコンポーネントを重ねる」）:
//!
//! - 物理層 = 機材の板（実機の形）。セクションごとに**ソケット**
//! - 仮想層 = ケーブル・プラグの札・ノブに重ねるパラメータ名
//! - 仮想機材 = 奥の Mixer（engine の顔。Jack の箱は無く、ケーブルは直接
//!   その Track のストリップ / DRUMS に着く）
//!
//! 結線図の情報はここに全部畳む（`DeskGraph`）。板に乗らない機材は左の棚。
//! 操作:
//! - 板の上で弾く（実機と同じ入口 `routeKeyboard` / `routeDrums` を通す）
//! - プラグを掴んでストリップへ落とす = 担当の刺し替え（右クリックでも選べる）
//! - 見出しの ≡ をドラッグ = 配置（window.json に残る）

import CreoUI
import SwiftUI

/// 机のアンカー（ソケット・ストリップ・Mixer の枠）。Mixer も同じキーで出す
struct DeskAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(
        value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct DeskView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    /// ドラッグ中の仮の位置（離したら window.json へ）
    @State private var dragging: [DeskGear: DeskPlacement] = [:]
    /// 掴んでいるプラグ（ソケット id）と指の位置（机の座標）
    @State private var heldPlug: (socket: String, point: CGPoint)?

    static let shelfWidth: CGFloat = 150
    static let mixerScale: CGFloat = 0.72

    private var gears: [DeskGear] { DeskModel.gears(sources: appState.midiConnected) }

    private var sockets: [DeskSocket] {
        DeskGraph.sockets(
            rows: JackBoardView.gearRows(
                sources: appState.midiConnected, lpd8KnobJack: appState.lpd8KnobJack),
            gears: gears)
    }

    private var bindings: DeskGraph.Bindings {
        DeskGraph.Bindings(
            synth1: appState.synthInput1Slot, synth2: appState.secondKeyboardSlot,
            selected: appState.rack.selected,
            page: appState.activeKnobPage ?? appState.rotoPage, miniLab: appState.miniLabSlot)
    }

    private var bank: [Int] {
        MixerModel.bankIndices(
            selected: appState.rack.selected, trackCount: appState.rack.slots.count)
    }

    var body: some View {
        let sockets = sockets
        HStack(alignment: .top, spacing: 0) {
            shelf(sockets.filter { $0.home == nil })
                .frame(width: Self.shelfWidth)
            GeometryReader { geo in
                // 置ける範囲は上下に余白（機材の半分が床からはみ出さないように）
                let size = CGSize(width: geo.size.width, height: geo.size.height - 120)
                ZStack(alignment: .topLeading) {
                    DeskGround()
                    ForEach(gears) { gear in
                        let placement =
                            dragging[gear]
                            ?? DeskModel.placement(gear, saved: appState.windowPlacement.deskPlacements)
                        let point = DeskModel.point(placement, in: size)
                        gearCard(gear, sockets: sockets.filter { $0.home == gear }, size: size)
                            .scaleEffect(DeskModel.scale(depth: placement.depth))
                            .position(x: point.x, y: point.y + 60)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .coordinateSpace(name: "desk")
        // 仮想層 — ケーブルとプラグ（アンカーが揃ってから描く）
        .overlayPreferenceValue(DeskAnchorKey.self) { anchors in
            GeometryReader { proxy in
                cables(sockets: sockets, anchors: anchors, proxy: proxy)
            }
        }
    }

    // MARK: - 棚（板の無い機材。挿さっていれば線が出る）

    private func shelf(_ items: [DeskSocket]) -> some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            Text("棚")
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textTertiary)
            ForEach(items) { socket in
                VStack(alignment: .leading, spacing: 2) {
                    Text(socket.gear)
                        .font(LadylandFont.deskHeading)
                        .lineLimit(1)
                    socketChip(socket)
                }
                .padding(CreoUITokens.spacingS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                        .fill(theme.surfaceSurface))
                .opacity(socket.connected ? 1 : 0.45)
                .help(socket.connected ? "接続中" : "未接続（挿すと線が出る）")
            }
            Spacer(minLength: 0)
        }
        .padding(CreoUITokens.spacingS)
    }

    // MARK: - 機材の板

    private func gearCard(_ gear: DeskGear, sockets: [DeskSocket], size: CGSize) -> some View {
        VStack(spacing: 4) {
            // 見出し = 掴むところ（ドラッグで配置）
            HStack(spacing: CreoUITokens.spacingS) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10))
                    .foregroundColor(theme.textTertiary)
                Text(gear.title)
                    .font(LadylandFont.deskHeading)
                Spacer(minLength: 0)
                if gear == .mixer {
                    badge("T\((bank.first ?? 0) + 1)-\((bank.last ?? 0) + 1)")
                }
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
            // ソケット（セクションの差込口）
            if !sockets.isEmpty {
                HStack(spacing: CreoUITokens.spacingS) {
                    ForEach(sockets) { socketChip($0) }
                    Spacer(minLength: 0)
                }
            }
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
        .anchorPreference(key: DeskAnchorKey.self, value: .bounds) {
            gear == .mixer ? ["mixer": $0] : [:]
        }
    }

    /// ソケット — Jack の色の丸 + セクション名。ケーブルはここから出る
    private func socketChip(_ socket: DeskSocket) -> some View {
        HStack(spacing: 4) {
            Circle()
                .strokeBorder(Self.color(socket.jack, theme), lineWidth: 2)
                .background(
                    Circle().fill(socket.connected ? Self.color(socket.jack, theme) : .clear)
                        .padding(3))
                .frame(width: 12, height: 12)
                .anchorPreference(key: DeskAnchorKey.self, value: .bounds) {
                    ["socket.\(socket.id)": $0]
                }
            Text(socket.section)
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textSecondary)
        }
    }

    @ViewBuilder
    private func gearBody(_ gear: DeskGear) -> some View {
        switch gear {
        case .mixer:
            let width = MixerView.width(strips: bank.count + 1)
            MixerView(includeDrums: true)
                .frame(width: width, height: 300)
                .scaleEffect(Self.mixerScale, anchor: .topLeading)
                .frame(width: width * Self.mixerScale, height: 300 * Self.mixerScale, alignment: .topLeading)
        case .lpd8:
            Lpd8DeskView(
                selected: appState.rack.selectedSlot, drums: appState.rack.drumSlot)
        case .nanokontrol:
            NanoKontrolDeskView()
        case .keystage, .keyboard:
            DeskKeyboardView(
                onNoteOn: { appState.router.routeKeyboard(0x90, $0, 100) },
                onNoteOff: { appState.router.routeKeyboard(0x80, $0, 0) })
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

    // MARK: - 仮想層: ケーブルとプラグ

    /// Jack の色（鍵盤 1 = mint、鍵盤 2 = 第 2 色、Track ノブ = info、ドラム = warning）
    static func color(_ jack: JackBoardView.JackID, _ theme: CreoTheme) -> Color {
        switch jack {
        case .synth1: return theme.brandPrimary
        case .synth2, .miniLab: return theme.brandSecondary
        case .trackKnobs: return theme.semanticInfo
        case .drums: return theme.semanticWarning
        }
    }

    @ViewBuilder
    private func cables(
        sockets: [DeskSocket], anchors: [String: Anchor<CGRect>], proxy: GeometryProxy
    ) -> some View {
        let live = sockets.filter { $0.connected }
        let mixer = anchors["mixer"].map { proxy[$0] }
        // 同じ着地点に何本来ているか（プラグを縦に積む）
        let ends: [(DeskSocket, CGPoint, Int)] = {
            var stacked: [String: Int] = [:]
            return live.compactMap { socket in
                guard let (key, point) = landing(socket, anchors: anchors, proxy: proxy, mixer: mixer)
                else { return nil }
                let k = stacked[key, default: 0]
                stacked[key] = k + 1
                return (socket, point, k)
            }
        }()
        ZStack(alignment: .topLeading) {
            ForEach(ends, id: \.0.id) { socket, end, k in
                if let from = anchors["socket.\(socket.id)"].map({ proxy[$0] }) {
                    let held = heldPlug?.socket == socket.id ? heldPlug?.point : nil
                    let plugPoint = held ?? CGPoint(x: end.x, y: end.y + 14 + CGFloat(k) * 20)
                    cable(from: CGPoint(x: from.midX, y: from.minY), to: plugPoint, jack: socket.jack)
                    plug(socket, at: plugPoint, anchors: anchors, proxy: proxy, mixer: mixer)
                }
            }
        }
    }

    /// ケーブルの着地点（キー = 積み上げの単位、点 = ストリップの下端の中央）
    private func landing(
        _ socket: DeskSocket, anchors: [String: Anchor<CGRect>], proxy: GeometryProxy,
        mixer: CGRect?
    ) -> (String, CGPoint)? {
        switch DeskGraph.target(socket.jack, bindings) {
        case .drums:
            guard let rect = anchors["strip.drums"].map({ proxy[$0] }) else { return nil }
            return ("drums", CGPoint(x: rect.midX, y: rect.maxY))
        case .strip(let slot, _):
            if let rect = anchors["strip.\(slot)"].map({ proxy[$0] }) {
                return ("strip.\(slot)", CGPoint(x: rect.midX, y: rect.maxY))
            }
            // バンク外 — Mixer の右端に着く（札に席番号が出る）
            guard let mixer else { return nil }
            return ("offbank", CGPoint(x: mixer.maxX + 40, y: mixer.midY))
        }
    }

    private func cable(from: CGPoint, to: CGPoint, jack: JackBoardView.JackID) -> some View {
        Path { path in
            path.move(to: from)
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x, y: from.y - 90),
                control2: CGPoint(x: to.x, y: to.y + 90))
        }
        .stroke(
            Self.color(jack, theme).opacity(0.85),
            style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .shadow(color: .black.opacity(0.4), radius: 2, y: 2)
        .allowsHitTesting(false)
    }

    /// プラグ — Jack 名の札。刺し替えられるものは掴んでストリップへ落とす
    @ViewBuilder
    private func plug(
        _ socket: DeskSocket, at point: CGPoint, anchors: [String: Anchor<CGRect>],
        proxy: GeometryProxy, mixer: CGRect?
    ) -> some View {
        let label = Text(DeskGraph.plugLabel(socket.jack, bindings, bank: bank))
            .font(LadylandFont.deskCaption)
            .foregroundColor(theme.surfaceBgBase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Self.color(socket.jack, theme)))
            .fixedSize()
            .position(point)
        if socket.repluggable {
            label
                .gesture(
                    DragGesture(coordinateSpace: .named("desk"))
                        .onChanged { heldPlug = (socket.id, $0.location) }
                        .onEnded { value in
                            heldPlug = nil
                            var strips: [Int: CGRect] = [:]
                            for (key, anchor) in anchors where key.hasPrefix("strip.") {
                                if let i = Int(key.dropFirst("strip.".count)) { strips[i] = proxy[anchor] }
                            }
                            let drop = DeskGraph.dropTarget(
                                at: value.location, strips: strips,
                                drums: anchors["strip.drums"].map { proxy[$0] }, mixer: mixer)
                            apply(DeskGraph.rebind(socket, drop: drop))
                        }
                )
                .contextMenu { plugMenu(socket) }
                .help("掴んでストリップへ落とすと刺し替え（Mixer の外 = 選択に追従）")
        } else {
            label.allowsHitTesting(false)
        }
    }

    /// 右クリックの近道（ドラッグが面倒なとき）
    @ViewBuilder
    private func plugMenu(_ socket: DeskSocket) -> some View {
        if socket.id == "lpd8.knobs" {
            Button("ドラム") { apply(.lpd8Knobs(.drums)) }
            Button("Track ノブ") { apply(.lpd8Knobs(.face)) }
        } else {
            let fix: (Int?) -> DeskRebind = { slot in
                switch socket.jack {
                case .synth2: .synth2(slot)
                case .miniLab: .miniLab(slot)
                default: .synth1(slot)
                }
            }
            Button("選択に追従") { apply(fix(nil)) }
            ForEach(appState.rack.slots, id: \.index) { track in
                Button(JackBoardView.trackLabel(index: track.index, name: track.trackName ?? "")) {
                    apply(fix(track.index))
                }
            }
        }
    }

    private func apply(_ rebind: DeskRebind) {
        switch rebind {
        case .synth1(let slot): appState.synthInput1Slot = slot
        case .synth2(let slot): appState.secondKeyboardSlot = slot
        case .miniLab(let slot): appState.miniLabSlot = slot
        case .lpd8Knobs(let jack): appState.lpd8KnobJack = jack
        case .none: break
        }
    }
}

/// 机の面 — 遠近の格子（奥が狭く、横線は奥ほど詰まる）。描くだけで触れない
private struct DeskGround: View {
    @Environment(\.creoTheme) private var theme

    var body: some View {
        Canvas { context, size in
            let back = DeskModel.scale(depth: 0)
            let cx = size.width / 2
            // 床の台形
            var floor = Path()
            floor.move(to: CGPoint(x: cx - cx * back, y: 0))
            floor.addLine(to: CGPoint(x: cx + cx * back, y: 0))
            floor.addLine(to: CGPoint(x: size.width, y: size.height))
            floor.addLine(to: CGPoint(x: 0, y: size.height))
            floor.closeSubpath()
            context.fill(floor, with: .color(theme.surfaceBgSubtle))

            var grid = Path()
            let columns = 16
            for i in 0...columns {
                let t = CGFloat(i) / CGFloat(columns) - 0.5
                grid.move(to: CGPoint(x: cx + t * size.width * back, y: 0))
                grid.addLine(to: CGPoint(x: cx + t * size.width, y: size.height))
            }
            let rows = 10
            for i in 0...rows {
                // 奥ほど詰まる（depth^1.6）
                let depth = pow(CGFloat(i) / CGFloat(rows), 1.6)
                let s = DeskModel.scale(depth: Double(depth))
                let y = size.height * depth
                grid.move(to: CGPoint(x: cx - cx * s, y: y))
                grid.addLine(to: CGPoint(x: cx + cx * s, y: y))
            }
            context.stroke(grid, with: .color(theme.surfaceBorderSubtle.opacity(0.7)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
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
    /// 仮想層の材料 — ノブに重ねる割当名（Track ノブ = 選択中、ドラム = ドラム席）
    @ObservedObject var selected: InstrumentSlot
    @ObservedObject var drums: InstrumentSlot

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
            // ノブ: K1-K8（2 段）。下にいまの割当名を重ねる
            VStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 8) {
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

    private func knobLabel(_ index: Int) -> String? {
        DeskGraph.lpd8KnobLabel(
            index: index, jack: appState.lpd8KnobJack, knobCCs: appState.lpd8KnobCCs,
            page: appState.activeKnobPage ?? appState.rotoPage,
            selected: selected.knobMappings, drums: drums.knobMappings)
    }

    /// ノブ — 上下ドラッグで 0-127。実機と同じ CC を drums 経路へ流す
    /// （刺し先が Track ノブでも drums でも、横取りは router が決める）
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
            // 仮想層 — いまこのノブが動かすパラメータ名（空きは K 番号）
            Text(knobLabel(index) ?? "K\(index + 1)")
                .font(.system(size: 7))
                .foregroundColor(knobLabel(index) == nil ? theme.textTertiary : theme.textSecondary)
                .lineLimit(1)
                .frame(width: 40)
                .offset(y: 16))
        .padding(.bottom, 8)
        .frame(width: 34)
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
