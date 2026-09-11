import Foundation
import CoreMIDI
import AppKit

// MARK: - MIDI Manager

class MIDIManager {
    private var midiClient: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var outputPort: MIDIPortRef = 0
    private var lpd8Source: MIDIEndpointRef = 0
    private var lpd8Destination: MIDIEndpointRef = 0

    // LED輝度 (0.0 - 1.0)
    private var ledBrightness: Float = 1.0

    // 設定
    private var config: LauncherConfig?
    private let windowManager = WindowManager()

    // 現在のContext/Scene
    private var currentContext: String?
    private var currentScene: String?

    init() {
        setupMIDI()
    }

    // MARK: - Config

    func loadConfig(from path: String) {
        do {
            config = try ConfigLoader.load(from: path)
            print("設定を読み込みました: \(path)")
            updateLEDsFromConfig()
        } catch {
            print("設定読み込みエラー: \(error)")
        }
    }

    func loadConfigFromString(_ content: String) {
        do {
            config = try ConfigLoader.loadFromString(content)
            print("設定を読み込みました")
            updateLEDsFromConfig()
        } catch {
            print("設定読み込みエラー: \(error)")
        }
    }

    // MARK: - MIDI Setup

    private func setupMIDI() {
        // MIDIクライアント作成
        let status = MIDIClientCreateWithBlock("bikeboy-launcher" as CFString, &midiClient) { [weak self] notification in
            self?.handleMIDINotification(notification)
        }

        guard status == noErr else {
            print("MIDIクライアント作成失敗: \(status)")
            return
        }

        // 入力ポート作成
        MIDIInputPortCreateWithProtocol(
            midiClient,
            "Input" as CFString,
            ._1_0,
            &inputPort
        ) { [weak self] eventList, srcConnRefCon in
            self?.handleMIDIInput(eventList)
        }

        // 出力ポート作成
        MIDIOutputPortCreate(midiClient, "Output" as CFString, &outputPort)

        // LPD8を検索
        findLPD8()
    }

    private func findLPD8() {
        let sourceCount = MIDIGetNumberOfSources()
        let destCount = MIDIGetNumberOfDestinations()

        print("MIDI Sources: \(sourceCount), Destinations: \(destCount)")

        // 入力ソースからLPD8を検索
        for i in 0..<sourceCount {
            let source = MIDIGetSource(i)
            if let name = getMIDIEndpointName(source), name.contains("LPD8") {
                print("LPD8 入力を検出: \(name)")
                lpd8Source = source
                MIDIPortConnectSource(inputPort, source, nil)
            }
        }

        // 出力先からLPD8を検索
        for i in 0..<destCount {
            let dest = MIDIGetDestination(i)
            if let name = getMIDIEndpointName(dest), name.contains("LPD8") {
                print("LPD8 出力を検出: \(name)")
                lpd8Destination = dest
            }
        }

        if lpd8Source == 0 {
            print("LPD8が見つかりません。接続を確認してください。")
        }
    }

    private func getMIDIEndpointName(_ endpoint: MIDIEndpointRef) -> String? {
        var name: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name)
        guard status == noErr, let cfName = name?.takeRetainedValue() else {
            return nil
        }
        return cfName as String
    }

    private func handleMIDINotification(_ notification: UnsafePointer<MIDINotification>) {
        switch notification.pointee.messageID {
        case .msgSetupChanged:
            print("MIDI設定が変更されました")
            findLPD8()
        default:
            break
        }
    }

    private func handleMIDIInput(_ eventList: UnsafePointer<MIDIEventList>) {
        let packet = eventList.pointee.packet

        withUnsafePointer(to: packet) { ptr in
            var p = ptr
            for _ in 0..<eventList.pointee.numPackets {
                let wordCount = Int(p.pointee.wordCount)

                withUnsafePointer(to: p.pointee.words) { wordsPtr in
                    wordsPtr.withMemoryRebound(to: UInt8.self, capacity: wordCount * 4) { bytes in
                        parseMIDIMessage(bytes, count: wordCount * 4)
                    }
                }

                p = UnsafePointer(UnsafeRawPointer(p).advanced(by: MemoryLayout<MIDIEventPacket>.stride).assumingMemoryBound(to: MIDIEventPacket.self))
            }
        }
    }

    private func parseMIDIMessage(_ data: UnsafePointer<UInt8>, count: Int) {
        guard count >= 1 else { return }

        let status = data[0]
        let messageType = status & 0xF0
        let channel = (status & 0x0F) + 1

        switch messageType {
        case 0x90: // Note On
            guard count >= 3 else { return }
            let note = data[1]
            let velocity = data[2]

            if velocity > 0 {
                handlePadOn(note: note, velocity: velocity, channel: channel)
            } else {
                handlePadOff(note: note, channel: channel)
            }

        case 0x80: // Note Off
            guard count >= 3 else { return }
            let note = data[1]
            handlePadOff(note: note, channel: channel)

        case 0xB0: // Control Change
            guard count >= 3 else { return }
            let controller = data[1]
            let value = data[2]
            handleControlChange(controller: controller, value: value, channel: channel)

        default:
            break
        }
    }

    // MARK: - Event Handlers

    private func handlePadOn(note: UInt8, velocity: UInt8, channel: UInt8) {
        let padNumber = noteToPad(note)
        print("Pad \(padNumber) ON (note: \(note), velocity: \(velocity))")

        // 設定からマッピングを検索
        guard let config = config else {
            print("設定が読み込まれていません")
            return
        }

        if let mapping = config.padMappings.first(where: { $0.pad == padNumber }) {
            activateMapping(mapping)
        }
    }

    private func handlePadOff(note: UInt8, channel: UInt8) {
        let padNumber = noteToPad(note)
        print("Pad \(padNumber) OFF")
    }

    private func handleControlChange(controller: UInt8, value: UInt8, channel: UInt8) {
        print("CC \(controller) = \(value)")

        // ノブ1 (CC 70) でLED輝度制御
        if controller == 70 {
            ledBrightness = Float(value) / 127.0
            print("LED輝度: \(Int(ledBrightness * 100))%")
            updateLEDsFromConfig()
        }

        // 他のノブは設定で定義された機能を実行
        if let config = config, let function = config.knobMappings[Int(controller - 69)] {
            print("ノブ機能: \(function)")
        }
    }

    // MARK: - Mapping Activation

    private func activateMapping(_ mapping: PadMapping) {
        guard let config = config else { return }

        guard let context = config.contexts[mapping.contextName] else {
            print("Context not found: \(mapping.contextName)")
            return
        }

        // Scene名を決定
        let sceneName = mapping.sceneName ?? context.defaultScene ?? context.scenes.keys.first

        guard let sceneName = sceneName, let scene = context.scenes[sceneName] else {
            print("Scene not found")
            return
        }

        currentContext = mapping.contextName
        currentScene = sceneName

        // Sceneをアクティブ化
        windowManager.activateScene(scene, in: context)

        // LEDを更新
        updateLEDsFromConfig()
    }

    // MARK: - Pad Mapping

    private func noteToPad(_ note: UInt8) -> Int {
        switch note {
        case 40: return 1
        case 41: return 2
        case 42: return 3
        case 43: return 4
        case 36: return 5
        case 37: return 6
        case 38: return 7
        case 39: return 8
        default: return 0
        }
    }

    // MARK: - LED Control

    private func updateLEDsFromConfig() {
        guard let config = config else {
            updateAllLEDs()
            return
        }

        var colors: [(r: UInt8, g: UInt8, b: UInt8)] = Array(repeating: (0, 0, 0), count: 8)

        // パッドマッピングから色を取得
        for mapping in config.padMappings {
            guard mapping.pad >= 1 && mapping.pad <= 8 else { continue }

            let padIndex = mapping.pad - 1

            if let context = config.contexts[mapping.contextName] {
                let sceneName = mapping.sceneName ?? context.defaultScene ?? context.scenes.keys.first
                if let sceneName = sceneName, let scene = context.scenes[sceneName] {
                    if let color = scene.ledColor {
                        colors[padIndex] = color
                    } else {
                        // デフォルト色
                        colors[padIndex] = defaultColor(for: mapping.pad)
                    }
                }
            }

            // 現在選択中のパッドは明るく
            if mapping.contextName == currentContext {
                let color = colors[padIndex]
                colors[padIndex] = (
                    min(color.r + 30, 127),
                    min(color.g + 30, 127),
                    min(color.b + 30, 127)
                )
            }
        }

        // 輝度を適用
        let adjustedColors = colors.map { color in
            (
                r: UInt8(Float(color.r) * ledBrightness),
                g: UInt8(Float(color.g) * ledBrightness),
                b: UInt8(Float(color.b) * ledBrightness)
            )
        }

        sendLEDColors(adjustedColors)
    }

    private func defaultColor(for pad: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        switch pad {
        case 1: return (127, 0, 0)     // 赤
        case 2: return (0, 127, 0)     // 緑
        case 3: return (0, 0, 127)     // 青
        case 4: return (127, 127, 0)   // 黄
        case 5: return (0, 127, 127)   // シアン
        case 6: return (127, 0, 127)   // マゼンタ
        case 7: return (127, 127, 127) // 白
        case 8: return (127, 64, 0)    // オレンジ
        default: return (0, 0, 0)
        }
    }

    func updateAllLEDs() {
        let colors: [(r: UInt8, g: UInt8, b: UInt8)] = (1...8).map { defaultColor(for: $0) }

        let adjustedColors = colors.map { color in
            (
                r: UInt8(Float(color.r) * ledBrightness),
                g: UInt8(Float(color.g) * ledBrightness),
                b: UInt8(Float(color.b) * ledBrightness)
            )
        }

        sendLEDColors(adjustedColors)
    }

    func sendLEDColors(_ colors: [(r: UInt8, g: UInt8, b: UInt8)]) {
        guard lpd8Destination != 0 else {
            return
        }

        // SysExメッセージ構築: F0 47 7F 4C 06 00 30 [48 bytes RGB] F7
        var sysex: [UInt8] = [0xF0, 0x47, 0x7F, 0x4C, 0x06, 0x00, 0x30]

        for color in colors {
            sysex.append((color.r >> 7) & 0x7F)
            sysex.append(color.r & 0x7F)
            sysex.append((color.g >> 7) & 0x7F)
            sysex.append(color.g & 0x7F)
            sysex.append((color.b >> 7) & 0x7F)
            sysex.append(color.b & 0x7F)
        }

        sysex.append(0xF7)

        sysex.withUnsafeBytes { ptr in
            var packetList = MIDIPacketList()
            var packet = MIDIPacketListInit(&packetList)
            packet = MIDIPacketListAdd(&packetList, 1024, packet, 0, sysex.count, ptr.bindMemory(to: UInt8.self).baseAddress!)
            MIDISend(outputPort, lpd8Destination, &packetList)
        }
    }

    func run() {
        print("bikeboy-launcher 起動")
        print("終了: Ctrl+C")

        // 初期LED設定
        if config != nil {
            updateLEDsFromConfig()
        } else {
            updateAllLEDs()
        }

        RunLoop.main.run()
    }
}

// MARK: - Main

// Accessibility権限チェック
if !WindowManager.checkAccessibilityPermission() {
    print("⚠️  アクセシビリティ権限が必要です")
    print("システム環境設定 > プライバシーとセキュリティ > アクセシビリティ で許可してください")
}

let manager = MIDIManager()

// 設定ファイルのパス
let configPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/bikeboy/launcher.kdl")
    .path

if FileManager.default.fileExists(atPath: configPath) {
    manager.loadConfig(from: configPath)
} else {
    print("設定ファイルがありません: \(configPath)")
    print("サンプル設定で起動します")

    // サンプル設定
    let sampleConfig = """
    // bikeboy-launcher 設定ファイル

    context "bikeboy" default="coding" {
        scene "coding" led-r=0 led-g=127 led-b=64 {
            app "com.todesktop.230313mzl4w4u92" window="bikeboy" {
                position x=0 y=25 width=960 height=1055
            }
            app "com.github.wez.wezterm" {
                position x=960 y=25 width=960 height=1055
            }
        }
    }

    context "vantage" default="coding" {
        scene "coding" led-r=127 led-g=64 led-b=0 {
            app "com.todesktop.230313mzl4w4u92" window="vantage" {
                position x=0 y=25 width=960 height=1055
            }
            app "com.github.wez.wezterm" {
                position x=960 y=25 width=960 height=1055
            }
        }
    }

    // パッドマッピング
    pad 1 context="bikeboy" scene="coding"
    pad 2 context="vantage" scene="coding"

    // ノブマッピング
    knob 1 "led-brightness"
    """

    manager.loadConfigFromString(sampleConfig)
}

manager.run()
