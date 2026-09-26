//! Jack 結線図（spec/09 / design/08。mako 裁定 2026-08-25「b（2 カラム結線）が
//! わかりやすいね」）。**左 = 機材セクション、右 = Jack、間をケーブルで結ぶ** —
//! NodeGraph の「ケーブルが見える」楽しさだけを頂き、座標管理は持たない
//! （両端が固定リストなので線は自動で決まる）。
//!
//! 接続は `MIDIInput.plan`（名前 → 経路）の写し。**未知の鍵盤は名前で行になる**
//! （Keystage 不在なら鍵盤 1、居れば鍵盤 2 — mako 裁定 2026-09-26「スタジオの
//! MIDI 鍵盤を Keystage の代わりに」）。操作できるのは Jack 側の束縛（担当
//! Track）と **LPD8 ノブ 8 の刺し先**（ドラム / 顔つまみ）。演奏前チェックが
//! 主用途 — 「いま誰がどこ？」が一目で分かること。

import CreoUI
import SwiftUI

struct JackBoardView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    // MARK: - 姿（幅で決まる。別ウィンドウに切り離すと広い版になる）

    enum Layout: Equatable {
        /// サイドバー版 — 2 列（機材 → Jack）、担当は「選択中の席に固定」
        case sidebar
        /// 広い版 — 3 列（機材 → Jack → 担当）、担当は Track のピッカーで直接選ぶ
        case wide
    }

    static let wideThreshold: CGFloat = 720

    static func layout(forWidth width: CGFloat) -> Layout {
        width >= wideThreshold ? .wide : .sidebar
    }

    /// 担当ピッカーの見出し — 席番号 + 名前（名前が無ければ番号だけ）
    static func trackLabel(index: Int, name: String) -> String {
        name.isEmpty ? "T\(index + 1)" : "T\(index + 1)  \(name)"
    }

    // MARK: - 行モデル（`MIDIInput.plan` の結線と対。機材は**セクション単位**）

    enum JackID: String, CaseIterable {
        case synth1, synth2, faceKnobs, drums
    }

    struct GearRow: Identifiable, Equatable {
        let id: String
        let gear: String
        let section: String
        let jack: JackID
        let connected: Bool
    }

    /// 行を組む（純関数 — テスト対象）。汎用鍵盤は名前で行になり、結線先は
    /// 接続表どおり（Keystage 不在なら鍵盤 1、居れば鍵盤 2）。
    /// LPD8 のノブ 8 は `lpd8KnobJack` で刺し先が変わる
    static func gearRows(sources: [MIDIConnectedSource], lpd8KnobJack: Lpd8KnobJack) -> [GearRow] {
        let has: (MIDISourceRoute) -> Bool = { route in sources.contains { $0.route == route } }
        let keystage = has(.keystage)
        let lpd8 = has(.drums)
        var rows: [GearRow] = [
            GearRow(id: "keystage.keys", gear: "Keystage", section: "鍵盤", jack: .synth1, connected: keystage),
            GearRow(id: "keystage.knobs", gear: "Keystage", section: "ノブ 8", jack: .faceKnobs, connected: keystage),
            GearRow(id: "pckb", gear: "PC キーボード", section: "Tab 演奏モード", jack: .synth1, connected: true),
        ]
        // 汎用鍵盤（挿さっているものだけ。抜けば行ごと消える）
        // id は名前ではなく通し番号 — 同じ名前で 2 ポート持つ鍵盤が居ても行が衝突しない
        for (i, source) in sources.enumerated() where source.route == .genericKeyboard {
            rows.append(GearRow(id: "generic.\(i)", gear: source.name, section: "鍵盤（汎用）", jack: .synth1, connected: true))
        }
        let minilab = sources.contains { $0.route == .secondKeyboard && $0.name.contains("MiniLab") }
        let ncxse = sources.contains { $0.route == .secondKeyboard && $0.name.contains("NCXse") }
        rows.append(GearRow(id: "minilab", gear: "MiniLab mkII", section: "鍵盤", jack: .synth2, connected: minilab))
        rows.append(GearRow(id: "ncxse", gear: "NCXse", section: "鍵盤", jack: .synth2, connected: ncxse))
        for (i, source) in sources.enumerated()
        where source.route == .secondKeyboard && !source.name.contains("MiniLab") && !source.name.contains("NCXse") {
            rows.append(GearRow(id: "generic.\(i)", gear: source.name, section: "鍵盤（汎用）", jack: .synth2, connected: true))
        }
        rows.append(GearRow(id: "lpd8.pads", gear: "LPD8", section: "パッド", jack: .drums, connected: lpd8))
        rows.append(
            GearRow(
                id: "lpd8.knobs", gear: "LPD8", section: "ノブ 8",
                jack: lpd8KnobJack == .face ? .faceKnobs : .drums, connected: lpd8))
        return rows
    }

    private var rows: [GearRow] {
        Self.gearRows(sources: appState.midiConnected, lpd8KnobJack: appState.lpd8KnobJack)
    }

    var body: some View {
        GeometryReader { geometry in
            board(Self.layout(forWidth: geometry.size.width))
        }
    }

    private func board(_ layout: Layout) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CreoUITokens.spacingL) {
                HStack(alignment: .top, spacing: 0) {
                    // 左列 — 機材セクション
                    VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
                        ForEach(rows) { row in
                            gearCard(row)
                                .anchorPreference(
                                    key: JackAnchorKey.self, value: .trailing
                                ) { ["gear.\(row.id)": $0] }
                        }
                    }
                    Spacer(minLength: layout == .wide ? 80 : 36)
                    // 右列 — Jack（広い版はその右に担当の列が並ぶ）
                    VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
                        ForEach(JackID.allCases, id: \.self) { jack in
                            HStack(alignment: .top, spacing: CreoUITokens.spacingM) {
                                jackCard(jack, layout: layout)
                                    .anchorPreference(key: JackAnchorKey.self, value: .leading) {
                                        ["jack.\(jack.rawValue)": $0]
                                    }
                                if layout == .wide {
                                    assigneeCard(jack)
                                }
                            }
                        }
                    }
                    if layout == .wide { Spacer(minLength: 0) }
                }
                // MIXER Jack（MiniLab ノブ16 / ROTO）と配役シーンは次段
                // （design/08 §4）— 効かない設定は並べない・説明文も出さない
            }
            .padding(CreoUITokens.spacingM)
            // ケーブル — 両端のアンカーを集めて描く
            .backgroundPreferenceValue(JackAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    ForEach(rows) { row in
                        if let from = anchors["gear.\(row.id)"],
                            let to = anchors["jack.\(row.jack.rawValue)"] {
                            cable(
                                from: proxy[from], to: proxy[to],
                                lit: row.connected)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 部品

    private func gearCard(_ row: GearRow) -> some View {
        let connected = row.connected
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: CreoUITokens.spacingS) {
                Circle()
                    .fill(connected ? theme.semanticSuccessText : theme.textTertiary)
                    .frame(width: 7, height: 7)
                Text(row.gear)
                    .font(LadylandFont.deskHeading)
            }
            Text(row.section)
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textSecondary)
            // LPD8 のノブ 8 だけ刺し替えられる（Keystage のつまみの代役。
            // mako 裁定 2026-09-26）。ページは ROTO / Keystage の現ページに追従
            if row.id == "lpd8.knobs" {
                Picker(
                    "",
                    selection: Binding(
                        get: { appState.lpd8KnobJack },
                        set: { appState.lpd8KnobJack = $0 })
                ) {
                    Text("ドラム").tag(Lpd8KnobJack.drums)
                    Text("顔つまみ").tag(Lpd8KnobJack.face)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(CreoUITokens.spacingS)
        .frame(width: 150, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .fill(theme.surfaceSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .stroke(theme.surfaceBorderSubtle, lineWidth: 1)
        )
        .opacity(connected ? 1 : 0.6)
        .help(connected ? "接続中" : "未接続（挿すと線が点く）")
    }

    @ViewBuilder
    private func jackCard(_ jack: JackID, layout: Layout) -> some View {
        switch jack {
        case .synth1:
            bindableJackCard(
                title: "鍵盤 1", slot: appState.synthInput1Slot, layout: layout,
                fix: { appState.synthInput1Slot = $0 })
        case .synth2:
            bindableJackCard(
                title: "鍵盤 2", slot: appState.secondKeyboardSlot, layout: layout,
                fix: { appState.secondKeyboardSlot = $0 })
        case .faceKnobs:
            VStack(alignment: .leading, spacing: 2) {
                Text("顔つまみ")
                    .font(LadylandFont.deskHeading)
                Text("担当: 選択中の Track（P\((appState.activeKnobPage ?? appState.rotoPage) + 1)）")
                    .font(LadylandFont.deskCaption)
                    .foregroundColor(theme.textSecondary)
            }
            .padding(CreoUITokens.spacingS)
            .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                    .fill(theme.surfaceSurface))
            .overlay(
                RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                    .stroke(theme.surfaceBorderSubtle, lineWidth: 1))
        case .drums:
            VStack(alignment: .leading, spacing: 2) {
                Text("サンプラ打面")
                    .font(LadylandFont.deskHeading)
                Text("担当: ドラム席（固定）")
                    .font(LadylandFont.deskCaption)
                    .foregroundColor(theme.textSecondary)
            }
            .padding(CreoUITokens.spacingS)
            .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                    .fill(theme.surfaceSurface))
            .overlay(
                RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                    .stroke(theme.surfaceBorderSubtle, lineWidth: 1))
        }
    }

    /// 担当 Track を持つ Jack（シンセ入力）のカード。
    /// 操作は「選択中の席に固定 / 解除」— タイル右クリックの対になる第 2 の口
    private func bindableJackCard(
        title: String, slot: Int?, layout: Layout, fix: @escaping (Int?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(LadylandFont.deskHeading)
            Text(slot.map { "担当: T\($0 + 1)" } ?? "担当: 選択に追従")
                .font(LadylandFont.deskCaption)
                .foregroundColor(slot == nil ? theme.textSecondary : theme.brandPrimary)
            // 広い版は担当の列（assigneeCard）で選ぶので、ここにはボタンを置かない。
            // サイドバー版のボタンは 2 行目 — 1 行に詰めると sidebar 幅で見切れる
            // （実機スクショ 2026-08-25）
            if layout == .sidebar {
                if slot == nil {
                    Button("選択中の席に固定") { fix(appState.rack.selected) }
                        .font(LadylandFont.deskCaption)
                } else {
                    Button("解除（選択に追従）") { fix(nil) }
                        .font(LadylandFont.deskCaption)
                }
            }
        }
        .padding(CreoUITokens.spacingS)
        .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .fill(theme.surfaceSurface))
        .overlay(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .stroke(theme.surfaceBorderSubtle, lineWidth: 1))
    }

    /// 担当の列（広い版だけ）— Track を名前で直接選ぶ。「Keystage = A、MiniLab = B」を
    /// 広い画面で一発で組む口（鍵盤 2 の設営）。ドラムは固定なので選べない
    @ViewBuilder
    private func assigneeCard(_ jack: JackID) -> some View {
        switch jack {
        case .synth1:
            trackPicker(slot: appState.synthInput1Slot) { appState.synthInput1Slot = $0 }
        case .synth2:
            trackPicker(slot: appState.secondKeyboardSlot) { appState.secondKeyboardSlot = $0 }
        case .faceKnobs:
            Text("選択中の Track")
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textTertiary)
                .padding(CreoUITokens.spacingS)
                .frame(width: 260, alignment: .leading)
        case .drums:
            Text("ドラム席")
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textTertiary)
                .padding(CreoUITokens.spacingS)
                .frame(width: 260, alignment: .leading)
        }
    }

    private func trackPicker(slot: Int?, fix: @escaping (Int?) -> Void) -> some View {
        Picker(
            "",
            selection: Binding(
                get: { slot ?? -1 },
                set: { fix($0 < 0 ? nil : $0) })
        ) {
            Text("選択に追従").tag(-1)
            ForEach(appState.rack.slots, id: \.index) { track in
                Text(Self.trackLabel(index: track.index, name: track.trackName ?? "")).tag(track.index)
            }
        }
        .labelsHidden()
        .frame(width: 260, alignment: .leading)
        .padding(.vertical, CreoUITokens.spacingS)
    }

    /// ケーブル 1 本（水平ベジェ — パッチベイの垂れたケーブルの気持ちで
    /// 少しだけ撓ませる）
    private func cable(from: CGPoint, to: CGPoint, lit: Bool) -> some View {
        Path { path in
            path.move(to: from)
            let sag: CGFloat = 12  // 撓み
            let mid = (from.x + to.x) / 2
            path.addCurve(
                to: to,
                control1: CGPoint(x: mid, y: from.y + sag),
                control2: CGPoint(x: mid, y: to.y + sag))
        }
        .stroke(
            lit ? theme.brandPrimary : theme.textTertiary.opacity(0.4),
            style: StrokeStyle(
                lineWidth: lit ? 2 : 1.5, lineCap: .round,
                dash: lit ? [] : [4, 4]))
    }
}

/// 結線図のアンカー収集（両端の点。InstMatrix の cellFrames と同じ流儀）
private struct JackAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGPoint>] = [:]
    static func reduce(
        value: inout [String: Anchor<CGPoint>],
        nextValue: () -> [String: Anchor<CGPoint>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}
