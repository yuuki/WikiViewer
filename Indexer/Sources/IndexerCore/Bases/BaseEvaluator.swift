//
//  BaseEvaluator.swift
//  IndexerCore
//
//  Evaluates Bases expressions for one note at a time. Semantics follow the
//  Bases documentation; where it is silent, the evaluator behaves like
//  JavaScript (Obsidian's own implementation language) and turns type errors
//  into `null` rather than failing the whole base. Functions it does not
//  implement evaluate to `null` and are reported in `unsupported`, which the
//  viewer shows next to the base.
//

import Foundation
import WikiShared

enum BaseValue: @unchecked Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case date(Date, hasTime: Bool)
    case list([BaseValue])
    case object([(String, BaseValue)])
    /// A link: `path` is the resolved vault path when known.
    case link(target: String, display: String?, path: String?)
    /// `global`: the literal had the g flag (`replace` replaces every match).
    case regex(NSRegularExpression, global: Bool)
    /// The current note's file (`file`).
    case file
    /// `note` or `formula`: a namespace resolved by member access.
    case scope(String)

    var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let b): b
        case .number(let n): n != 0 && !n.isNaN
        case .string(let s): !s.isEmpty
        case .list(let items): !items.isEmpty
        case .object(let pairs): !pairs.isEmpty
        default: true
        }
    }

    var isEmptyValue: Bool {
        switch self {
        case .null: true
        case .string(let s): s.isEmpty
        case .list(let items): items.isEmpty
        case .object(let pairs): pairs.isEmpty
        default: false
        }
    }

    /// Text shown for the value, as Obsidian would print it.
    var displayString: String {
        switch self {
        case .null, .file, .scope: ""
        case .bool(let b): b ? "true" : "false"
        case .number(let n): BaseCell.format(n)
        case .string(let s): s
        case .date(let d, let hasTime): BaseDates.display(d, hasTime: hasTime)
        case .list(let items): items.map(\.displayString).joined(separator: ", ")
        case .object(let pairs): pairs.map { "\($0.0): \($0.1.displayString)" }.joined(separator: ", ")
        case .link(let target, let display, _): display ?? BaseValue.linkName(target)
        case .regex(let r, _): "/\(r.pattern)/"
        }
    }

    /// The name a link shows by default: the file name without ".md"
    /// (`[[v1.0 notes]]` is "v1.0 notes", not "v1").
    static func linkName(_ target: String) -> String {
        VaultPath.fileName(of: LinkResolver.stripMarkdownExtension(target))
    }

    /// A frontmatter value decoded from the indexer's JSON.
    static func fromJSON(_ any: Any, depth: Int = 0) -> BaseValue {
        guard depth < 16 else { return .null }
        switch any {
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let a as [Any]: return .list(a.map { fromJSON($0, depth: depth + 1) })
        case let d as [String: Any]: return .object(d.keys.sorted().map { ($0, fromJSON(d[$0]!, depth: depth + 1)) })
        default: return .null
        }
    }
}

enum BaseDates {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    static func display(_ date: Date, hasTime: Bool) -> String {
        format(date, pattern: hasTime ? "YYYY-MM-DD HH:mm" : "YYYY-MM-DD")
    }

    /// Parses the date forms Obsidian writes in properties.
    static func parse(_ text: String) -> BaseValue {
        let s = text.trimmingCharacters(in: .whitespaces)
        let formats: [(String, Bool)] = [
            ("yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", true), ("yyyy-MM-dd'T'HH:mm:ssXXXXX", true),
            ("yyyy-MM-dd'T'HH:mm:ss.SSS", true), ("yyyy-MM-dd'T'HH:mm:ss", true), ("yyyy-MM-dd'T'HH:mm", true),
            ("yyyy-MM-dd HH:mm:ss", true), ("yyyy-MM-dd HH:mm", true), ("yyyy-MM-dd", false),
        ]
        for (format, hasTime) in formats where format.replacingOccurrences(of: "'", with: "").count >= s.count - 6 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: s) { return .date(date, hasTime: hasTime) }
        }
        return .null
    }

    /// Moment.js-style tokens: YYYY YY MM M DD D HH H mm ss.
    static func format(_ date: Date, pattern: String) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ n: Int?, _ width: Int) -> String {
            let s = String(n ?? 0)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        let tokens: [(String, String)] = [
            ("YYYY", pad(c.year, 4)), ("YY", pad((c.year ?? 0) % 100, 2)), ("MM", pad(c.month, 2)), ("M", String(c.month ?? 0)),
            ("DD", pad(c.day, 2)), ("D", String(c.day ?? 0)), ("HH", pad(c.hour, 2)), ("H", String(c.hour ?? 0)),
            ("mm", pad(c.minute, 2)), ("ss", pad(c.second, 2)),
        ]
        var out = ""
        var rest = Substring(pattern)
        outer: while !rest.isEmpty {
            for (token, value) in tokens where rest.hasPrefix(token) {
                out += value
                rest = rest.dropFirst(token.count)
                continue outer
            }
            out.append(rest.removeFirst())
        }
        return out
    }
}

/// What the evaluator knows about the note being evaluated. Tags, links and
/// backlinks are loaded only if an expression asks for them.
final class BaseNote {
    let id: Int64
    let path: String
    let mtimeNs: Int64
    let size: Int64
    let properties: [(String, BaseValue)]
    private let loadTags: () -> [String]
    private let loadLinks: () -> [BaseValue]
    private let loadBacklinks: () -> [BaseValue]
    private(set) lazy var tags: [String] = loadTags()
    private(set) lazy var links: [BaseValue] = loadLinks()
    private(set) lazy var backlinks: [BaseValue] = loadBacklinks()

    init(id: Int64, path: String, mtimeNs: Int64, size: Int64, properties: [(String, BaseValue)],
         tags: @escaping () -> [String], links: @escaping () -> [BaseValue], backlinks: @escaping () -> [BaseValue]) {
        self.id = id
        self.path = path
        self.mtimeNs = mtimeNs
        self.size = size
        self.properties = properties
        loadTags = tags
        loadLinks = links
        loadBacklinks = backlinks
    }

    /// Exact key first, then case-insensitive (Obsidian property names are).
    func property(_ name: String) -> BaseValue {
        if let hit = properties.first(where: { $0.0 == name }) { return hit.1 }
        let lower = name.lowercased()
        return properties.first(where: { $0.0.lowercased() == lower })?.1 ?? .null
    }
}

final class BaseEvaluator {
    let formulas: [String: BaseExpr]
    /// Names of functions and methods that evaluated to null because they
    /// are not implemented.
    private(set) var unsupported = Set<String>()
    private var note: BaseNote!
    private var formulaCache: [String: BaseValue] = [:]
    private var evaluating = Set<String>()
    private var regexCache: [String: NSRegularExpression] = [:]
    /// Upper bound on list items produced by one operation.
    static let maximumListItems = 10_000

    init(formulas: [String: BaseExpr]) {
        self.formulas = formulas
    }

    func begin(_ note: BaseNote) {
        self.note = note
        formulaCache.removeAll(keepingCapacity: true)
    }

    func formula(_ name: String) -> BaseValue {
        if let cached = formulaCache[name] { return cached }
        guard let expr = formulas[name], evaluating.insert(name).inserted else { return .null }
        defer { evaluating.remove(name) }
        let value = evaluate(expr, locals: [:])
        formulaCache[name] = value
        return value
    }

    /// Value of a column or sort property id: `status`, `note.status`,
    /// `file.mtime`, `formula.x`. Property names may contain characters
    /// expressions cannot (`date-published`), so ids are not parsed.
    func property(id: String) -> BaseValue {
        if id.hasPrefix("formula.") { return formula(String(id.dropFirst(8))) }
        if id.hasPrefix("file.") { return fileMember(String(id.dropFirst(5))) }
        if id.hasPrefix("note.") { return note.property(String(id.dropFirst(5))) }
        return note.property(id)
    }

    func evaluate(_ expr: BaseExpr, locals: [String: BaseValue]) -> BaseValue {
        switch expr {
        case .literal(let v):
            return v
        case .regex(let pattern, let flags):
            let key = flags + "/" + pattern
            let global = flags.contains("g")
            if let cached = regexCache[key] { return .regex(cached, global: global) }
            var options: NSRegularExpression.Options = []
            if flags.contains("i") { options.insert(.caseInsensitive) }
            if flags.contains("m") { options.insert(.anchorsMatchLines) }
            if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return .null }
            regexCache[key] = regex
            return .regex(regex, global: global)
        case .array(let items):
            return .list(items.map { evaluate($0, locals: locals) })
        case .name(let name):
            if let local = locals[name] { return local }
            switch name {
            case "file": return .file
            case "note", "formula": return .scope(name)
            case "this": return .null
            default: return note.property(name)
            }
        case .member(let target, let name):
            return member(evaluate(target, locals: locals), name)
        case .index(let target, let index):
            let t = evaluate(target, locals: locals)
            let i = evaluate(index, locals: locals)
            switch (t, i) {
            case (.list(let items), .number(let n)):
                let k = Int(n)
                let idx = k < 0 ? items.count + k : k
                return items.indices.contains(idx) ? items[idx] : .null
            case (.string(let s), .number(let n)):
                let chars = Array(s)
                let k = Int(n)
                return chars.indices.contains(k) ? .string(String(chars[k])) : .null
            case (_, .string(let key)):
                return member(t, key)
            default:
                return .null
            }
        case .call(let callee, let args):
            switch callee {
            case .name(let name) where locals[name] == nil:
                return function(name, args, locals: locals)
            case .member(let target, let name):
                return method(evaluate(target, locals: locals), name, args, locals: locals)
            default:
                return .null
            }
        case .unary(let op, let operand):
            let v = evaluate(operand, locals: locals)
            if op == "!" { return .bool(!v.isTruthy) }
            if case .number(let n) = v { return .number(-n) }
            return .null
        case .binary(let op, let lhs, let rhs):
            if op == "&&" {
                let l = evaluate(lhs, locals: locals)
                return l.isTruthy ? evaluate(rhs, locals: locals) : l
            }
            if op == "||" {
                let l = evaluate(lhs, locals: locals)
                return l.isTruthy ? l : evaluate(rhs, locals: locals)
            }
            return binary(op, evaluate(lhs, locals: locals), evaluate(rhs, locals: locals))
        }
    }

    // MARK: Members

    private func member(_ target: BaseValue, _ name: String) -> BaseValue {
        switch target {
        case .file: return fileMember(name)
        case .scope("note"): return note.property(name)
        case .scope("formula"): return formula(name)
        case .string(let s) where name == "length": return .number(Double(s.count))
        case .list(let items) where name == "length": return .number(Double(items.count))
        case .object(let pairs): return pairs.first(where: { $0.0 == name })?.1 ?? .null
        case .date(let d, _):
            let c = BaseDates.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: d)
            switch name {
            case "year": return .number(Double(c.year ?? 0))
            case "month": return .number(Double(c.month ?? 0))
            case "day": return .number(Double(c.day ?? 0))
            case "hour": return .number(Double(c.hour ?? 0))
            case "minute": return .number(Double(c.minute ?? 0))
            case "second": return .number(Double(c.second ?? 0))
            case "millisecond": return .number(Double((c.nanosecond ?? 0) / 1_000_000))
            default: return .null
            }
        default: return .null
        }
    }

    func fileMember(_ name: String) -> BaseValue {
        switch name {
        case "name": return .string(VaultPath.fileName(of: note.path))
        case "basename": return .string(VaultPath.basename(of: note.path))
        case "path": return .string(note.path)
        case "folder": return .string(VaultPath.folder(of: note.path))
        case "ext": return .string(VaultPath.fileExtension(of: note.path))
        case "size": return .number(Double(note.size))
        case "mtime": return .date(Date(timeIntervalSince1970: Double(note.mtimeNs) / 1e9), hasTime: true)
        case "tags": return .list(note.tags.map { .string("#" + $0) })
        case "links": return .list(note.links)
        case "backlinks": return .list(note.backlinks)
        case "properties": return .object(note.properties)
        case "file": return .file
        default:
            // ctime, embeds, …: not recorded by the indexer.
            return .null
        }
    }

    // MARK: Functions

    private func function(_ name: String, _ args: [BaseExpr], locals: [String: BaseValue]) -> BaseValue {
        func arg(_ i: Int) -> BaseValue { i < args.count ? evaluate(args[i], locals: locals) : .null }
        switch name {
        case "if":
            return arg(0).isTruthy ? arg(1) : arg(2)
        case "date":
            switch arg(0) {
            case .date(let d, let t): return .date(d, hasTime: t)
            case .string(let s): return BaseDates.parse(s)
            case .number(let ms): return .date(Date(timeIntervalSince1970: ms / 1000), hasTime: true)
            default: return .null
            }
        case "now":
            return .date(Date(), hasTime: true)
        case "today":
            return .date(BaseDates.calendar.startOfDay(for: Date()), hasTime: false)
        case "number":
            switch arg(0) {
            case .number(let n): return .number(n)
            case .bool(let b): return .number(b ? 1 : 0)
            case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces)).map { .number($0) } ?? .null
            case .date(let d, _): return .number(d.timeIntervalSince1970 * 1000)
            default: return .null
            }
        case "list":
            let v = arg(0)
            if case .list = v { return v }
            return v.isEmptyValue ? .list([]) : .list([v])
        case "link":
            let target = arg(0).displayString
            let display = args.count > 1 ? arg(1).displayString : nil
            return .link(target: target, display: display, path: nil)
        case "min", "max":
            let numbers = args.compactMap { a -> Double? in if case .number(let n) = evaluate(a, locals: locals) { n } else { nil } }
            guard !numbers.isEmpty else { return .null }
            return .number(name == "min" ? numbers.min()! : numbers.max()!)
        default:
            unsupported.insert(name + "()")
            return .null
        }
    }

    // MARK: Methods

    private func method(_ target: BaseValue, _ name: String, _ args: [BaseExpr], locals: [String: BaseValue]) -> BaseValue {
        func arg(_ i: Int) -> BaseValue { i < args.count ? evaluate(args[i], locals: locals) : .null }
        // Methods of every type.
        switch name {
        case "isEmpty": return .bool(target.isEmptyValue)
        case "isTruthy": return .bool(target.isTruthy)
        case "toString": return .string(target.displayString)
        case "isType":
            let type: String = switch target {
            case .null: "null"
            case .bool: "boolean"
            case .number: "number"
            case .string: "string"
            case .date: "date"
            case .list: "list"
            case .object: "object"
            case .link: "link"
            case .file: "file"
            default: "unknown"
            }
            return .bool(arg(0).displayString == type)
        default: break
        }
        switch target {
        case .file: return fileMethod(name, args, locals: locals)
        case .string(let s): return stringMethod(s, name, args, locals: locals)
        case .list(let items): return listMethod(items, name, args, locals: locals)
        case .number(let n): return numberMethod(n, name, args, locals: locals)
        case .date(let d, let hasTime):
            switch name {
            case "format": return .string(BaseDates.format(d, pattern: arg(0).displayString))
            case "date": return .date(BaseDates.calendar.startOfDay(for: d), hasTime: false)
            case "time": return .string(BaseDates.format(d, pattern: "HH:mm:ss"))
            default: _ = hasTime
            }
        case .regex(let r, _):
            if name == "matches" {
                let s = arg(0).displayString
                return .bool(r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil)
            }
        case .link(let target, _, let path):
            if name == "linksTo" {
                return .bool(linkMatches(.link(target: target, display: nil, path: path), arg(0)))
            }
        case .object(let pairs):
            switch name {
            case "keys": return .list(pairs.map { .string($0.0) })
            case "values": return .list(pairs.map(\.1))
            default: break
            }
        default: break
        }
        unsupported.insert("." + name + "()")
        return .null
    }

    private func fileMethod(_ name: String, _ args: [BaseExpr], locals: [String: BaseValue]) -> BaseValue {
        let values = args.map { evaluate($0, locals: locals) }
        switch name {
        case "inFolder":
            let folder = values.first?.displayString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            let own = VaultPath.folder(of: note.path)
            return .bool(folder.isEmpty || own == folder || own.hasPrefix(folder + "/"))
        case "hasTag":
            let keys = note.tags.map(VaultPath.matchKey)
            return .bool(values.contains { value in
                var tag = value.displayString
                while tag.hasPrefix("#") { tag.removeFirst() }
                let key = VaultPath.matchKey(tag)
                return keys.contains { $0 == key || $0.hasPrefix(key + "/") }
            })
        case "hasProperty":
            let name = values.first?.displayString ?? ""
            return .bool(note.properties.contains { $0.0 == name })
        case "hasLink":
            guard let wanted = values.first else { return .bool(false) }
            return .bool(note.links.contains { linkMatches($0, wanted) })
        case "asLink":
            return .link(target: note.path, display: values.first.map(\.displayString), path: note.path)
        default:
            unsupported.insert("file." + name + "()")
            return .null
        }
    }

    /// True if `link` points at `wanted` (a link, a file or a name/path).
    private func linkMatches(_ link: BaseValue, _ wanted: BaseValue) -> Bool {
        guard case .link(let target, _, let path) = link else { return false }
        let wantedName: String
        switch wanted {
        case .link(let t, _, let p):
            if let p, let path { return p == path }
            wantedName = t
        case .file:
            return path == note.path
        default:
            wantedName = wanted.displayString
        }
        let strip = { (s: String) in VaultPath.matchKey(LinkResolver.stripMarkdownExtension(s)) }
        let key = strip(wantedName)
        return strip(target) == key || path.map(strip) == key || path.map { strip(VaultPath.basename(of: $0)) } == key
    }

    private func stringMethod(_ s: String, _ name: String, _ args: [BaseExpr], locals: [String: BaseValue]) -> BaseValue {
        func arg(_ i: Int) -> BaseValue { i < args.count ? evaluate(args[i], locals: locals) : .null }
        switch name {
        case "contains": return .bool(s.contains(arg(0).displayString))
        case "containsAll": return .bool(args.indices.allSatisfy { s.contains(arg($0).displayString) })
        case "containsAny": return .bool(args.indices.contains { s.contains(arg($0).displayString) })
        case "startsWith": return .bool(s.hasPrefix(arg(0).displayString))
        case "endsWith": return .bool(s.hasSuffix(arg(0).displayString))
        case "lower": return .string(s.lowercased())
        case "upper": return .string(s.uppercased())
        case "title": return .string(s.capitalized)
        case "trim": return .string(s.trimmingCharacters(in: .whitespacesAndNewlines))
        case "reverse": return .string(String(s.reversed()))
        case "repeat":
            guard case .number(let n) = arg(0), n >= 0, Double(s.count) * n <= 100_000 else { return .null }
            return .string(String(repeating: s, count: Int(n)))
        case "slice":
            let chars = Array(s)
            let (a, b) = sliceBounds(count: chars.count, arg(0), arg(1))
            return .string(String(chars[a..<b]))
        case "split":
            let parts: [String]
            switch arg(0) {
            case .regex(let r, _):
                var out: [String] = []
                var last = s.startIndex
                for m in r.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                    guard let range = Range(m.range, in: s) else { continue }
                    out.append(String(s[last..<range.lowerBound]))
                    last = range.upperBound
                }
                out.append(String(s[last...]))
                parts = out
            default:
                let sep = arg(0).displayString
                parts = sep.isEmpty ? s.map(String.init) : s.components(separatedBy: sep)
            }
            return .list(parts.prefix(Self.maximumListItems).map { .string($0) })
        case "replace":
            let replacement = arg(1).displayString
            switch arg(0) {
            case .regex(let r, let global):
                let range = NSRange(s.startIndex..., in: s)
                let template = NSRegularExpression.escapedTemplate(for: replacement)
                // Without the g flag only the first match is replaced.
                if global {
                    return .string(r.stringByReplacingMatches(in: s, range: range, withTemplate: template))
                }
                guard let m = r.firstMatch(in: s, range: range), let mr = Range(m.range, in: s) else { return .string(s) }
                return .string(s.replacingCharacters(in: mr, with: replacement))
            case let pattern:
                let p = pattern.displayString
                return .string(p.isEmpty ? s : s.replacingOccurrences(of: p, with: replacement))
            }
        default:
            unsupported.insert("." + name + "()")
            return .null
        }
    }

    private func listMethod(_ items: [BaseValue], _ name: String, _ args: [BaseExpr], locals: [String: BaseValue]) -> BaseValue {
        func arg(_ i: Int) -> BaseValue { i < args.count ? evaluate(args[i], locals: locals) : .null }
        switch name {
        case "contains":
            let v = arg(0)
            return .bool(items.contains { equals($0, v) })
        case "containsAll":
            let wanted = args.indices.map { arg($0) }
            return .bool(wanted.allSatisfy { w in items.contains { equals($0, w) } })
        case "containsAny":
            let wanted = args.indices.map { arg($0) }
            return .bool(wanted.contains { w in items.contains { equals($0, w) } })
        case "map", "filter":
            guard let body = args.first else { return .list(items) }
            var out: [BaseValue] = []
            for (i, item) in items.prefix(Self.maximumListItems).enumerated() {
                var scope = locals
                scope["value"] = item
                scope["index"] = .number(Double(i))
                let result = evaluate(body, locals: scope)
                if name == "map" {
                    out.append(result)
                } else if result.isTruthy {
                    out.append(item)
                }
            }
            return .list(out)
        case "join":
            let sep = args.isEmpty ? "," : arg(0).displayString
            return .string(items.map(\.displayString).joined(separator: sep))
        case "reverse": return .list(items.reversed())
        case "unique":
            var out: [BaseValue] = []
            for item in items where !out.contains(where: { equals($0, item) }) { out.append(item) }
            return .list(out)
        case "sort":
            return .list(items.sorted { compare($0, $1) == .orderedAscending })
        case "flat":
            return .list(items.flatMap { item -> [BaseValue] in if case .list(let inner) = item { inner } else { [item] } }.prefix(Self.maximumListItems).map { $0 })
        case "slice":
            let (a, b) = sliceBounds(count: items.count, arg(0), arg(1))
            return .list(Array(items[a..<b]))
        default:
            unsupported.insert("." + name + "()")
            return .null
        }
    }

    private func numberMethod(_ n: Double, _ name: String, _ args: [BaseExpr], locals: [String: BaseValue]) -> BaseValue {
        func arg(_ i: Int) -> BaseValue { i < args.count ? evaluate(args[i], locals: locals) : .null }
        switch name {
        case "abs": return .number(abs(n))
        case "ceil": return .number(n.rounded(.up))
        case "floor": return .number(n.rounded(.down))
        case "round":
            guard case .number(let digits) = arg(0), digits > 0, digits < 16 else { return .number(n.rounded()) }
            let factor = pow(10, digits.rounded())
            return .number((n * factor).rounded() / factor)
        case "toFixed":
            guard case .number(let digits) = arg(0), digits >= 0, digits < 16 else { return .string(BaseCell.format(n)) }
            return .string(String(format: "%.\(Int(digits))f", n))
        default:
            unsupported.insert("." + name + "()")
            return .null
        }
    }

    private func sliceBounds(count: Int, _ start: BaseValue, _ end: BaseValue) -> (Int, Int) {
        func resolve(_ v: BaseValue, _ fallback: Int) -> Int {
            guard case .number(let n) = v else { return fallback }
            let k = Int(n)
            return min(max(k < 0 ? count + k : k, 0), count)
        }
        let a = resolve(start, 0)
        return (a, max(a, resolve(end, count)))
    }

    // MARK: Operators

    private func binary(_ op: String, _ l: BaseValue, _ r: BaseValue) -> BaseValue {
        switch op {
        case "==": return .bool(equals(l, r))
        case "!=": return .bool(!equals(l, r))
        case "<", "<=", ">", ">=":
            guard let order = orderedCompare(l, r) else { return .bool(false) }
            switch op {
            case "<": return .bool(order == .orderedAscending)
            case "<=": return .bool(order != .orderedDescending)
            case ">": return .bool(order == .orderedDescending)
            default: return .bool(order != .orderedAscending)
            }
        case "+":
            switch (l, r) {
            case (.number(let a), .number(let b)): return .number(a + b)
            case (.list(let a), .list(let b)): return .list(a + b)
            case (.date(let d, let t), .string(let s)): return shift(d, t, s, sign: 1)
            case (.string, _), (_, .string): return .string(l.displayString + r.displayString)
            default: return .null
            }
        case "-":
            switch (l, r) {
            case (.number(let a), .number(let b)): return .number(a - b)
            case (.date(let a, _), .date(let b, _)): return .number((a.timeIntervalSince1970 - b.timeIntervalSince1970) * 1000)
            case (.date(let d, let t), .string(let s)): return shift(d, t, s, sign: -1)
            default: return .null
            }
        case "*", "/", "%":
            guard case .number(let a) = l, case .number(let b) = r else { return .null }
            switch op {
            case "*": return .number(a * b)
            case "/": return b == 0 ? .null : .number(a / b)
            default: return b == 0 ? .null : .number(a.truncatingRemainder(dividingBy: b))
            }
        default:
            return .null
        }
    }

    /// `date + "1d"`, `date - "2 weeks"`: y, M, w, d, h, m, s units.
    private func shift(_ date: Date, _ hasTime: Bool, _ duration: String, sign: Int) -> BaseValue {
        let trimmed = duration.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber || $0 == "-" }
        guard let amount = Int(digits) else { return .null }
        let unit = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let component: Calendar.Component
        switch unit {
        case "y", "year", "years": component = .year
        case "M", "month", "months": component = .month
        case "w", "week", "weeks": component = .weekOfYear
        case "d", "day", "days": component = .day
        case "h", "hour", "hours": component = .hour
        case "m", "minute", "minutes": component = .minute
        case "s", "second", "seconds": component = .second
        default: return .null
        }
        guard let shifted = BaseDates.calendar.date(byAdding: component, value: sign * amount, to: date) else { return .null }
        return .date(shifted, hasTime: hasTime || [.hour, .minute, .second].contains(component))
    }

    func equals(_ l: BaseValue, _ r: BaseValue) -> Bool {
        switch (l, r) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.date(let a, _), .date(let b, _)): return a == b
        case (.list(let a), .list(let b)): return a.count == b.count && zip(a, b).allSatisfy { equals($0, $1) }
        case (.link, _): return linkMatches(l, r)
        case (_, .link): return linkMatches(r, l)
        case (.file, .file): return true
        default: return false
        }
    }

    /// Order of two values of comparable types; nil otherwise.
    func orderedCompare(_ l: BaseValue, _ r: BaseValue) -> ComparisonResult? {
        switch (l, r) {
        case (.number(let a), .number(let b)): return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        case (.date(let a, _), .date(let b, _)): return a.compare(b)
        case (.string(let a), .string(let b)): return a.compare(b)
        case (.bool(let a), .bool(let b)): return a == b ? .orderedSame : (!a ? .orderedAscending : .orderedDescending)
        default: return nil
        }
    }

    /// Total order used by `list.sort()`.
    func compare(_ l: BaseValue, _ r: BaseValue) -> ComparisonResult {
        orderedCompare(l, r) ?? l.displayString.localizedStandardCompare(r.displayString)
    }
}
