//! INST マトリクス — ROTO の INST 冊（L02 = P1-P4 / L03 = P5-P8）の配置図
//! （mako 要望 2026-08-12「マトリクスがあって、drag & drop で割り当て変更できて、
//! 空いてるマスをクリックして、パラメータ選択も」）。
//!
//! ## マトリクスとドラッグの「復活」について
//!
//! 8×16 マトリクスは 2026-08-02 に、ドラッグは 2026-08-05 に一度廃止された。
//! 当時は「割当を**設定する**」ための UI として過剰だった。いまは INST 冊 =
//! **実機に焼かれる 64 席**という物理的な対応物ができたので、配置図として
//! 意味を持つ — billboard のタイル交換と同じ設計言語（掴んで動かす = 交換）。
//!
//! ## 操作の同居
//!
//! - **クリック = 割当メニュー**（空きは「何を載せるか」、埋まりは変更/別名/空ける
//!   — 2026-08-05「セレクトで選ぶ」の裁定はここに生きている）
//! - **ドラッグ = 配置換え**（移動先が埋まっていれば交換 — 消えない操作）
//! - **右クリック = 席色**（マトリクスの色チップと同じ trackCells。
//!   焼きは 席色 > トラックカラー > ページ色）
//!
//! 変更は `onChanged`（= knobMappingsChanged）経由で差分焼きに乗り、
//! 1 秒後に実機の LCD が変わる。

import CreoUI
import RotoKit
import SwiftUI

struct InstMatrix: View {
    @Environment(\.creoTheme) private var theme
    @ObservedObject var slot: InstrumentSlot
    /// そのセルに実機で出ている色（AppState.cellColor — 解決順込み）
    let cellColor: (Int) -> UInt8
    /// 席の**明示色**（パラメータ色 > 席色。nil = 未設定 — チップは破線）。
    /// cellColor はページ色既定に落ちた解決値なので、チップには使えない
    let explicitCellColor: (Int) -> UInt8?
    /// セル色の上書き（nil = 既定へ戻す）
    let setCellColor: (Int, UInt8?) -> Void
    let onChanged: () -> Void

    /// ドラッグ中の状態（from = 掴んだ席 CC、location = matrix 座標系）
    @State private var drag: (from: Int, location: CGPoint)?
    /// 各セル枠（matrix 座標系。ヒットテストの基準）
    @State private var cellFrames: [Int: CGRect] = [:]
    /// 別名編集中のセル
    @State private var aliasCC: Int?
    @State private var aliasDraft = ""
    /// ページ操作（交換 / コピー）直前の割当 — **1 段だけ**戻せる
    /// （コピーの上書きで音色の触り場を失う事故のセーフティネット。
    /// mako 裁定 2026-08-12「確認ダイアログなしで上書き + 直後に戻せる」）
    @State private var beforePageEdit: [FaceKnobMapping]?

    private var parameters: [ParameterInfo] { ParameterInfo.list(of: slot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<KnobPages.pageCount, id: \.self) { page in
                if page == KnobPages.pageCount / 2 {
                    // 冊の区切り（前後半 = 実機の INST- / INST+ の 2 冊）
                    bookDivider("INST+")
                } else if page == 0 {
                    bookDivider("INST-")
                }
                pageRow(page)
            }
        }
        .coordinateSpace(name: "instMatrix")
        .onPreferenceChange(InstCellFramesKey.self) { cellFrames = $0 }
    }

    private func bookDivider(_ name: String) -> some View {
        HStack(spacing: CreoUITokens.spacingS) {
            Text(name)
                .font(LadylandFont.chipBold)
                .foregroundColor(theme.textTertiary)
            Rectangle()
                .fill(theme.surfaceBorderSubtle)
                .frame(height: 1)
        }
        .padding(.top, 2)
    }

    /// 1 ページ = **2 段 × 4**（mako 要望 2026-08-14「1x8 だと一つが狭い」。
    /// ROTO 実機のノブも上段 1-4 / 下段 5-8 の 2 段 — 物理と同じ並びになる）
    private func pageRow(_ page: Int) -> some View {
        HStack(alignment: .top, spacing: 2) {
            // 行ヘッダ = ページ操作の口（右クリックで交換 / コピー / 戻す）
            Text("P\(page + 1)")
                .font(LadylandFont.captionNumber)
                .foregroundColor(theme.textTertiary)
                .frame(width: 22, alignment: .trailing)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .contextMenu { pageMenu(page) }
                .help("P\(page + 1) — 右クリックで交換 / コピー")
            let half = KnobPages.perPage / 2
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    ForEach(0..<half, id: \.self) { position in
                        cell(cc: page * KnobPages.perPage + position)
                    }
                }
                HStack(spacing: 2) {
                    ForEach(half..<KnobPages.perPage, id: \.self) { position in
                        cell(cc: page * KnobPages.perPage + position)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// ページ操作（同一トラック内のみ — address は AU 依存なのでトラック間は
    /// 次段）。コピーは上書きだが、直前の状態を 1 段だけ覚えていて戻せる
    @ViewBuilder
    private func pageMenu(_ page: Int) -> some View {
        Menu("P\(page + 1) と交換") {
            ForEach(otherPages(than: page), id: \.self) { other in
                Button("P\(other + 1)") {
                    beforePageEdit = slot.knobMappings
                    slot.knobMappings = FaceKnobAssignment.swappingPages(
                        slot.knobMappings, page, other)
                    onChanged()
                }
            }
        }
        Menu("P\(page + 1) をコピー") {
            ForEach(otherPages(than: page), id: \.self) { other in
                Button("P\(other + 1) へ（上書き）") {
                    beforePageEdit = slot.knobMappings
                    slot.knobMappings = FaceKnobAssignment.copyingPage(
                        slot.knobMappings, from: page, to: other)
                    onChanged()
                }
            }
        }
        if beforePageEdit != nil {
            Divider()
            Button("直前のページ操作を戻す") {
                if let before = beforePageEdit {
                    slot.knobMappings = before
                    beforePageEdit = nil
                    onChanged()
                }
            }
        }
    }

    private func otherPages(than page: Int) -> [Int] {
        (0..<KnobPages.pageCount).filter { $0 != page }
    }

    // MARK: - セル

    private func mapping(at cc: Int) -> FaceKnobMapping? {
        slot.knobMappings.first { $0.knob == cc }
    }

    /// セルの表示名（別名 > 控えた名前。live 名は 64 セル分の AU 問い合わせを
    /// 避けて出さない — 正確な名前はメニューとツールチップで足りる）
    private func seatName(_ mapping: FaceKnobMapping) -> String {
        KnobLabel.resolve(alias: mapping.alias, live: nil, remembered: mapping.name) ?? "?"
    }

    @ViewBuilder
    private func cell(cc: Int) -> some View {
        let mapping = mapping(at: cc)
        let isDragSource = drag?.from == cc
        let isDropTarget = dropTarget == cc && drag != nil && !isDragSource

        Group {
            if aliasCC == cc {
                // 別名の編集中だけは素の TextField（Menu のラベルは打鍵を奪う）
                TextField(
                    "", text: $aliasDraft,
                    onCommit: {
                        slot.knobMappings = FaceKnobAssignment.aliasing(
                            slot.knobMappings, knob: cc, alias: aliasDraft)
                        aliasCC = nil
                        onChanged()
                    }
                )
                .textFieldStyle(.plain)
                .font(LadylandFont.matrixCell)
            } else {
                Text(mapping.map(seatName) ?? "")
                    .font(LadylandFont.matrixCell)
                    .foregroundColor(mapping == nil ? theme.textTertiary : theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .topLeading)
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(RotoPaletteMap.color(cellColor(cc)).opacity(mapping == nil ? 0.25 : 0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(
                    isDropTarget ? theme.brandPrimary : theme.surfaceBorderSubtle,
                    lineWidth: isDropTarget ? 2 : 0.5)
        )
        .opacity(isDragSource ? 0.35 : 1)
        .help(mapping.map { "\(seatName($0)) — CC\(cc)" } ?? "空き — CC\(cc)（クリックで割当）")
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: InstCellFramesKey.self,
                    value: [cc: proxy.frame(in: .named("instMatrix"))])
            }
        )
        .overlay(assignMenuOverlay(cc: cc, mapping: mapping))
        // 色チップ — 右上に常設、押すと 83 色パレットの popover（mako 要望
        // 2026-08-16「"席の色" メニューよりパレットが出て欲しい」。
        // ⚠️ **assignMenuOverlay より後**（前は contextMenu が全面 Menu の
        // 下敷きになって右クリックが死んでいた — チップは最前面に置く）
        .overlay(alignment: .topTrailing) {
            RotoColorChip(
                current: explicitCellColor(cc),
                onPick: { setCellColor(cc, $0) },
                size: 9)
                .padding(2)
        }
        // ドラッグ = 配置換え。minimumDistance 4 でクリック（メニュー）と切り分ける
        .highPriorityGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("instMatrix"))
                .onChanged { drag = (cc, $0.location) }
                .onEnded { value in
                    defer { drag = nil }
                    guard let target = hitCC(at: value.location), target != cc else { return }
                    slot.knobMappings = FaceKnobAssignment.swappingSeats(
                        slot.knobMappings, cc, target)
                    onChanged()
                }
        )
    }

    /// クリックで開く割当メニュー（透明オーバーレイ — ラベルにジェスチャを
    /// 重ねると Menu が開かなくなるので、Menu 自体を上に薄く敷く）
    @ViewBuilder
    private func assignMenuOverlay(cc: Int, mapping: FaceKnobMapping?) -> some View {
        if aliasCC != cc {
            Menu {
                ForEach(ParameterInfo.grouped(parameters), id: \.title) { group in
                    if group.title.isEmpty {
                        ForEach(group.items, id: \.address) { parameterButton($0, to: cc) }
                    } else {
                        Menu(group.title) {
                            ForEach(group.items, id: \.address) { parameterButton($0, to: cc) }
                        }
                    }
                }
                if mapping != nil {
                    Divider()
                    Button("別名をつける…") {
                        aliasDraft = mapping?.alias ?? ""
                        aliasCC = cc
                    }
                    Button("この席を空ける") {
                        slot.knobMappings = slot.knobMappings.filter { $0.knob != cc }
                        onChanged()
                    }
                }
            } label: {
                Color.clear
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    /// パラメータ 1 個の項目。**いまどこに載っているか**を添える（選ぶと移動）
    private func parameterButton(_ info: ParameterInfo, to cc: Int) -> some View {
        let current = slot.knobMappings.first { $0.address == info.address }
        let mark = current?.knob == cc ? "✓ " : ""
        let elsewhere = current.map {
            $0.knob != cc ? " · P\($0.knob / KnobPages.perPage + 1)-\($0.knob % KnobPages.perPage + 1)" : ""
        } ?? ""
        return Button(mark + info.name + elsewhere) {
            slot.knobMappings = FaceKnobAssignment.assigning(
                slot.knobMappings, knob: cc, address: info.address, name: info.name)
            onChanged()
        }
    }

    // 席色のリストメニューは 2026-08-16 に撤去 — 色はチップ（RotoColorChip の
    // 83 色パレット popover）へ一本化（mako「メニューよりパレットが出て欲しい」）

    // MARK: - ドラッグのヒットテスト

    private var dropTarget: Int? {
        guard let drag else { return nil }
        return hitCC(at: drag.location)
    }

    private func hitCC(at point: CGPoint) -> Int? {
        cellFrames.first { $0.value.contains(point) }?.key
    }
}

/// 各セル枠の収集（billboard の TileFramesKey と同じ作法）
private struct InstCellFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
