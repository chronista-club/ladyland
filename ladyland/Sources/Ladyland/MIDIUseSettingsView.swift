import SwiftUI
import MidistageClient

/// 機材ごとの使用意思。確認時に見た revision を渡し、他アプリの変更を上書きしない。
struct MIDIUseSettingsView: View {
    @ObservedObject var session: MIDIUseSession
    @State private var takeover: DeviceView?
    @State private var failure: String?
    @State private var changing: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("このアプリで使う MIDI 機材").font(.headline)
            Text("OFF にすると、その機材の入力・LED・書き込みを停止します。結線と楽器の設定は保持されます。")
                .font(.caption).foregroundStyle(.secondary)
            if !session.connected {
                Label("MIDI サービスに接続していません", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(session.devices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name)
                                Text(status(device)).font(.caption).foregroundStyle(.secondary)
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
                        }.padding(.vertical, 10)
                        Divider()
                    }
                }
            }
        }
        .padding(.top, 12)
        .alert("Ladyland に切り替えますか？", isPresented: Binding(
            get: { takeover != nil }, set: { if !$0 { takeover = nil } }
        ), presenting: takeover) { device in
            Button("切り替える") { change(device, enabled: true, takeover: true) }
            Button("キャンセル", role: .cancel) {}
        } message: { device in
            Text("\(device.name) は \(device.assignment.clientID ?? "別のアプリ") に割り当てられています。現在の処理が終了してから切り替えます。")
        }
    }
    private func status(_ device: DeviceView) -> String {
        if let error = device.error { return "接続エラー: \(error)" }
        if device.phase == "releasing" { return "切り替え中…" }
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
    private func change(_ device: DeviceView, enabled: Bool, takeover: Bool = false) {
        changing.insert(device.id)
        failure = nil
        Task {
            defer { changing.remove(device.id) }
            do { try await session.setEnabled(device, enabled: enabled, takeover: takeover) }
            catch { failure = "切り替えできませんでした: \(error.localizedDescription)" }
        }
    }
}
