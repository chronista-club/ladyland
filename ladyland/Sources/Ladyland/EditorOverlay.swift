//! Editor Mode の overlay（creo-ui editor-mode.md の 4 領域のうち
//! **TOP + RIGHT** — D-2 の semantic layout の最小形）。
//!
//! D-6 非侵襲: Content Layer の座標・可視性・操作を奪わない — ZStack の
//! 最上段に浮かび、ヒットテストはバーとパネルの面だけ。mode OFF で完全不可視
//! （D-8。field 値は bind 先の @Published が持っているので当然保持される）。
//!
//! control は既存部品を使う — rotoColor は Track 面と同じ RotoColorChip
//! （palette popover）。変更は bind 先の @Published に入り、Content の再描画
//! も ROTO の差分焼きも既存経路で走る（D-9）。

import CreoUI
import SwiftUI

struct EditorOverlay: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                Spacer()
                rightPanel
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(true)
    }

    /// TOP — global（D-3: 上 = グローバル、視線の起点）。mode の表示と出口
    private var topBar: some View {
        HStack(spacing: CreoUITokens.spacingS) {
            Image(systemName: "slider.horizontal.2.square")
            Text("EDITOR MODE")
                .font(LadylandFont.chipBold)
            Spacer()
            Button {
                appState.editorModeOn = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, CreoUITokens.spacingM)
        .padding(.vertical, 4)
        .background(theme.brandPrimary.opacity(0.9))
        .foregroundColor(.white)
    }

    /// RIGHT — tool（D-3: 右 = 未来を作る側）。field を group ごとに並べる
    private var rightPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
                ForEach(groupedFields, id: \.group) { section in
                    Text(section.group)
                        .font(LadylandFont.deskHeading)
                        .foregroundColor(theme.textSecondary)
                        .padding(.top, CreoUITokens.spacingS)
                    ForEach(section.fields) { field in
                        fieldRow(field)
                    }
                }
            }
            .padding(CreoUITokens.spacingM)
        }
        .frame(width: 240)
        .background(theme.surfaceBgBase.opacity(0.95))
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.surfaceBorderSubtle).frame(width: 1)
        }
    }

    /// 登録順を保った group 分け（Dictionary(grouping:) は順序を失う）
    private var groupedFields: [(group: String, fields: [EditorField])] {
        var order: [String] = []
        var buckets: [String: [EditorField]] = [:]
        for field in appState.editorFields {
            if buckets[field.group] == nil { order.append(field.group) }
            buckets[field.group, default: []].append(field)
        }
        return order.map { (group: $0, fields: buckets[$0] ?? []) }
    }

    @ViewBuilder
    private func fieldRow(_ field: EditorField) -> some View {
        switch field.kind {
        case .rotoColor(let get, let set):
            HStack(spacing: CreoUITokens.spacingS) {
                RotoColorChip(current: get(), onPick: { set($0) }, size: 16)
                Text(field.label)
                    .font(LadylandFont.deskBody)
                Spacer()
            }
        case .toggle(let get, let set):
            Toggle(
                field.label,
                isOn: Binding(get: get, set: set)
            )
            .font(LadylandFont.deskBody)
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }
}
