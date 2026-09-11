import Foundation

// MARK: - Configuration Models

/// アプリのウィンドウ位置
struct WindowPosition {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

/// Scene内のアプリ設定
struct AppConfig {
    let bundleId: String
    var windowTitle: String?
    var position: WindowPosition?
}

/// Scene（作業状態）
struct Scene {
    let name: String
    var apps: [AppConfig]
    var ledColor: (r: UInt8, g: UInt8, b: UInt8)?
}

/// Context（作業文脈）
struct Context {
    let name: String
    var scenes: [String: Scene]
    var defaultScene: String?
}

/// パッドマッピング
struct PadMapping {
    let pad: Int
    let contextName: String
    let sceneName: String?
}

/// 全体設定
struct LauncherConfig {
    var contexts: [String: Context]
    var padMappings: [PadMapping]
    var knobMappings: [Int: String] // knob番号 -> 機能名
}

// MARK: - Config Loader

class ConfigLoader {

    static func load(from path: String) throws -> LauncherConfig {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let nodes = try KDLParser.parse(content)
        return try parseConfig(nodes)
    }

    static func loadFromString(_ content: String) throws -> LauncherConfig {
        let nodes = try KDLParser.parse(content)
        return try parseConfig(nodes)
    }

    private static func parseConfig(_ nodes: [KDLNode]) throws -> LauncherConfig {
        var contexts: [String: Context] = [:]
        var padMappings: [PadMapping] = []
        var knobMappings: [Int: String] = [:]

        for node in nodes {
            switch node.name {
            case "context":
                let context = try parseContext(node)
                contexts[context.name] = context

            case "pad":
                let mapping = try parsePadMapping(node)
                padMappings.append(mapping)

            case "knob":
                let (knobNum, function) = try parseKnobMapping(node)
                knobMappings[knobNum] = function

            default:
                break
            }
        }

        return LauncherConfig(
            contexts: contexts,
            padMappings: padMappings,
            knobMappings: knobMappings
        )
    }

    private static func parseContext(_ node: KDLNode) throws -> Context {
        guard let name = node.arguments.first?.stringValue else {
            throw ConfigError.missingContextName
        }

        var scenes: [String: Scene] = [:]
        var defaultScene: String?

        if let defaultSceneName = node.properties["default"]?.stringValue {
            defaultScene = defaultSceneName
        }

        for child in node.children {
            if child.name == "scene" {
                let scene = try parseScene(child)
                scenes[scene.name] = scene
            }
        }

        return Context(name: name, scenes: scenes, defaultScene: defaultScene)
    }

    private static func parseScene(_ node: KDLNode) throws -> Scene {
        guard let name = node.arguments.first?.stringValue else {
            throw ConfigError.missingSceneName
        }

        var apps: [AppConfig] = []
        var ledColor: (r: UInt8, g: UInt8, b: UInt8)?

        // LEDカラー
        if let r = node.properties["led-r"]?.intValue,
           let g = node.properties["led-g"]?.intValue,
           let b = node.properties["led-b"]?.intValue {
            ledColor = (UInt8(r), UInt8(g), UInt8(b))
        }

        for child in node.children {
            if child.name == "app" {
                let app = try parseApp(child)
                apps.append(app)
            }
        }

        return Scene(name: name, apps: apps, ledColor: ledColor)
    }

    private static func parseApp(_ node: KDLNode) throws -> AppConfig {
        guard let bundleId = node.arguments.first?.stringValue else {
            throw ConfigError.missingBundleId
        }

        let windowTitle = node.properties["window"]?.stringValue

        var position: WindowPosition?

        for child in node.children {
            if child.name == "position" {
                position = try parsePosition(child)
            }
        }

        // プロパティからも位置を取得可能
        if position == nil,
           let x = node.properties["x"]?.intValue,
           let y = node.properties["y"]?.intValue,
           let w = node.properties["width"]?.intValue,
           let h = node.properties["height"]?.intValue {
            position = WindowPosition(x: x, y: y, width: w, height: h)
        }

        return AppConfig(bundleId: bundleId, windowTitle: windowTitle, position: position)
    }

    private static func parsePosition(_ node: KDLNode) throws -> WindowPosition {
        guard let x = node.properties["x"]?.intValue,
              let y = node.properties["y"]?.intValue,
              let width = node.properties["width"]?.intValue,
              let height = node.properties["height"]?.intValue else {
            throw ConfigError.invalidPosition
        }

        return WindowPosition(x: x, y: y, width: width, height: height)
    }

    private static func parsePadMapping(_ node: KDLNode) throws -> PadMapping {
        guard let padNum = node.arguments.first?.intValue else {
            throw ConfigError.missingPadNumber
        }

        guard let contextName = node.properties["context"]?.stringValue else {
            throw ConfigError.missingContextReference
        }

        let sceneName = node.properties["scene"]?.stringValue

        return PadMapping(pad: padNum, contextName: contextName, sceneName: sceneName)
    }

    private static func parseKnobMapping(_ node: KDLNode) throws -> (Int, String) {
        guard let knobNum = node.arguments.first?.intValue else {
            throw ConfigError.missingKnobNumber
        }

        guard let function = node.arguments.dropFirst().first?.stringValue ??
                             node.properties["function"]?.stringValue else {
            throw ConfigError.missingKnobFunction
        }

        return (knobNum, function)
    }
}

// MARK: - Errors

enum ConfigError: Error, LocalizedError {
    case missingContextName
    case missingSceneName
    case missingBundleId
    case invalidPosition
    case missingPadNumber
    case missingContextReference
    case missingKnobNumber
    case missingKnobFunction

    var errorDescription: String? {
        switch self {
        case .missingContextName: return "contextに名前がありません"
        case .missingSceneName: return "sceneに名前がありません"
        case .missingBundleId: return "appにbundleIdがありません"
        case .invalidPosition: return "positionの値が不正です"
        case .missingPadNumber: return "padに番号がありません"
        case .missingContextReference: return "padにcontext参照がありません"
        case .missingKnobNumber: return "knobに番号がありません"
        case .missingKnobFunction: return "knobに機能名がありません"
        }
    }
}
