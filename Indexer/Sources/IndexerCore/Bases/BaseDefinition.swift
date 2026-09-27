//
//  BaseDefinition.swift
//  IndexerCore
//
//  The contents of a `.base` file (YAML): global filters, formulas,
//  property display names and views. Parse errors in one expression are
//  collected and reported, not fatal: the rest of the base still works.
//

import Foundation
import Yams

indirect enum BaseFilter: Sendable {
    case expression(BaseExpr)
    case and([BaseFilter])
    case or([BaseFilter])
    /// True if none of the filters is true.
    case not([BaseFilter])
}

struct BaseSortSpec: Sendable {
    var property: String
    var ascending: Bool
}

struct BaseViewDefinition: Sendable {
    var type: String
    var name: String
    var order: [String]
    var sort: [BaseSortSpec]
    var groupBy: BaseSortSpec?
    var filters: BaseFilter?
    var limit: Int?
}

struct BaseDefinition: Sendable {
    var filters: BaseFilter?
    var formulas: [String: BaseExpr]
    var displayNames: [String: String]
    var views: [BaseViewDefinition]
    var errors: [String]

    /// Largest `.base` file read (they are small YAML documents).
    static let maximumBytes = 1024 * 1024

    static func parse(_ yaml: String) -> BaseDefinition {
        var definition = BaseDefinition(filters: nil, formulas: [:], displayNames: [:], views: [], errors: [])
        let node: Node?
        do {
            node = try Yams.compose(yaml: yaml)
        } catch {
            definition.errors.append("invalid YAML: \(error)")
            return definition
        }
        guard let node else {
            return definition
        }
        guard case .mapping(let root) = node else {
            definition.errors.append("a base must be a YAML mapping")
            return definition
        }
        if let filters = root["filters"] {
            definition.filters = definition.filter(filters, depth: 0)
        }
        if case .mapping(let formulas)? = root["formulas"] {
            for (key, value) in formulas {
                guard let name = key.string, let source = value.string else { continue }
                do {
                    definition.formulas[name] = try BaseExpressionParser.parse(source)
                } catch {
                    definition.errors.append("formula \(name): \(error)")
                }
            }
        }
        if case .mapping(let properties)? = root["properties"] {
            for (key, value) in properties {
                guard let id = key.string, case .mapping(let options) = value,
                      let displayName = options["displayName"]?.string else { continue }
                definition.displayNames[id] = displayName
            }
        }
        if case .sequence(let views)? = root["views"] {
            for (i, view) in views.enumerated() {
                guard case .mapping(let v) = view else { continue }
                var parsed = BaseViewDefinition(
                    type: v["type"]?.string ?? "table",
                    name: v["name"]?.string ?? "View \(i + 1)",
                    order: [], sort: [], groupBy: nil, filters: nil, limit: nil
                )
                if case .sequence(let order)? = v["order"] {
                    parsed.order = order.compactMap(\.string)
                }
                if case .sequence(let sort)? = v["sort"] {
                    parsed.sort = sort.compactMap(Self.sortSpec)
                }
                if let group = v["groupBy"] {
                    parsed.groupBy = Self.sortSpec(group)
                }
                if let filters = v["filters"] {
                    parsed.filters = definition.filter(filters, depth: 0)
                }
                if let limit = v["limit"]?.int, limit > 0 {
                    parsed.limit = limit
                }
                definition.views.append(parsed)
            }
        }
        if definition.views.isEmpty {
            // Obsidian shows a default table of every matching file.
            definition.views.append(BaseViewDefinition(type: "table", name: "Table", order: ["file.name"], sort: [], groupBy: nil, filters: nil, limit: nil))
        }
        return definition
    }

    private static func sortSpec(_ node: Node) -> BaseSortSpec? {
        if let property = node.string { return BaseSortSpec(property: property, ascending: true) }
        guard case .mapping(let m) = node, let property = m["property"]?.string else { return nil }
        return BaseSortSpec(property: property, ascending: m["direction"]?.string?.uppercased() != "DESC")
    }

    private mutating func filter(_ node: Node, depth: Int) -> BaseFilter? {
        guard depth < BaseExpressionParser.maximumDepth else {
            errors.append("filters nested too deeply")
            return nil
        }
        switch node {
        case .scalar(let scalar):
            do {
                return .expression(try BaseExpressionParser.parse(scalar.string))
            } catch {
                errors.append("filter: \(error)")
                return nil
            }
        case .mapping(let m):
            var parts: [BaseFilter] = []
            for (key, value) in m {
                let children: [BaseFilter]
                if case .sequence(let seq) = value {
                    children = seq.compactMap { filter($0, depth: depth + 1) }
                } else {
                    children = [filter(value, depth: depth + 1)].compactMap { $0 }
                }
                switch key.string {
                case "and": parts.append(.and(children))
                case "or": parts.append(.or(children))
                case "not": parts.append(.not(children))
                default: errors.append("unknown filter \(key.string ?? "?")")
                }
            }
            return parts.count == 1 ? parts[0] : .and(parts)
        case .sequence(let seq):
            return .and(seq.compactMap { filter($0, depth: depth + 1) })
        case .alias:
            return nil
        }
    }

    /// A folder every matching note must be in, when the global filter says
    /// so at its top level (`file.inFolder("x")` under `and`). Lets the
    /// builder read only that folder's notes.
    var requiredFolder: String? {
        func folder(_ filter: BaseFilter) -> String? {
            switch filter {
            case .expression(.call(callee: .member(.name("file"), "inFolder"), args: let args)):
                guard args.count == 1, case .literal(.string(let path)) = args[0] else { return nil }
                let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return trimmed.isEmpty ? nil : trimmed
            case .and(let parts):
                return parts.lazy.compactMap(folder).first
            default:
                return nil
            }
        }
        return filters.flatMap(folder)
    }
}
