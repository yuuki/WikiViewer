//
//  BaseExpression.swift
//  IndexerCore
//
//  Parser for the expression language of Obsidian Bases (filters and
//  formulas), following its public documentation:
//
//    literals     "text" 'text' 12 1.5 true false null [a, b] /regex/flags
//    names        status  note.status  file.name  formula.x  value  index
//    postfix      a.b  a.b(args)  f(args)  a[i]
//    operators    ! -  * / %  + -  < <= > >=  == !=  &&  ||   (JS precedence)
//
//  The tree is evaluated by `BaseEvaluator`.
//

import Foundation

indirect enum BaseExpr: Sendable {
    case literal(BaseValue)
    case regex(pattern: String, flags: String)
    case array([BaseExpr])
    case name(String)
    case member(BaseExpr, String)
    case call(callee: BaseExpr, args: [BaseExpr])
    case index(BaseExpr, BaseExpr)
    case unary(String, BaseExpr)
    case binary(String, BaseExpr, BaseExpr)
}

struct BaseParseError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

enum BaseExpressionParser {
    /// Upper bound on nesting, so a hostile file cannot overflow the stack.
    static let maximumDepth = 64

    static func parse(_ source: String) throws -> BaseExpr {
        var parser = Parser(tokens: try tokenize(source))
        let expr = try parser.expression(depth: 0)
        guard parser.peek == .end else { throw BaseParseError(message: "unexpected \(parser.peek) in \"\(source)\"") }
        return expr
    }

    enum Token: Equatable, CustomStringConvertible {
        case number(Double)
        case string(String)
        case regex(String, String)
        case identifier(String)
        case op(String)
        case end

        var description: String {
            switch self {
            case .number(let n): String(n)
            case .string(let s): "\"\(s)\""
            case .regex(let p, _): "/\(p)/"
            case .identifier(let s): s
            case .op(let s): s
            case .end: "end of expression"
            }
        }

        /// True if a `/` after this token is division, not a regex.
        var endsOperand: Bool {
            switch self {
            case .number, .string, .regex, .identifier: true
            case .op(let s): s == ")" || s == "]"
            case .end: false
            }
        }
    }

    static func tokenize(_ source: String) throws -> [Token] {
        let chars = Array(source)
        var tokens: [Token] = []
        var i = 0
        let operators = ["&&", "||", "==", "!=", "<=", ">=", "!", "<", ">", "+", "-", "*", "/", "%", "(", ")", "[", "]", ",", "."]
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
                continue
            }
            if c == "\"" || c == "'" {
                var s = ""
                i += 1
                var closed = false
                while i < chars.count {
                    let d = chars[i]
                    if d == "\\", i + 1 < chars.count {
                        let e = chars[i + 1]
                        switch e {
                        case "n": s.append("\n")
                        case "t": s.append("\t")
                        default: s.append(e)
                        }
                        i += 2
                        continue
                    }
                    if d == c {
                        closed = true
                        i += 1
                        break
                    }
                    s.append(d)
                    i += 1
                }
                guard closed else { throw BaseParseError(message: "unterminated string in \"\(source)\"") }
                tokens.append(.string(s))
                continue
            }
            if c == "/", !(tokens.last?.endsOperand ?? false) {
                // Regex literal: up to the next unescaped "/" outside a class.
                var pattern = ""
                var inClass = false
                i += 1
                var closed = false
                while i < chars.count {
                    let d = chars[i]
                    if d == "\\", i + 1 < chars.count {
                        pattern.append(d)
                        pattern.append(chars[i + 1])
                        i += 2
                        continue
                    }
                    if d == "[" { inClass = true } else if d == "]" { inClass = false }
                    if d == "/", !inClass {
                        closed = true
                        i += 1
                        break
                    }
                    pattern.append(d)
                    i += 1
                }
                guard closed else { throw BaseParseError(message: "unterminated regex in \"\(source)\"") }
                var flags = ""
                while i < chars.count, chars[i].isLetter {
                    flags.append(chars[i])
                    i += 1
                }
                tokens.append(.regex(pattern, flags))
                continue
            }
            if c.isNumber, c.isASCII {
                var s = ""
                while i < chars.count, chars[i].isASCII, chars[i].isNumber || chars[i] == "." {
                    // "1.foo()" would be a method call; accept one dot followed by a digit.
                    if chars[i] == ".", !(i + 1 < chars.count && chars[i + 1].isASCII && chars[i + 1].isNumber) { break }
                    s.append(chars[i])
                    i += 1
                }
                guard let n = Double(s) else { throw BaseParseError(message: "bad number \(s)") }
                tokens.append(.number(n))
                continue
            }
            if c.isLetter || c == "_" || c == "$" {
                var s = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "$" {
                    s.append(chars[i])
                    i += 1
                }
                tokens.append(.identifier(s))
                continue
            }
            if let op = operators.first(where: { op in
                let opChars = Array(op)
                return i + opChars.count <= chars.count && Array(chars[i..<(i + opChars.count)]) == opChars
            }) {
                tokens.append(.op(op))
                i += op.count
                continue
            }
            throw BaseParseError(message: "unexpected character \"\(c)\" in \"\(source)\"")
        }
        tokens.append(.end)
        return tokens
    }

    struct Parser {
        var tokens: [Token]
        var position = 0

        var peek: Token { tokens[position] }

        mutating func next() -> Token {
            let t = tokens[position]
            if position < tokens.count - 1 { position += 1 }
            return t
        }

        mutating func accept(_ op: String) -> Bool {
            if peek == .op(op) {
                position += 1
                return true
            }
            return false
        }

        mutating func expect(_ op: String) throws {
            guard accept(op) else { throw BaseParseError(message: "expected \"\(op)\", found \(peek)") }
        }

        static let levels: [[String]] = [["||"], ["&&"], ["==", "!="], ["<", "<=", ">", ">="], ["+", "-"], ["*", "/", "%"]]

        mutating func expression(depth: Int) throws -> BaseExpr {
            try binary(level: 0, depth: depth)
        }

        mutating func binary(level: Int, depth: Int) throws -> BaseExpr {
            guard depth < BaseExpressionParser.maximumDepth else { throw BaseParseError(message: "expression nested too deeply") }
            guard level < Self.levels.count else { return try unary(depth: depth) }
            var left = try binary(level: level + 1, depth: depth + 1)
            while case .op(let op) = peek, Self.levels[level].contains(op) {
                _ = next()
                let right = try binary(level: level + 1, depth: depth + 1)
                left = .binary(op, left, right)
            }
            return left
        }

        mutating func unary(depth: Int) throws -> BaseExpr {
            guard depth < BaseExpressionParser.maximumDepth else { throw BaseParseError(message: "expression nested too deeply") }
            if accept("!") { return .unary("!", try unary(depth: depth + 1)) }
            if accept("-") { return .unary("-", try unary(depth: depth + 1)) }
            return try postfix(depth: depth + 1)
        }

        mutating func postfix(depth: Int) throws -> BaseExpr {
            var expr = try primary(depth: depth)
            while true {
                if accept(".") {
                    guard case .identifier(let name) = next() else { throw BaseParseError(message: "expected a name after \".\"") }
                    expr = .member(expr, name)
                } else if accept("(") {
                    expr = .call(callee: expr, args: try arguments(closing: ")", depth: depth))
                } else if accept("[") {
                    let index = try expression(depth: depth + 1)
                    try expect("]")
                    expr = .index(expr, index)
                } else {
                    return expr
                }
            }
        }

        mutating func arguments(closing: String, depth: Int) throws -> [BaseExpr] {
            var args: [BaseExpr] = []
            if accept(closing) { return args }
            repeat {
                args.append(try expression(depth: depth + 1))
            } while accept(",")
            try expect(closing)
            return args
        }

        mutating func primary(depth: Int) throws -> BaseExpr {
            switch next() {
            case .number(let n): return .literal(.number(n))
            case .string(let s): return .literal(.string(s))
            case .regex(let p, let f): return .regex(pattern: p, flags: f)
            case .identifier(let name):
                switch name {
                case "true": return .literal(.bool(true))
                case "false": return .literal(.bool(false))
                case "null": return .literal(.null)
                default: return .name(name)
                }
            case .op("("):
                let expr = try expression(depth: depth + 1)
                try expect(")")
                return expr
            case .op("["):
                return .array(try arguments(closing: "]", depth: depth))
            case let token:
                throw BaseParseError(message: "unexpected \(token)")
            }
        }
    }
}
