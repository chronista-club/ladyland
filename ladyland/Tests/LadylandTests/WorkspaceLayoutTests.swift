// mem_1ChUnGHxJNU9XAJdmdySnR
import AppKit
import Foundation
import Testing

@testable import Ladyland

@Suite("中央ワークスペースと Inspector")
struct WorkspaceLayoutTests {
    @Test("window.json はワークスペースの選択を保持する", arguments: ["play", "mixer", "studio"])
    func workspaceSelectionSurvivesRoundTrip(selection: String) throws {
        let json = Data("""
            {"mode":"windowed","assignTab":"lpd8","drumPaneExpanded":true,"workspaceTab":"\(selection)"}
            """.utf8)
        let prefs = try JSONDecoder().decode(WindowPreferences.self, from: json)
        let encoded = try JSONEncoder().encode(prefs)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["workspaceTab"] as? String == selection)
        #expect(prefs.assignTab == .lpd8)
        #expect(prefs.drumPaneExpanded == true)
    }

    @MainActor
    @Test("旧設定は Play で開き、タブの変更を次回起動へ引き継ぐ")
    func controllerRestoresWorkspace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-workspace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("window.json")
        try Data(#"{"mode":"windowed","assignTab":"jack","drumPaneExpanded":true}"#.utf8)
            .write(to: url)

        let controller = WindowPlacementController(storeURL: url)
        #expect(controller.workspaceTab == .play)
        #expect(controller.assignTab == .jack)
        #expect(controller.drumPaneExpanded)
        controller.workspaceTab = .studio

        let restored = WindowPlacementController(storeURL: url)
        #expect(restored.workspaceTab == .studio)
        #expect(restored.assignTab == .jack)
        #expect(restored.drumPaneExpanded)
    }

    @MainActor
    @Test("中央タブには別々の SF Symbol と対応するポップアウトがある")
    func workspacePresentation() {
        let tabs = WorkspaceTab.allCases
        #expect(tabs.map(\.title) == ["Play", "Mixer", "Studio"])
        #expect(tabs.map(\.paneID) == [nil, .xtouch, .jack])
        #expect(Set(tabs.map(\.icon)).count == tabs.count)
        for tab in tabs {
            #expect(NSImage(systemSymbolName: tab.icon, accessibilityDescription: nil) != nil)
        }
    }

    @Test("Inspector は Track と 3 機材だけを表示し、旧設定の中央面は Track へ戻す")
    func inspectorSurface() {
        #expect(SurfaceTab.gearTabs == [.roto, .keystage, .lpd8])
        for tab in [.track] + SurfaceTab.gearTabs {
            #expect(tab.inspectorTab == tab)
        }
        for tab in [SurfaceTab.mixer, .xtouch, .jack] {
            #expect(tab.inspectorTab == .track)
        }
    }
}
