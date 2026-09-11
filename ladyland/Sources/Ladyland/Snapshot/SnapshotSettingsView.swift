//! スナップショットタブ — 書き出しと**部分ロード**の UI
//! （mako 要望 2026-08-02）。
//!
//! 書き出しは 1 クリック。読み込みは**必ず中身を見せてから選ばせる** —
//! 「開いた瞬間に全部入れ替わる」を作らない（ライブ機材で一番怖い操作）。

import AppKit
import CreoUI
import SwiftUI

struct SnapshotSettingsView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    @State private var loaded: LlDataSnapshot?
    @State private var loadedURL: URL?
    @State private var selection: Set<Int> = []
    @State private var includeGlobals = false
    @State private var includeBlobs = true
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
            Text("書き出し")
                .font(LadylandFont.deskHeading)
                .foregroundColor(theme.textPrimary)

            HStack {
                Button("スナップショットを書き出す…", action: exportSnapshot)
                Toggle("音色を含める", isOn: $includeBlobs)
                    .toggleStyle(.checkbox)
            }
            Text(
                "いまの席・音量・割当・棚を `lldata-snapshot-{日付}.kdl` に書き出します。"
                    + "音色を含めると持ち出せる完全な控えに、外すと構造だけの軽いファイル（差分向き）になります。"
            )
            .font(LadylandFont.deskCaption)
            .foregroundColor(theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("読み込み（部分ロード）")
                .font(LadylandFont.deskHeading)
                .foregroundColor(theme.textPrimary)

            HStack {
                Button("ファイルを選ぶ…", action: openSnapshot)
                if let loadedURL {
                    Text(loadedURL.lastPathComponent)
                        .font(LadylandFont.deskCaption)
                        .foregroundColor(theme.textSecondary)
                }
            }

            if let loaded {
                Text("入れたい席にチェックを付けてください（チェックした席だけが入れ替わります）")
                    .font(LadylandFont.deskCaption)
                    .foregroundColor(theme.textTertiary)

                List {
                    ForEach(loaded.contents, id: \.index) { item in
                        Toggle(isOn: binding(for: item.index)) {
                            HStack(spacing: CreoUITokens.spacingS) {
                                Text("\(item.index + 1)")
                                    .font(LadylandFont.deskBody.monospacedDigit())
                                    .foregroundColor(theme.textTertiary)
                                    .frame(width: 28, alignment: .trailing)
                                Text(item.name)
                                if !item.hasState {
                                    Text("音色なし")
                                        .font(LadylandFont.deskCaption)
                                        .foregroundColor(theme.semanticWarningText)
                                }
                                if item.drafts > 0 {
                                    Text("棚 \(item.drafts)")
                                        .font(LadylandFont.deskCaption)
                                        .foregroundColor(theme.textTertiary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(minHeight: 160)

                HStack {
                    Button("すべて選ぶ") { selection = Set(loaded.contents.map(\.index)) }
                    Button("選択を外す") { selection = [] }
                    Toggle("キー・出力・LED も入れる", isOn: $includeGlobals)
                        .toggleStyle(.checkbox)
                    Spacer()
                    Button("選んだ席を入れる") { apply(loaded) }
                        .buttonStyle(.borderedProminent)
                        .disabled(selection.isEmpty)
                }
            }

            if let message {
                Text(message)
                    .font(LadylandFont.deskCaption)
                    .foregroundColor(
                        isError ? theme.semanticWarningText : theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func binding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { selection.contains(index) },
            set: { isOn in
                if isOn { selection.insert(index) } else { selection.remove(index) }
            })
    }

    private func exportSnapshot() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = LlDataSnapshot.fileName(for: Date())
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appState.exportSnapshot(to: url, includeBlobs: includeBlobs)
            report("書き出しました: \(url.lastPathComponent)", error: false)
        } catch {
            report("書き出しに失敗しました: \(error.localizedDescription)", error: true)
        }
    }

    private func openSnapshot() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let snapshot = try appState.readSnapshot(at: url)
            loaded = snapshot
            loadedURL = url
            selection = []
            report("\(snapshot.slots.count) 席が入っています。入れたい席を選んでください。", error: false)
        } catch {
            loaded = nil
            loadedURL = nil
            report("読み込めませんでした: \(error)", error: true)
        }
    }

    private func apply(_ snapshot: LlDataSnapshot) {
        appState.applySnapshot(
            snapshot, slotIndices: selection, includeGlobals: includeGlobals)
        report("\(selection.count) 席を入れました。", error: false)
    }

    private func report(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}
