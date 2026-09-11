//! Keystage 面 — **機材の受け方 = 演奏**（ARP / CHORD / テンポ同期 /
//! ボタン焼き。面の責務原則 2026-08-14 — Page の設計は Track 面へ、
//! 割当パネルはこの面から退いた。設定ウィンドウからも撤去 = 一箇所だけ）。
//!
//! ⚠️ **ここが映すのは「ladyland が送った設定」**。本体で操作した内容は
//! ホストから読めない（Dump は保存済みしか返さない — docs/keystage/README.md
//! 「Dump の二重構造」）。起動時に実機から一度読んで初期値にしているので、
//! ズレた状態からは始まらない。
//!
//! ⚠️ **ARP / CHORD の on/off はここに無い**。Dump に載らないので
//! ホストからは起こせない — **起動は本体のボタン、中身はここから**。
//! 変更は即実機へ送られるが本体には保存されない（電源で元に戻る）。

import CreoUI
import KeystageKit
import SwiftUI

struct KeystageSettingsView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    /// **焼くボタンの CC 範囲**（`ladylandButtonCCs` から引く）。
    /// ⚠️ **画面の数字を直書きしない** — 2026-08-08 に旧値（CC96-101 / 121-123）の
    /// まま残っていて、**実際に焼く 102-110 と食い違っていた**
    static var burnedButtonRange: String {
        "CC" + AssignList.compactRanges(Keystage.ladylandButtonCCs.map { Int($0.1) })
    }

    /// 焼くエンコーダーの CC 範囲（`ladylandEncoderCCs` から引く）
    static var burnedEncoderRange: String {
        "CC" + AssignList.compactRanges(Keystage.ladylandEncoderCCs.map { Int($0.1) })
    }

    /// 取り込み元の User セット（0-31）
    @State private var copySource = 0

    private var settings: Binding<KeystageSettings> {
        $appState.keystageSettings
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CreoUITokens.spacingL) {
                header

                GroupBox("アルペジエーター") {
                    VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
                        picker("モード", settings.arpMode, KeystageSettings.arpModeNames)
                        picker("レート", settings.arpRate, KeystageSettings.arpRateNames)

                        Picker("オクターブ", selection: settings.arpOctave) {
                            ForEach(0..<4, id: \.self) { Text("\($0 + 1)").tag($0) }
                        }
                        .pickerStyle(.segmented)

                        Toggle("ラッチ（手を離しても鳴り続ける）", isOn: settings.arpLatch)
                        Toggle("キーシンク（弾き直しで頭から）", isOn: settings.arpKeySync)

                        slider("スウィング", settings.arpSwing, 0...100, unit: "%")
                        slider(
                            "ゲート長", settings.arpGateTime, 0...200, unit: "",
                            display: { "\($0 - 100 > 0 ? "+" : "")\($0 - 100)%" })
                        slider("確率", settings.arpChance, 1...100, unit: "%")

                        HStack {
                            Text("ベロシティ")
                            Spacer()
                            Text(settings.arpVelocity.wrappedValue == 0
                                ? "弾いた強さ" : "\(settings.arpVelocity.wrappedValue) 固定")
                                .foregroundColor(theme.textSecondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.arpVelocity.wrappedValue) },
                                set: { settings.arpVelocity.wrappedValue = Int($0) }),
                            in: 0...127, step: 1)
                    }
                    .padding(CreoUITokens.spacingS)
                }

                GroupBox("コード") {
                    VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
                        Picker("コードセット", selection: settings.chordSet) {
                            // **Preset は機器内蔵**（読めない・編集できない）。
                            // User は Global Dump に入っていて ladyland から作れる
                            Section("ユーザー — ここに作る") {
                                ForEach(32..<64, id: \.self) {
                                    Text(KeystageSettings.chordSetName($0)).tag($0)
                                }
                            }
                            Section("プリセット — 読み取り不可") {
                                ForEach(0..<32, id: \.self) {
                                    Text(KeystageSettings.chordSetName($0)).tag($0)
                                }
                            }
                        }
                        picker(
                            "ストラム方向", settings.strumDirection,
                            KeystageSettings.strumDirectionNames)
                        slider("ストラム量", settings.strumTime, 0...100, unit: "")

                        Divider()
                        chordSetContents
                    }
                    .padding(CreoUITokens.spacingS)
                }
            }
            .padding(CreoUITokens.spacingM)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            HStack(spacing: CreoUITokens.spacingS) {
                Circle()
                    .fill(appState.keystage.connected
                        ? theme.semanticSuccessText : theme.textSecondary)
                    .frame(width: 8, height: 8)
                Text(appState.keystage.connected ? "Keystage 接続中" : "Keystage 未接続")
                    .foregroundColor(theme.textSecondary)
            }
            // 説明テキストはオフ（mako 流儀 2026-08-13「テキストの説明は、
            // 全部オフ」— on/off は本体ボタン / 即時送信・非保存、はファイル
            // 冒頭のコメントが知識の置き場）

            Divider()
            tempoSection

            Divider()
            buttonSection
        }
    }

    /// **ボタンの CC を ladyland の規約へ**（mako 裁定 2026-08-05）
    private var buttonSection: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            HStack {
                Button("ボタン・エンコーダーの CC を焼く") { appState.keystage.burnLadylandButtons() }
                    .disabled(!appState.keystage.connected)
                Spacer()
            }
            // 説明テキストはオフ（2026-08-14）。知識: ボタン類を MIDI 未定義の
            // 空き帯（burnedButtonRange / burnedEncoderRange — **焼く値から引く**、
            // 直書きすると 2026-08-08 のように嘘になる）へ寄せる。焼くまでは
            // CC41-49 / 58-59 の実用領域に居て、割当があると押した瞬間 127 へ
            // 飛ぶ。ノブは CC を持てない（位置固定）。確認は KONTROL EDITOR
        }
    }

    /// **テンポ同期**（mako 裁定 2026-08-05）。Keystage が送る MIDI Clock を
    /// 読んで、プラグインへ渡すかどうか
    private var tempoSection: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            HStack(spacing: CreoUITokens.spacingM) {
                Toggle("テンポ同期", isOn: $appState.tempoSyncEnabled)
                    .toggleStyle(.switch)
                if let bpm = appState.clockBPM {
                    Text(String(format: "%.1f BPM", bpm))
                        .monospacedDigit()
                        .foregroundColor(theme.textSecondary)
                } else {
                    Text("Clock を受けていない")
                        .font(LadylandFont.deskCaption)
                        .foregroundColor(theme.textTertiary)
                }
                Spacer()
            }
            // 説明テキストはオフ（2026-08-14）。知識: MIDI Clock からテンポを
            // 読んでプラグインへ渡す（切ると各自の既定 ≒ 120 BPM — 2026-08-05
            // まではずっとその状態だった）。BPM は SysEx では取れないので、
            // Clock が止まる操作（ARP 停止等）をすると読めなくなる
        }
    }

    // MARK: - セットの中身

    /// 選んでいるセットの 12 キーぶんを一覧する。
    /// ⚠️ **Preset は機器内蔵で Dump に含まれない**ので表示できない
    @ViewBuilder
    private var chordSetContents: some View {
        let selected = settings.chordSet.wrappedValue
        HStack {
            Text("セットの中身")
                .font(LadylandFont.deskHeading)
            Spacer()
            Button("実機から読む") { appState.keystage.loadGlobalDump() }
                .disabled(!appState.keystage.connected)
        }

        if selected < 32 {
            // **Preset は行き止まり** — 機器内蔵なので読むことも編集することも
            // できない。留まらせず User へ導く（mako 2026-08-04
            //「Keystage の Preset と分ければ良い。で User1 に移動して、
            // 新しく作っていく UX」）
            VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
                Text("プリセットは機器内蔵です — **中身を読むことも、編集することもできません**")
                    .font(LadylandFont.deskCaption)
                    .foregroundColor(theme.textSecondary)
                Button("User1 で作り始める") {
                    settings.chordSet.wrappedValue = 32
                    if appState.keystageGlobalDump == nil {
                        appState.keystage.loadGlobalDump()
                    }
                }
                .disabled(!appState.keystage.connected)
            }
        } else if let dump = appState.keystageGlobalDump {
            let userSet = selected - 32
            HStack(spacing: CreoUITokens.spacingS) {
                Text("セット名")
                    .font(LadylandFont.deskCaption)
                    .foregroundColor(theme.textSecondary)
                // 実機の枠は 6 byte（null 終端込み）なので実質 5 字
                TextField(
                    "5 字まで",
                    text: Binding(
                        get: { Keystage.chordSetName(from: dump, set: userSet) ?? "" },
                        set: { appState.keystage.writeChordSetName(set: userSet, name: $0) })
                )
                .frame(width: 120)
            }
            copyFrom(dump: dump, target: userSet)
            nowPlaying
            VStack(spacing: 2) {
                ForEach(0..<12, id: \.self) { key in
                    chordRow(dump: dump, set: userSet, key: key)
                }
            }
        } else {
            Text("「実機から読む」で User セットの中身を取り込めます")
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textSecondary)
        }
    }

    /// 他の User セットから丸ごと写す（**インポート元を選ぶ**）。
    /// Preset は Global Dump に無いので元にできない — 取り込むには実機で
    /// Preset を選んで各キーを弾き、「登録」で 1 キーずつ移す
    private func copyFrom(dump: [UInt8], target: Int) -> some View {
        HStack(spacing: CreoUITokens.spacingS) {
            Text("取り込み元")
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textSecondary)
            Picker("", selection: $copySource) {
                ForEach(0..<32, id: \.self) { set in
                    let name = Keystage.chordSetName(from: dump, set: set) ?? ""
                    Text(name.isEmpty ? "User\(set + 1)" : "User\(set + 1)（\(name)）")
                        .tag(set)
                }
            }
            .labelsHidden()
            .frame(width: 170)
            Button("このセットへ写す") {
                appState.keystage.copyChordSet(from: copySource, to: target)
            }
            .disabled(copySource == target)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    /// いま押さえている和音（「弾いて登録」の入力）
    @ViewBuilder
    private var nowPlaying: some View {
        let notes = appState.heldNotes
        HStack(spacing: CreoUITokens.spacingS) {
            Text("いま押さえている:")
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textSecondary)
            if notes.isEmpty {
                Text("—").foregroundColor(theme.textSecondary)
            } else {
                Text(appState.heldChord?.name ?? "?")
                    .bold()
                Text(notes.map { Chord.noteName(Int($0)) + "\(Int($0) / 12 - 1)" }
                    .joined(separator: " "))
                    .font(LadylandFont.deskCaption)
                    .foregroundColor(theme.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func chordRow(dump: [UInt8], set: Int, key: Int) -> some View {
        let notes = Keystage.chord(from: dump, set: set, key: key) ?? []
        // 和音名は判定器に任せる — 画面と実機で同じ呼び名になる
        let chord = ChordDetector.detect(
            notes: notes,
            keyRoot: appState.keyScale.root, scale: appState.keyScale.scale)
        return HStack(spacing: CreoUITokens.spacingS) {
            Text(Chord.noteName(key))
                .frame(width: 28, alignment: .leading)
                .monospacedDigit()
            Text(chord?.name ?? (notes.isEmpty ? "—" : "?"))
                .frame(width: 80, alignment: .leading)
                .foregroundColor(chord == nil ? theme.textSecondary : theme.textPrimary)
            Text(notes.map { Chord.noteName(Int($0)) + "\(Int($0) / 12 - 1)" }
                .joined(separator: " "))
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textSecondary)
            Spacer()
            // **弾いて覚えさせる** — いま押さえている和音をこのキーに書く。
            // キープ中の音は入力に含めていないので、ペダルを踏んでいても濁らない
            Button("登録") {
                appState.keystage.writeChord(
                    set: set, key: key, notes: appState.heldNotes)
            }
            .disabled(appState.heldNotes.isEmpty)
            .help("いま押さえている和音を \(Chord.noteName(key)) に割り当てる")
        }
    }

    // MARK: - 小道具

    private func picker(_ label: String, _ value: Binding<Int>, _ names: [String]) -> some View {
        Picker(label, selection: value) {
            ForEach(names.indices, id: \.self) { Text(names[$0]).tag($0) }
        }
    }

    private func slider(
        _ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>, unit: String,
        display: ((Int) -> String)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            HStack {
                Text(label)
                Spacer()
                Text(display?(value.wrappedValue) ?? "\(value.wrappedValue)\(unit)")
                    .foregroundColor(theme.textSecondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0) }),
                in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
        }
    }
}
