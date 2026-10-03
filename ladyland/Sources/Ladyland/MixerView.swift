//! 8ch ミキサー面（mako 火花 2026-10-01「8ch の Mixer component 欲しいな」
//! 「いわゆる DAW のミキサー的な感じで」）。
//!
//! 縦のチャンネルストリップ × 8 = **選択中のバンク**（LPD8 PROG4 の Track 選択と
//! 同じ切り方）。上からトラック名 + 色、メーター付きの縦フェーダー、M ボタンと
//! 数値。gain / mute / level / 色 / 名前は席（`InstrumentSlot`）が持っている
//! ものをそのまま映す — MIXER Jack（nanoKONTROL2 のフェーダー 8）の画面側の顔。
//!
//! 色の語彙は Track タイルの `GainBar` / `LevelBar` と同じ（選択 = live、
//! 他 = standby、メーターは AV semantic）。

import CreoUI
import SwiftUI

/// 純関数（テスト対象）
enum MixerModel {
    /// 面に出す 8 席 — 選択中の席を含むバンク。端数のバンクは在る分だけ
    static func bankIndices(selected: Int, trackCount: Int) -> [Int] {
        let size = 8  // = `InstrumentRack.visibleCount`（バンク = LPD8 の 8 パッド）
        let start = (max(selected, 0) / size) * size
        return Array(start..<min(start + size, max(trackCount, 0)))
    }

    /// フェーダーのドラッグ位置（上が 0）→ gain 0-1（下 0 / 上 1、枠外は端）
    static func gain(atY y: CGFloat, height: CGFloat) -> Float {
        guard height > 0 else { return 0 }
        return Float(min(max(1 - y / height, 0), 1))
    }

    /// ストリップの見出し — トラック名 > プラグイン名（`trackName` が畳む）> T 番号
    static func title(index: Int, trackName: String?) -> String {
        trackName ?? "T\(index + 1)"
    }
}

struct MixerView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    /// 右端にドラム席のストリップを足す（机 — ドラムのケーブルの着地点）
    var includeDrums = false

    /// 面の幅（ストリップ n 本 + 間隔 + 余白）。机が縮尺の前の寸法に使う
    static func width(strips n: Int) -> CGFloat {
        CGFloat(n) * MixerStrip.width + CGFloat(max(n - 1, 0)) * CreoUITokens.spacingS
            + 2 * CreoUITokens.spacingM
    }

    var body: some View {
        let indices = MixerModel.bankIndices(
            selected: appState.rack.selected, trackCount: appState.rack.slots.count)
        HStack(alignment: .top, spacing: CreoUITokens.spacingS) {
            ForEach(indices, id: \.self) { index in
                MixerStrip(
                    slot: appState.rack.slots[index],
                    isSelected: index == appState.rack.selected,
                    onSelect: { appState.select(index) },
                    onGain: { appState.setGain(appState.rack.slots[index], to: $0) },
                    onMute: { appState.toggleMute(appState.rack.slots[index]) })
                    // 机のケーブルの着地点（Mixer タブでは誰も読まない）
                    .anchorPreference(key: DeskAnchorKey.self, value: .bounds) {
                        ["strip.\(index)": $0]
                    }
            }
            if includeDrums {
                MixerStrip(
                    slot: appState.rack.drumSlot, isSelected: false, title: "DRUMS",
                    onSelect: {},
                    onGain: { appState.setGain(appState.rack.drumSlot, to: $0) },
                    onMute: { appState.toggleMute(appState.rack.drumSlot) })
                    .anchorPreference(key: DeskAnchorKey.self, value: .bounds) {
                        ["strip.drums": $0]
                    }
            }
        }
        .padding(CreoUITokens.spacingM)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// チャンネルストリップ 1 本
struct MixerStrip: View {
    @Environment(\.creoTheme) private var theme
    @ObservedObject var slot: InstrumentSlot
    let isSelected: Bool
    /// 見出しの上書き（ドラム席は「DRUMS」）
    var title: String? = nil
    let onSelect: () -> Void
    let onGain: (Float) -> Void
    let onMute: () -> Void

    static let width: CGFloat = 64

    var body: some View {
        VStack(spacing: CreoUITokens.spacingS) {
            // 見出し — 色チップ + 名前（クリックで選択）
            HStack(spacing: 4) {
                Circle()
                    .fill(slot.rotoColor.map(RotoPaletteMap.color) ?? theme.textTertiary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(title ?? MixerModel.title(index: slot.index, trackName: slot.trackName))
                    .font(LadylandFont.deskCaption)
                    .foregroundColor(isSelected ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            // フェーダー + メーター
            GeometryReader { geo in
                HStack(spacing: 4) {
                    fader(height: geo.size.height)
                    LevelBar(level: slot.level, height: geo.size.height)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 160)

            // 数値 + M
            Text(String(format: "%.0f", slot.gain * 100))
                .font(LadylandFont.captionNumber)
                .foregroundColor(theme.textTertiary)
                .monospacedDigit()
            Button(action: onMute) {
                Text("M")
                    .font(LadylandFont.deskCaption)
                    .frame(width: 24, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(slot.mute ? theme.semanticError : theme.surfaceBgEmphasis))
                    .foregroundColor(slot.mute ? theme.textPrimary : theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help(slot.mute ? "ミュート解除" : "ミュート")
        }
        .padding(CreoUITokens.spacingS)
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .fill(isSelected ? theme.surfaceBgEmphasis : theme.surfaceSurface))
        .overlay(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .stroke(isSelected ? theme.brandPrimary : theme.surfaceBorderSubtle, lineWidth: 1))
    }

    /// 縦フェーダー — ドラッグで gain。`GainBar` と同じ色（選択 = live）
    private func fader(height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.levelTrack)
            RoundedRectangle(cornerRadius: 3)
                .fill(slot.mute ? theme.textTertiary.opacity(0.5) : (isSelected ? theme.live : theme.standby))
                .frame(height: height * CGFloat(slot.gain))
            // つまみ
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.textPrimary.opacity(0.9))
                .frame(height: 6)
                .offset(y: -height * CGFloat(slot.gain) + 3)
        }
        .frame(width: 14, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onGain(MixerModel.gain(atY: value.location.y, height: height))
                }
        )
    }
}
