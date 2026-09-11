import Foundation

// MARK: - KDL AST

/// KDLノード
struct KDLNode {
    let name: String
    var arguments: [KDLValue]
    var properties: [String: KDLValue]
    var children: [KDLNode]
}

/// KDL値
enum KDLValue: Equatable {
    case string(String)
    case int(Int)
    case float(Double)
    case bool(Bool)
    case null

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    var floatValue: Double? {
        if case .float(let f) = self { return f }
        if case .int(let i) = self { return Double(i) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

// MARK: - KDL Parser

class KDLParser {
    private var input: String
    private var index: String.Index

    init(_ input: String) {
        self.input = input
        self.index = input.startIndex
    }

    // MARK: - Public API

    static func parse(_ input: String) throws -> [KDLNode] {
        let parser = KDLParser(input)
        return try parser.parseDocument()
    }

    // MARK: - Parsing

    private func parseDocument() throws -> [KDLNode] {
        var nodes: [KDLNode] = []

        while !isAtEnd {
            skipWhitespaceAndComments()
            if isAtEnd { break }

            if let node = try parseNode() {
                nodes.append(node)
            }
        }

        return nodes
    }

    private func parseNode() throws -> KDLNode? {
        skipWhitespaceAndComments()

        guard !isAtEnd else { return nil }

        // ノード名をパース
        guard let name = parseIdentifier() else {
            // '}' や改行のみの場合はnil
            if peek() == "}" || peek() == "\n" {
                return nil
            }
            throw KDLError.unexpectedCharacter(peek())
        }

        var arguments: [KDLValue] = []
        var properties: [String: KDLValue] = [:]
        var children: [KDLNode] = []

        // 引数とプロパティをパース
        while !isAtEnd {
            skipInlineWhitespace()

            let c = peek()

            // ノード終端
            if c == "\n" || c == ";" {
                advance()
                break
            }

            // 子ノードブロック
            if c == "{" {
                advance()
                children = try parseChildren()
                skipWhitespaceAndComments()
                break
            }

            // ブロック終了
            if c == "}" {
                break
            }

            // コメント
            if c == "/" {
                if peekNext() == "/" {
                    skipLineComment()
                    break
                } else if peekNext() == "*" {
                    skipBlockComment()
                    continue
                }
            }

            // プロパティまたは引数
            if let value = try parsePropertyOrArgument(&properties) {
                arguments.append(value)
            }
        }

        return KDLNode(name: name, arguments: arguments, properties: properties, children: children)
    }

    private func parseChildren() throws -> [KDLNode] {
        var children: [KDLNode] = []

        while !isAtEnd {
            skipWhitespaceAndComments()

            if peek() == "}" {
                advance()
                break
            }

            if let node = try parseNode() {
                children.append(node)
            }
        }

        return children
    }

    private func parsePropertyOrArgument(_ properties: inout [String: KDLValue]) throws -> KDLValue? {
        // 識別子で始まる場合、プロパティの可能性
        let startIndex = index

        if let ident = parseIdentifier() {
            skipInlineWhitespace()

            if peek() == "=" {
                advance()
                skipInlineWhitespace()
                let value = try parseValue()
                properties[ident] = value
                return nil
            } else {
                // 識別子自体が値（キーワードまたは文字列）
                index = startIndex
            }
        }

        // 値をパース
        return try parseValue()
    }

    private func parseValue() throws -> KDLValue {
        skipInlineWhitespace()

        let c = peek()

        // 文字列
        if c == "\"" {
            return .string(try parseString())
        }

        // 数値または識別子
        if c == "-" || c == "+" || c.isNumber {
            return try parseNumber()
        }

        // キーワード (true, false, null) または裸の識別子
        if let ident = parseIdentifier() {
            switch ident {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: return .string(ident)
            }
        }

        throw KDLError.unexpectedCharacter(c)
    }

    private func parseString() throws -> String {
        guard peek() == "\"" else {
            throw KDLError.expectedString
        }
        advance()

        var result = ""

        while !isAtEnd && peek() != "\"" {
            let c = peek()

            if c == "\\" {
                advance()
                if isAtEnd {
                    throw KDLError.unterminatedString
                }
                let escaped = peek()
                advance()

                switch escaped {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                default: result.append(escaped)
                }
            } else {
                result.append(c)
                advance()
            }
        }

        guard peek() == "\"" else {
            throw KDLError.unterminatedString
        }
        advance()

        return result
    }

    private func parseNumber() throws -> KDLValue {
        var numStr = ""

        // 符号
        if peek() == "-" || peek() == "+" {
            numStr.append(peek())
            advance()
        }

        // 整数部
        while !isAtEnd && (peek().isNumber || peek() == "_") {
            if peek() != "_" {
                numStr.append(peek())
            }
            advance()
        }

        // 小数部
        var isFloat = false
        if peek() == "." {
            isFloat = true
            numStr.append(peek())
            advance()

            while !isAtEnd && (peek().isNumber || peek() == "_") {
                if peek() != "_" {
                    numStr.append(peek())
                }
                advance()
            }
        }

        // 指数部
        if peek() == "e" || peek() == "E" {
            isFloat = true
            numStr.append(peek())
            advance()

            if peek() == "-" || peek() == "+" {
                numStr.append(peek())
                advance()
            }

            while !isAtEnd && peek().isNumber {
                numStr.append(peek())
                advance()
            }
        }

        if isFloat {
            guard let value = Double(numStr) else {
                throw KDLError.invalidNumber(numStr)
            }
            return .float(value)
        } else {
            guard let value = Int(numStr) else {
                throw KDLError.invalidNumber(numStr)
            }
            return .int(value)
        }
    }

    private func parseIdentifier() -> String? {
        var result = ""

        // 最初の文字
        guard !isAtEnd else { return nil }
        let first = peek()

        guard first.isLetter || first == "_" || first == "-" else {
            return nil
        }

        result.append(first)
        advance()

        // 残り
        while !isAtEnd {
            let c = peek()
            if c.isLetter || c.isNumber || c == "_" || c == "-" {
                result.append(c)
                advance()
            } else {
                break
            }
        }

        return result.isEmpty ? nil : result
    }

    // MARK: - Whitespace & Comments

    private func skipWhitespaceAndComments() {
        while !isAtEnd {
            let c = peek()

            if c.isWhitespace {
                advance()
            } else if c == "/" {
                if peekNext() == "/" {
                    skipLineComment()
                } else if peekNext() == "*" {
                    skipBlockComment()
                } else {
                    break
                }
            } else {
                break
            }
        }
    }

    private func skipInlineWhitespace() {
        while !isAtEnd && (peek() == " " || peek() == "\t") {
            advance()
        }
    }

    private func skipLineComment() {
        // "//" をスキップ
        advance()
        advance()

        while !isAtEnd && peek() != "\n" {
            advance()
        }
    }

    private func skipBlockComment() {
        // "/*" をスキップ
        advance()
        advance()

        var depth = 1

        while !isAtEnd && depth > 0 {
            if peek() == "/" && peekNext() == "*" {
                depth += 1
                advance()
                advance()
            } else if peek() == "*" && peekNext() == "/" {
                depth -= 1
                advance()
                advance()
            } else {
                advance()
            }
        }
    }

    // MARK: - Utilities

    private var isAtEnd: Bool {
        index >= input.endIndex
    }

    private func peek() -> Character {
        guard !isAtEnd else { return "\0" }
        return input[index]
    }

    private func peekNext() -> Character {
        let next = input.index(after: index)
        guard next < input.endIndex else { return "\0" }
        return input[next]
    }

    @discardableResult
    private func advance() -> Character {
        let c = peek()
        if !isAtEnd {
            index = input.index(after: index)
        }
        return c
    }
}

// MARK: - Errors

enum KDLError: Error, LocalizedError {
    case unexpectedCharacter(Character)
    case expectedString
    case unterminatedString
    case invalidNumber(String)
    case unexpectedEndOfInput

    var errorDescription: String? {
        switch self {
        case .unexpectedCharacter(let c):
            return "予期しない文字: '\(c)'"
        case .expectedString:
            return "文字列が必要です"
        case .unterminatedString:
            return "文字列が閉じられていません"
        case .invalidNumber(let s):
            return "無効な数値: '\(s)'"
        case .unexpectedEndOfInput:
            return "予期しない入力の終了"
        }
    }
}
