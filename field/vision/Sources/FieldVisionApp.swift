//! LadylandField — **Field に降り立つ**（spec/08 v0）。
//!
//! 入口の小窓（接続先 + 降りるボタン）と ImmersiveSpace。v0 は mixed
//! immersion — スタジオの現実に lady が浮かぶ（部屋を消すのは field の
//! 物性が育ってから）。

import SwiftUI

@main
struct FieldVisionApp: App {
    @State private var client = FieldClient()
    @State private var immersed = false

    var body: some Scene {
        WindowGroup {
            LandingView(immersed: $immersed)
                .environment(client)
        }
        .defaultSize(width: 420, height: 260)

        ImmersiveSpace(id: "field") {
            FieldSpace()
                .environment(client)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

/// 入口 — 接続先（Mac のホスト名）と「降りる」
struct LandingView: View {
    @Environment(FieldClient.self) private var client
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @Binding var immersed: Bool
    @AppStorage("fieldHost") private var host = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Ladyland Field")
                .font(.title)
            TextField("Mac のホスト名（例: makomac.local）", text: $host)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Circle()
                    .fill(client.connected ? .green : .secondary)
                    .frame(width: 10, height: 10)
                Text(client.connected
                    ? "field 接続中（\(client.entities.count) 体）"
                    : "未接続")
                    .foregroundStyle(.secondary)
            }
            Button(immersed ? "戻る" : "Field に降りる") {
                Task {
                    if immersed {
                        await dismissSpace()
                        immersed = false
                    } else {
                        client.start(host: host)
                        if await openSpace(id: "field") == .opened {
                            immersed = true
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(host.isEmpty)
        }
        .padding(24)
    }
}
