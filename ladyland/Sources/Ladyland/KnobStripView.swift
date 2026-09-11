//! Keystage ノブストリップ — ノブ HUD（mako 裁定 2026-08-01 スタジオ試奏
//! フィードバック「目の前のつまみが、どこと接続して、どの CC の範囲なのか」）。
//!
//! いま手元の 8 ノブが「どのページ（CC 範囲）で・何に繋がっているか」を
//! 演奏向けに常設表示する。編集はマトリクス（R Area）、見るのはここ、と
//! 役割を分ける。ページは受信 CC から直読み — ページ = CC ÷ 8 が正典
//! （FaceKnobAssignment.inferredPage。Page +/- 自体は MIDI 無音なので、
//! 最初のノブ 1 動きで追従する）。
//! 円弧 = パラメータ現在値、ゴースト針 = 未キャッチの物理ノブ位置
//! （ピックアップが掴むまでのズレが見える）。

import CreoUI
import SwiftUI

/// ストリップのセル導出 — 純関数（テスト対象）
enum KnobStrip {
    struct Cell: Equatable, Identifiable {
        /// 物理ノブ位置 0-7
        let position: Int
        /// この位置が送る CC 番号（= ページ × 8 + 位置）
        let cc: Int
        /// 割当先パラメータ名（nil = 未割当 — 帯が飲むので楽器へは届かない）
        let name: String?
        /// 物理コントローラのバッジ（M / E）
        let badge: String?
        /// 予約セル（割当対象外）。⚠️ 予約 CC（EXIT / keep 時の Damper）は
        /// どれも帯の外なので、帯を描くこのストリップでは常に false —
        /// 判定は将来の予約変更に備えて残している
        let reserved: Bool

        var id: Int { cc }
    }

    /// ページ p の 8 セルを割当から導出する（page は 0-based）。
    ///
    /// ⚠️ **帯（`KeystageKnobs`）から引く**（監査 2026-08-08 の B-4）。
    /// 以前は `page * 8 + position` を直に計算していて、**page = 8 を渡すと
    /// ペダル帯（CC64-71）を描けてしまった** — 実機に存在しないページ。
    ///
    /// ⚠️ **範囲外は空**（`KnobPages.page(_:)` が `[]` を返す）
    static func cells(page: Int, mappings: [FaceKnobMapping], pedal: PedalMode = .keep)
        -> [Cell]
    {
        let reservedCCs = FaceKnobAssignment.reservedCCs(pedal: pedal)
        let seats = KnobPages.page(page)
        return seats.enumerated().map { position, cc in
            let reserved = reservedCCs.contains(cc)
            let name = reserved ? nil : mappings.first { $0.knob == cc }?.name
            return Cell(
                position: position, cc: cc, name: name,
                badge: FaceKnobAssignment.controllerBadge(cc), reserved: reserved)
        }
    }
}

/// 常設の横帯 — 選択トラックに追従する物理ノブのミラー
struct KnobStripView: View {
    @Environment(\.creoTheme) private var theme
    @ObservedObject var slot: InstrumentSlot
    let page: Int?
    let controller: FaceKnobController
    /// ノートのキープ（ダンパーペダル）の状態
    var latchEngaged = false
    var latchSustaining = 0
    /// ダンパーペダルの役割（キープ表示を出すかの判定にも使う）
    var pedal: PedalMode = .keep

    /// Keystage が送っているテンポ（nil = Clock を受けていない）
    var clockBPM: Double?
    /// テンポ同期が入っているか（切っていると数字を淡く出す）
    var tempoSyncEnabled = true

    /// 席の明示色（パラメータ色 > 席色。nil = 色なし = 弧は従来のブランド色。
    /// mako 要望 2026-08-16「アイコンに色をつける動線」— ROTO の LCD と
    /// 手元 HUD の色が揃う）
    var cellColor: (Int) -> UInt8? = { _ in nil }
    /// 右クリックの色メニューの書き込み口（nil = メニューを出さない）
    var setCellColor: ((Int, UInt8?) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: CreoUITokens.spacingS) {
                Image(systemName: "dial.medium")
                    .font(LadylandFont.caption)
                    .foregroundColor(theme.textTertiary)
                Text(FaceKnobAssignment.pageLabel(page))
                    .font(LadylandFont.number.bold())
                    .foregroundColor(
                        page == nil ? theme.textTertiary : theme.textSecondary)
                if page == nil {
                    Text("ノブを回すと追従")
                        .font(LadylandFont.caption)
                        .foregroundColor(theme.textTertiary)
                }

                // **Keystage のテンポ**（mako 2026-08-05）。Clock を受けている
                // 間だけ出す。同期を切っているときは淡く出して「受けてはいるが
                // 渡していない」を区別する — 消すと切ったことを忘れる
                if let bpm = clockBPM {
                    // 小数第 1 位まで（mako 2026-08-05）。Clock の間隔ゆらぎで
                    // 実機の設定値から 0.2 ほどずれることがあり、**丸めると
                    // 「合っている」ように見えてしまう**。実測値として出す
                    Label(String(format: "%.1f", bpm), systemImage: "metronome")
                        .font(LadylandFont.captionNumber)
                        .foregroundColor(
                            tempoSyncEnabled
                                ? theme.textSecondary : theme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.surfaceBgEmphasis))
                        .help(
                            tempoSyncEnabled
                                ? "Keystage のテンポ。プラグインへ渡している"
                                : "Keystage のテンポ。**同期は切ってある**"
                                    + "（プラグインは自前の既定で動く）")
                }

                // ノートのキープ（ダンパー）— 踏みっぱなしに気づけるよう
                // 鳴っている間だけはっきり出す
                if latchEngaged {
                    Label(
                        latchSustaining > 0 ? "キープ中 \(latchSustaining) 音" : "キープ中",
                        systemImage: "hand.raised.fill"
                    )
                    .font(LadylandFont.caption.bold())
                    .foregroundColor(theme.semanticWarningText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(theme.semanticWarningSubtle))
                }
            }
            HStack(spacing: CreoUITokens.spacingS) {
                if let page {
                    ForEach(KnobStrip.cells(page: page, mappings: slot.knobMappings, pedal: pedal)) { cell in
                        KnobStripCellView(
                            cell: cell, slot: slot, controller: controller,
                            color: cellColor(cell.cc), onPickColor: setCellColor)
                    }
                } else {
                    // ページ未確定でも物理の足場（8 枠）は出しておく —
                    // 確定した瞬間にレイアウトが跳ねない
                    ForEach(0..<8, id: \.self) { position in
                        KnobStripCellView(
                            cell: KnobStrip.Cell(
                                position: position, cc: -1, name: nil, badge: nil,
                                reserved: false),
                            slot: slot, controller: controller)
                    }
                }
            }
        }
        // 縦に伸びない（親が高さを持て余しても自分の背丈で止まる）
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// セル 1 枚 = 物理ノブ 1 本
struct KnobStripCellView: View {
    @Environment(\.creoTheme) private var theme
    let cell: KnobStrip.Cell
    @ObservedObject var slot: InstrumentSlot
    let controller: FaceKnobController
    /// 席の明示色（nil = 弧は従来のブランド色）
    var color: UInt8?
    /// 右クリックの色メニュー（nil = 出さない）
    var onPickColor: ((Int, UInt8?) -> Void)?

    /// ページ未確定のプレースホルダ枠（cc = -1）
    private var isPlaceholder: Bool { cell.cc < 0 }

    /// 割当先パラメータの現在値 0-1（素通し・予約・空スロットは nil）
    private var normalizedValue: Double? {
        guard !isPlaceholder, !cell.reserved,
              let mapping = slot.knobMappings.first(where: { $0.knob == cell.cc }),
              let param = slot.parameter(at: mapping.address)
        else { return nil }
        let minValue = Double(param.minValue)
        let range = Double(param.maxValue) - minValue
        guard range > 0 else { return nil }
        return (Double(param.value) - minValue) / range
    }

    /// 未キャッチの物理ノブ位置（キャッチ済み・未受信は nil）
    private var ghostValue: Double? {
        guard normalizedValue != nil else { return nil }
        let state = controller.pickupState(cc: cell.cc)
        guard !state.engaged else { return nil }
        return state.knobValue
    }

    /// 枠の中身（純関数 — テスト対象）。
    ///
    /// **未割り当ては `‐`**（mako 裁定 2026-08-06「パラメータが未割り当ての場合、
    /// グレー背景で `‐` で表示する」）。GUI 全体で同じ規則にする。
    ///
    /// ⚠️ **プレースホルダ（`—`）と未割り当て（`‐`）は分ける**。
    /// - プレースホルダ = **枠そのものが未確定**（ページが決まっていない）
    /// - 未割り当て = **枠はあるが何も載っていない**（帯が飲むので、
    ///   回しても楽器には届かない — 割り当てれば効く）
    ///
    /// 状態が別物なので、同じ見た目にしてはいけない。
    /// em dash（長い）と hyphen（短い）で字面の長さも違う
    enum Caption: Equatable {
        case placeholder
        case assigned(String)
        case unassigned

        var text: String {
            switch self {
            case .placeholder: return "—"
            case .assigned(let name): return name
            case .unassigned: return "‐"
            }
        }

        /// **未割り当てかどうか**（グレー背景の判定に使う）
        var isUnassigned: Bool { self == .unassigned }
    }

    /// ⚠️ `switch` の case 順に依存させないため純関数に出す
    /// （`d24424a` で `where` 付き case が到達不能だった件と同じ轍を踏まない）
    static func caption(isPlaceholder: Bool, name: String?) -> Caption {
        if isPlaceholder { return .placeholder }
        if let name { return .assigned(name) }
        return .unassigned
    }

    private var caption: Caption {
        Self.caption(isPlaceholder: isPlaceholder, name: cell.name)
    }

    private var captionColor: Color {
        cell.name == nil ? theme.textTertiary : theme.textPrimary
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Text("\(cell.position + 1)")
                    .font(LadylandFont.captionNumber)
                    .foregroundColor(theme.textTertiary)
                // 色チップ — 押すと 83 色パレットの popover（mako 要望
                // 2026-08-16「"席の色" メニューよりパレットが出て欲しい」。
                // Track 面ヘッダのトラックカラーと同じ UX）
                if let onPickColor, !isPlaceholder, !cell.reserved {
                    RotoColorChip(
                        current: color,
                        onPick: { onPickColor(cell.cc, $0) },
                        size: 10)
                }
                Spacer()
                if let badge = cell.badge {
                    Text(badge)
                        .font(LadylandFont.caption.bold())
                        .foregroundColor(theme.brandPrimary)
                }
            }
            KnobDial(
                value: normalizedValue, ghost: ghostValue,
                accent: color.map { RotoPaletteMap.color($0) })
            Text(caption.text)
                .font(LadylandFont.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(captionColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        // 幅はタイルと同一 — billboard の 8 列とノブ 8 本が縦に揃う
        .frame(width: SlotView.width, height: 76)
        .background(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                // **未割り当てはグレーの地**（mako 裁定 2026-08-06）。
                // 空席のカードを `.outlined` で沈ませているのと同じ方向で、
                // 「ここには何も載っていない」を地の色で言う
                .fill(caption.isUnassigned ? theme.surfaceBgSubtle : theme.surfaceSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .stroke(theme.surfaceBorderSubtle, lineWidth: 1)
        )
        .opacity(cell.reserved || isPlaceholder ? 0.55 : 1)
        .help(helpText)
    }

    /// ⚠️ **「回すと何が起きるか」をツールチップに出す**。
    /// 帯（`KeystageKnobs.intercepted`）の CC は**割当が無くても飲む**ので、
    /// 未割当ノブを回しても楽器には何も届かない（監査 2026-08-08 の B-2 で
    /// 「素通しで飛ぶ」という旧世界の文言を修正 — #75 以降は嘘だった）
    private var helpText: String {
        guard !isPlaceholder else { return "ページ未確定 — ノブを回すと追従" }
        let label = "\(FaceKnobAssignment.ctrlLabel(cell.cc)) (CC\(cell.cc))"
        if cell.reserved { return "\(label): \(caption.text) — 予約（割当対象外）" }
        switch caption {
        case .assigned(let name): return "\(label): \(name)"
        case .unassigned: return "\(label): 未割り当て — 回しても楽器へは届かない（割り当てると効く）"
        case .placeholder: return label
        }
    }
}

/// 円弧ダイヤル — 弧 = パラメータ現在値、針 = 未キャッチの物理ノブ位置。
/// 下 1/4 が開いた 270° の弧（7 時半 → 4 時半、実機ポットと同じ回転範囲）
private struct KnobDial: View {
    @Environment(\.creoTheme) private var theme
    let value: Double?
    let ghost: Double?
    /// 席の明示色（パラメータ色/席色。nil = ブランド色 — 色を付けた席だけ
    /// 弧が変わるので、HUD 全体が淡色に沈まない）
    var accent: Color?

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(
                    theme.surfaceBorderSubtle,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(135))
            if let value {
                Circle()
                    .trim(from: 0, to: 0.75 * min(max(value, 0), 1))
                    .stroke(
                        accent ?? theme.brandPrimary,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(135))
            }
            if let ghost {
                // ゴースト針: ピックアップが掴むまでの物理ノブ位置。
                // 弧との差がそのまま「どちらへ回せば掴めるか」
                Capsule()
                    .fill(theme.semanticWarning)
                    .frame(width: 2, height: 8)
                    .offset(y: -7)
                    .rotationEffect(.degrees(225 + 270 * min(max(ghost, 0), 1)))
            }
        }
        .frame(width: 26, height: 26)
    }
}
