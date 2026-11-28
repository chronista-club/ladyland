//! nanoKONTROL2 の S → ノブ → S と同じ入力元選択を Mixer に表示する。
import CreoUI
import SwiftUI

struct StudioRoutingControls: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.creoTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            if appState.windowPlacement.docks?[VirtualComponent.mixer.rawValue] == "nanokontrol.faders" {
                Text("nanoKONTROL2 · S → ノブ → S")
                    .foregroundStyle(theme.textSecondary)
            } else {
                Button("nanoKONTROL2 に割り当て") {
                    appState.windowPlacement.setDock(.mixer, on: "nanokontrol.faders")
                }
            }

            if let pending = appState.studioSelection.pending {
                HStack {
                    Text("T\(pending.slot + 1) の入力元")
                    Picker("入力元", selection: Binding(
                        get: { pending.keyboard },
                        set: { appState.studioSelection.choose($0, for: pending.slot) }
                    )) {
                        ForEach(StudioKeyboard.allCases) { keyboard in
                            Text(keyboard.title).tag(keyboard)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("接続する") { appState.pressStudioSelect(pending.slot) }
                    Button("取消") { appState.studioSelection.cancel() }
                }
            }
        }
        .font(LadylandFont.deskCaption)
        .controlSize(.small)
    }
}
