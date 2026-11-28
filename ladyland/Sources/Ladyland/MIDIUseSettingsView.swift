import CreoUI
import LnxClient
import SwiftUI

/// 機材ごとの使用意思。確認時に見た revision を渡し、他アプリの変更を上書きしない。
struct MIDIUseSettingsView: View {
    @Environment(\.creoTheme) private var theme
    @ObservedObject var session: MIDIUseSession
    @State private var takeover: GearView?
    @State private var failure: String?
    @State private var changing: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
            Text("このアプリで使う MIDI 機材")
                .font(LadylandFont.deskHeading)
                .foregroundStyle(theme.textPrimary)
            Text("OFF にすると、その機材の入力・LED・書き込みを停止します。結線と楽器の設定は保持されます。")
                .font(LadylandFont.deskCaption)
                .foregroundStyle(theme.textSecondary)
            if !session.connected {
                Label("MIDI サービスに接続していません", systemImage: "exclamationmark.triangle")
                    .font(LadylandFont.deskCaption)
                    .foregroundStyle(theme.semanticWarningText)
            }
            if let failure {
                Text(failure)
                    .font(LadylandFont.deskCaption)
                    .foregroundStyle(theme.semanticErrorText)
            }
            if let error = session.rotoSetupError {
                Text("ROTO 設定エラー: \(error)")
                    .font(LadylandFont.deskCaption)
                    .foregroundStyle(theme.semanticErrorText)
            }
            if session.devices.contains(where: { $0.profileID == "roto" && $0.setupOwners == nil }) {
                Text("ROTO を使うには MIDI サービスの更新が必要です。サービスを更新してから Ladyland を再起動してください。")
                    .font(LadylandFont.deskCaption)
                    .foregroundStyle(theme.semanticWarningText)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(session.devices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: CreoUITokens.spacingXs) {
                                Text(device.name)
                                    .font(LadylandFont.deskBody)
                                    .foregroundStyle(theme.textPrimary)
                                Text(status(device))
                                    .font(LadylandFont.deskCaption)
                                    .foregroundStyle(theme.textSecondary)
                            }
                            Spacer()
                            if changing.contains(device.id) { ProgressView().controlSize(.small) }
                            Toggle("Ladyland で使用", isOn: Binding(
                                get: { device.assignment.clientID == "ladyland" },
                                set: { enabled in
                                    if enabled, let owner = device.assignment.clientID, owner != "ladyland" {
                                        takeover = device
                                    } else { change(device, enabled: enabled) }
                                }))
                                .labelsHidden().toggleStyle(.switch)
                                .accessibilityLabel("\(device.name) を Ladyland で使用")
                                .disabled(!session.connected || changing.contains(device.id) || device.phase == "releasing")
                        }.padding(.vertical, CreoUITokens.spacingS)
                        Divider()
                    }
                }
            }
        }
        .padding(.top, CreoUITokens.spacingM)
        .alert("Ladyland に切り替えますか？", isPresented: Binding(
            get: { takeover != nil }, set: { if !$0 { takeover = nil } }
        ), presenting: takeover) { device in
            Button("切り替える") { change(device, enabled: true, takeover: true) }
            Button("キャンセル", role: .cancel) {}
        } message: { device in
            Text("\(device.name) は \(device.assignment.clientID ?? "別のアプリ") に割り当てられています。現在の処理が終了してから切り替えます。")
        }
    }
    private func status(_ device: GearView) -> String {
        if let error = device.error { return "接続エラー: \(error)" }
        if device.phase == "releasing" { return "切り替え中…" }
        if device.configuring == true || (device.profileID == "roto" && session.rotoConfiguring) { return "設定を反映中…" }
        if let error = device.configError { return "設定エラー: \(error)" }
        if !device.present {
            if ["roto", "lpd8", "nanokontrol"].contains(device.profileID), device.assignment.clientID == "ladyland" {
                return "使用 ON・機材が見つかりません。接続すると再開します。"
            }
            return "未接続"
        }
        if session.owns(device) { return "Ladyland で使用中" }
        if let owner = device.assignment.clientID { return "\(owner) に割り当て済み" }
        return "使用 OFF"
    }
    private func change(_ device: GearView, enabled: Bool, takeover: Bool = false) {
        changing.insert(device.id)
        failure = nil
        Task {
            defer { changing.remove(device.id) }
            do { try await session.setEnabled(device, enabled: enabled, takeover: takeover) }
            catch { failure = "切り替えできませんでした: \(error.localizedDescription)" }
        }
    }
}
