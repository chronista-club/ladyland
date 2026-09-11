//! KDL の最小読み書き（mako 要望 2026-08-02「kdl scheme の載った
//! lldata-snapshot-{date}.kdl の export と、そこからの部分ロード」）。
//!
//! **Swift に成熟した KDL パーサが無い**（2026-08-02 調査）。全仕様を実装する
//! 必要は無く、**自分が書き出した部分集合だけを読めればよい** ので、
//! 書き手と読み手を対にしてここに閉じ込める。
//!
//! 受け付ける文法（KDL 2.0 の部分集合）:
//!   node-name arg1 arg2 key=value { child ... }
//!   識別子     = 英数 / `-` / `_` / `.`、または引用文字列
//!   値         = 引用文字列 / 整数 / 小数 / #true / #false / #null
//!   コメント   = // 行末まで
//! **受け付けないもの**（書き出さないので不要）: 生文字列 `#"..."#`、
//! 型注釈 `(u8)`、`/-` スラッシュダッシュ、複数行コメント、行継続 `\`。
//! 知らない構文に出会ったら**黙って無視せずエラーにする** — 半端に読んだ
//! スナップショットを適用して席を壊さないため。
//!
//! バイト列（UTF8）で走査する: 音色 blob は base64 で数 MB になるため、
//! [Character] 化すると桁違いに重い。ASCII を直接見て、文字列だけ範囲から起こす。

import Foundation

enum KDLValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
}

struct KDLNode: Equatable {
    var name: String
    var args: [KDLValue] = []
    var props: [String: KDLValue] = [:]
    var children: [KDLNode] = []

    /// 名前で子を絞る（部分ロードの選択に使う）
    func children(named name: String) -> [KDLNode] {
        children.filter { $0.name == name }
    }

    func child(named name: String) -> KDLNode? {
        children.first { $0.name == name }
    }

    subscript(prop: String) -> KDLValue? { props[prop] }
}

enum KDLError: Error, CustomStringConvertible {
    case unexpected(String, line: Int)

    var description: String {
        switch self {
        case .unexpected(let what, let line): return "KDL \(line) 行目: \(what)"
        }
    }
}

enum KDLMini {

    // MARK: - 書き出し

    static func emit(_ nodes: [KDLNode]) -> String {
        var out = ""
        for node in nodes {
            emit(node, depth: 0, into: &out)
        }
        return out
    }

    private static func emit(_ node: KDLNode, depth: Int, into out: inout String) {
        let indent = String(repeating: "    ", count: depth)
        out += indent + identifier(node.name)
        for arg in node.args {
            out += " " + literal(arg)
        }
        // プロパティは並びを固定する（差分が安定 = git で読める）
        for key in node.props.keys.sorted() {
            out += " " + identifier(key) + "=" + literal(node.props[key]!)
        }
        if node.children.isEmpty {
            out += "\n"
            return
        }
        out += " {\n"
        for child in node.children {
            emit(child, depth: depth + 1, into: &out)
        }
        out += indent + "}\n"
    }

    /// 裸で書ける識別子はそのまま、それ以外は引用する
    static func identifier(_ name: String) -> String {
        let bare = !name.isEmpty && name.utf8.allSatisfy { isBareIdentifier($0) }
            && !(name.utf8.first.map { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") } ?? true)
        return bare ? name : quote(name)
    }

    static func literal(_ value: KDLValue) -> String {
        switch value {
        case .string(let v): return quote(v)
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return v ? "#true" : "#false"
        case .null: return "#null"
        }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(character)
            }
        }
        return out + "\""
    }

    private static func isBareIdentifier(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
    }

    // MARK: - 読み込み

    static func parse(_ text: String) throws -> [KDLNode] {
        var parser = Parser(bytes: Array(text.utf8))
        return try parser.parseNodes(topLevel: true)
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        var line = 1

        mutating func parseNodes(topLevel: Bool) throws -> [KDLNode] {
            var nodes: [KDLNode] = []
            while true {
                skipTrivia()
                if i >= bytes.count {
                    if topLevel { return nodes }
                    throw KDLError.unexpected("} が閉じられていない", line: line)
                }
                if bytes[i] == UInt8(ascii: "}") {
                    if topLevel {
                        throw KDLError.unexpected("対応しない }", line: line)
                    }
                    i += 1
                    return nodes
                }
                nodes.append(try parseNode())
            }
        }

        mutating func parseNode() throws -> KDLNode {
            var node = KDLNode(name: try parseIdentifier())
            while true {
                skipInlineTrivia()
                guard i < bytes.count else { return node }
                switch bytes[i] {
                case UInt8(ascii: "\n"):
                    i += 1
                    line += 1
                    return node
                case UInt8(ascii: ";"):
                    i += 1
                    return node
                case UInt8(ascii: "{"):
                    i += 1
                    node.children = try parseNodes(topLevel: false)
                    return node
                case UInt8(ascii: "}"):
                    return node
                default:
                    // 引数か プロパティ（key=value）か — `=` の有無で決まる
                    let start = i
                    let startLine = line
                    if isIdentifierStart(bytes[i]) || bytes[i] == UInt8(ascii: "\"") {
                        let name = try parseIdentifier()
                        skipInlineTrivia()
                        if i < bytes.count, bytes[i] == UInt8(ascii: "=") {
                            i += 1
                            skipInlineTrivia()
                            node.props[name] = try parseValue()
                            continue
                        }
                        // プロパティでなければ引数として読み直す
                        i = start
                        line = startLine
                    }
                    node.args.append(try parseValue())
                }
            }
        }

        mutating func parseIdentifier() throws -> String {
            guard i < bytes.count else {
                throw KDLError.unexpected("識別子が来るはずが終端", line: line)
            }
            if bytes[i] == UInt8(ascii: "\"") {
                return try parseQuoted()
            }
            let start = i
            while i < bytes.count, isBareIdentifier(bytes[i]) {
                i += 1
            }
            guard i > start else {
                throw KDLError.unexpected("識別子として読めない文字", line: line)
            }
            return string(from: start, to: i)
        }

        mutating func parseValue() throws -> KDLValue {
            guard i < bytes.count else {
                throw KDLError.unexpected("値が来るはずが終端", line: line)
            }
            if bytes[i] == UInt8(ascii: "\"") {
                return .string(try parseQuoted())
            }
            if bytes[i] == UInt8(ascii: "#") {
                let start = i
                i += 1
                while i < bytes.count, isBareIdentifier(bytes[i]) { i += 1 }
                switch string(from: start, to: i) {
                case "#true": return .bool(true)
                case "#false": return .bool(false)
                case "#null": return .null
                case let other:
                    throw KDLError.unexpected("未対応のキーワード \(other)", line: line)
                }
            }
            // 数値
            let start = i
            if bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { i += 1 }
            var isDouble = false
            while i < bytes.count {
                let byte = bytes[i]
                if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
                    i += 1
                } else if byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e")
                    || byte == UInt8(ascii: "E") || byte == UInt8(ascii: "_")
                {
                    isDouble = isDouble || byte != UInt8(ascii: "_")
                    i += 1
                } else if (byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+")),
                    i > start, bytes[i - 1] == UInt8(ascii: "e") || bytes[i - 1] == UInt8(ascii: "E")
                {
                    i += 1
                } else {
                    break
                }
            }
            guard i > start else {
                throw KDLError.unexpected("値として読めない文字", line: line)
            }
            let text = string(from: start, to: i).replacingOccurrences(of: "_", with: "")
            if !isDouble, let value = Int(text) { return .int(value) }
            guard let value = Double(text) else {
                throw KDLError.unexpected("数値として読めない \(text)", line: line)
            }
            return .double(value)
        }

        mutating func parseQuoted() throws -> String {
            i += 1  // 開き "
            var out: [UInt8] = []
            while i < bytes.count {
                let byte = bytes[i]
                if byte == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if byte == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { break }
                    switch bytes[i] {
                    case UInt8(ascii: "n"): out.append(UInt8(ascii: "\n"))
                    case UInt8(ascii: "r"): out.append(UInt8(ascii: "\r"))
                    case UInt8(ascii: "t"): out.append(UInt8(ascii: "\t"))
                    case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                    case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                    case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                    case let other:
                        throw KDLError.unexpected(
                            "未対応のエスケープ \\\(Character(UnicodeScalar(other)))", line: line)
                    }
                    i += 1
                    continue
                }
                if byte == UInt8(ascii: "\n") { line += 1 }
                out.append(byte)
                i += 1
            }
            throw KDLError.unexpected("閉じられていない文字列", line: line)
        }

        /// 改行も飛ばす（ノードの区切り探し）
        mutating func skipTrivia() {
            while i < bytes.count {
                let byte = bytes[i]
                if byte == UInt8(ascii: "\n") {
                    line += 1
                    i += 1
                } else if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
                    || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: ";")
                {
                    i += 1
                } else if isLineComment() {
                    skipLineComment()
                } else {
                    return
                }
            }
        }

        /// 改行は飛ばさない（ノードの終わりを示すため）
        mutating func skipInlineTrivia() {
            while i < bytes.count {
                let byte = bytes[i]
                if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
                    || byte == UInt8(ascii: "\r")
                {
                    i += 1
                } else if isLineComment() {
                    skipLineComment()
                } else {
                    return
                }
            }
        }

        func isLineComment() -> Bool {
            i + 1 < bytes.count && bytes[i] == UInt8(ascii: "/") && bytes[i + 1] == UInt8(ascii: "/")
        }

        mutating func skipLineComment() {
            while i < bytes.count, bytes[i] != UInt8(ascii: "\n") { i += 1 }
        }

        func string(from start: Int, to end: Int) -> String {
            String(decoding: bytes[start..<end], as: UTF8.self)
        }

        func isIdentifierStart(_ byte: UInt8) -> Bool {
            (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || byte == UInt8(ascii: "_")
        }

        func isBareIdentifier(_ byte: UInt8) -> Bool {
            KDLMini.isBareIdentifier(byte)
        }
    }
}
