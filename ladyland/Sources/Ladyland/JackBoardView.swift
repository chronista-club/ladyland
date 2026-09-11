//! Jack 結線図（spec/09 / design/08。mako 裁定 2026-08-25「b（2 カラム結線）が
//! わかりやすいね」）。**左 = 機材セクション、右 = Jack、間をケーブルで結ぶ** —
//! NodeGraph の「ケーブルが見える」楽しさだけを頂き、座標管理は持たない
//! （両端が固定リストなので線は自動で決まる）。
//!
//! v1 は接続がコード固定（`connectSources` の分岐と対）なので**図は読み取り**。
//! 操作できるのは Jack 側の束縛（担当 Track）だけ。刺し替えは接続表の
//! データ化（design/08 §4 v3）で効く。演奏前チェックが主用途 —
//! 「いま誰がどこ？」が一目で分かること。

import CreoUI
import SwiftUI

struct JackBoardView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    // MARK: - 行モデル（v1 固定 — connectSources の分岐と対）

    enum JackID: String, CaseIterable {
        case synth1, synth2, drums
    }

    struct GearRow: Identifiable {
        let id: String
        let gear: String
        let section: String
        let jack: JackID
        /// midiConnectedSources に現れる名前の断片（nil = 常時接続扱い）
        let matchKey: String?
    }

    private static let gearRows: [GearRow] = [
        GearRow(id: "keystage", gear: "Keystage", section: "鍵盤 + ノブ8", jack: .synth1, matchKey: "Keystage"),
        GearRow(id: "pckb", gear: "PC キーボード", section: "Tab 演奏モード", jack: .synth1, matchKey: nil),
        GearRow(id: "minilab", gear: "MiniLab mkII", section: "鍵盤", jack: .synth2, matchKey: "MiniLab"),
        GearRow(id: "ncxse", gear: "NCXse", section: "鍵盤", jack: .synth2, matchKey: "NCXse"),
        GearRow(id: "lpd8", gear: "LPD8", section: "パッド + ノブ8", jack: .drums, matchKey: "LPD8"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CreoUITokens.spacingL) {
                HStack(alignment: .top, spacing: 0) {
                    // 左列 — 機材セクション
                    VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
                        ForEach(Self.gearRows) { row in
                            gearCard(row)
                                .anchorPreference(
                                    key: JackAnchorKey.self, value: .trailing
                                ) { ["gear.\(row.id)": $0] }
                        }
                    }
                    Spacer(minLength: 36)
                    // 右列 — Jack
                    VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
                        jackCard(.synth1)
                            .anchorPreference(key: JackAnchorKey.self, value: .leading) {
                                ["jack.synth1": $0]
                            }
                        jackCard(.synth2)
                            .anchorPreference(key: JackAnchorKey.self, value: .leading) {
                                ["jack.synth2": $0]
                            }
                        jackCard(.drums)
                            .anchorPreference(key: JackAnchorKey.self, value: .leading) {
                                ["jack.drums": $0]
                            }
                    }
                }
                // MIXER Jack（MiniLab ノブ16 / ROTO）と配役シーンは次段
                // （design/08 §4）— 効かない設定は並べない・説明文も出さない
            }
            .padding(CreoUITokens.spacingM)
            // ケーブル — 両端のアンカーを集めて描く
            .backgroundPreferenceValue(JackAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    ForEach(Self.gearRows) { row in
                        if let from = anchors["gear.\(row.id)"],
                            let to = anchors["jack.\(row.jack.rawValue)"] {
                            cable(
                                from: proxy[from], to: proxy[to],
                                lit: isConnected(row))
                        }
                    }
                }
            }
        }
    }

    // MARK: - 部品

    private func isConnected(_ row: GearRow) -> Bool {
        guard let key = row.matchKey else { return true }
        return appState.midiConnectedSources.contains { $0.contains(key) }
    }

    private func gearCard(_ row: GearRow) -> some View {
        let connected = isConnected(row)
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
    private func jackCard(_ jack: JackID) -> some View {
        switch jack {
        case .synth1:
            bindableJackCard(
                title: "鍵盤 1", slot: appState.synthInput1Slot,
                fix: { appState.synthInput1Slot = $0 })
        case .synth2:
            bindableJackCard(
                title: "鍵盤 2", slot: appState.secondKeyboardSlot,
                fix: { appState.secondKeyboardSlot = $0 })
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
        title: String, slot: Int?, fix: @escaping (Int?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(LadylandFont.deskHeading)
            Text(slot.map { "担当: T\($0 + 1)" } ?? "担当: 選択に追従")
                .font(LadylandFont.deskCaption)
                .foregroundColor(slot == nil ? theme.textSecondary : theme.brandPrimary)
            // ボタンは 2 行目 — 1 行に詰めると sidebar 幅で見切れる
            // （実機スクショ 2026-08-25）
            if slot == nil {
                Button("選択中の席に固定") { fix(appState.rack.selected) }
                    .font(LadylandFont.deskCaption)
            } else {
                Button("解除（選択に追従）") { fix(nil) }
                    .font(LadylandFont.deskCaption)
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
