//
//  BaseBuilder.swift
//  IndexerCore
//
//  Evaluates every `.base` file over the notes and writes the result into
//  the `bases` / `base_cells` / `base_rows` / `base_groups` tables.
//
//  Runs before each publication (a base depends on every note, so it cannot
//  follow single files like link resolution does). The result is diffed
//  against the stored rows and only differences are written: rows are keyed
//  by values derived from the note alone, so a one-note edit changes a
//  handful of rows and the published delta stays small.
//

import Foundation
import GRDB
import WikiShared

public struct BaseBuildStats: Sendable, CustomStringConvertible {
    public var bases = 0
    public var rows = 0
    public var written = 0
    public var seconds = 0.0

    public var description: String {
        "bases=\(bases) rows=\(rows) written=\(written) in \(String(format: "%.3f", seconds))s"
    }
}

enum BaseBuilder {
    /// Upper bound on the rows of one view (the viewer pages them).
    static let maximumRowsPerView = 200_000

    static func rebuild(_ db: Database) throws -> BaseBuildStats {
        let start = Clock.now()
        var stats = BaseBuildStats()
        // Rows of bases that no longer exist (deleteAsset removes them too).
        for table in ["base_cells", "base_rows", "base_groups"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE base_id NOT IN (SELECT asset_id FROM bases)")
            stats.written += db.changesCount
        }
        let bases = try Row.fetchAll(db, sql: "SELECT b.asset_id, a.path, b.source, b.definition FROM bases b JOIN assets a ON a.id = b.asset_id ORDER BY b.asset_id")
        let links = LinkLookup()
        for row in bases {
            let id: Int64 = row[0]
            let path: String = row[1]
            let source: String = row[2]
            let stored: String? = row[3]
            try autoreleasepool {
                let result = try evaluate(db, basePath: path, source: source, links: links)
                stats.rows += result.rows.count
                stats.written += try store(db, baseID: id, result: result, storedDefinition: stored)
            }
            stats.bases += 1
        }
        stats.seconds = Clock.seconds(since: start)
        return stats
    }

    struct RowKey: Hashable {
        var view: Int
        var groupKey: Data
        var sortKey: Data
        var noteID: Int64

        /// The order of the `base_rows` primary key within one view.
        static func precedes(_ a: RowKey, _ b: RowKey) -> Bool {
            if a.groupKey != b.groupKey { return a.groupKey.lexicographicallyPrecedes(b.groupKey) }
            if a.sortKey != b.sortKey { return a.sortKey.lexicographicallyPrecedes(b.sortKey) }
            return a.noteID < b.noteID
        }

        /// The order of the whole `base_rows` primary key.
        static func inKeyOrder(_ a: RowKey, _ b: RowKey) -> Bool {
            a.view != b.view ? a.view < b.view : precedes(a, b)
        }
    }

    struct GroupKey: Hashable {
        var view: Int
        var key: Data

        static func inKeyOrder(_ a: GroupKey, _ b: GroupKey) -> Bool {
            a.view != b.view ? a.view < b.view : a.key.lexicographicallyPrecedes(b.key)
        }
    }

    struct Result {
        var definitionJSON: String
        var cells: [Int64: String] = [:]
        var rows: [RowKey] = []
        var groups: [GroupKey: (label: String?, count: Int)] = [:]
    }

    static func evaluate(_ db: Database, basePath: String, source: String, links: LinkLookup) throws -> Result {
        let definition = BaseDefinition.parse(source)
        let evaluator = BaseEvaluator(formulas: definition.formulas)
        // Every column any view shows, in first-seen order.
        var columns: [String] = []
        for view in definition.views {
            for id in view.order where !columns.contains(id) { columns.append(id) }
        }
        var rows: [[RowKey]] = Array(repeating: [], count: definition.views.count)
        var labels: [GroupKey: String?] = [:]
        var cells: [Int64: String] = [:]

        var sql = "SELECT id, path, mtime_ns, size, frontmatter FROM notes"
        var arguments: StatementArguments = []
        if let folder = definition.requiredFolder {
            // Range scan on the UNIQUE path index ("/" < "0").
            sql += " WHERE path >= ? AND path < ?"
            arguments = [folder + "/", folder + "0"]
        }
        let tagStatement = try db.cachedStatement(sql: "SELECT t.name FROM note_tags nt JOIN tags t ON t.id = nt.tag_id WHERE nt.note_id = ? ORDER BY t.id")
        let linkStatement = try db.cachedStatement(sql: """
            SELECT l.target_path, l.display, n.path FROM links l LEFT JOIN notes n ON n.id = l.target_note_id
            WHERE l.source_note_id = ? AND l.is_embed = 0 ORDER BY l.ordinal LIMIT 5000
            """)
        let backlinkStatement = try db.cachedStatement(sql: """
            SELECT DISTINCT n.path FROM links l JOIN notes n ON n.id = l.source_note_id
            WHERE l.target_note_id = ? AND l.source_note_id != ? LIMIT 5000
            """)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        while let row = try cursor.next() {
            let id: Int64 = row[0]
            let path: String = row[1]
            let properties = decodeProperties(row[4])
            let note = BaseNote(
                id: id, path: path, mtimeNs: row[2], size: row[3], properties: properties,
                tags: {
                    // Frontmatter tags in their written order, then inline ones.
                    var names: [String] = []
                    var keys = Set<String>()
                    let written = properties.first { ["tags", "tag"].contains($0.0.lowercased()) }?.1
                    let frontmatter: [String] = switch written {
                    case .list(let items)?: items.map(\.displayString)
                    case .string(let s)?: s.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                    default: []
                    }
                    let stored = (try? String.fetchAll(tagStatement, arguments: [id])) ?? []
                    for raw in frontmatter + stored {
                        var name = raw.trimmingCharacters(in: .whitespaces)
                        while name.hasPrefix("#") { name.removeFirst() }
                        if !name.isEmpty, keys.insert(VaultPath.matchKey(name)).inserted { names.append(name) }
                    }
                    return names
                },
                links: {
                    ((try? Row.fetchAll(linkStatement, arguments: [id])) ?? []).map {
                        BaseValue.link(target: $0[0], display: $0[1], path: $0[2])
                    }
                },
                backlinks: {
                    ((try? String.fetchAll(backlinkStatement, arguments: [id, id])) ?? []).map {
                        BaseValue.link(target: $0, display: nil, path: $0)
                    }
                }
            )
            evaluator.begin(note)
            guard definition.filters.map({ matches($0, evaluator) }) ?? true else { continue }
            var included = false
            for (index, view) in definition.views.enumerated() {
                guard view.filters.map({ matches($0, evaluator) }) ?? true else { continue }
                var groupKey = Data()
                if let group = view.groupBy {
                    let value = evaluator.property(id: group.property)
                    groupKey = BaseSortKey.encode(value, ascending: group.ascending)
                    let key = GroupKey(view: index, key: groupKey)
                    if labels[key] == nil {
                        labels[key] = value.isEmptyValue ? .some(nil) : .some(value.displayString)
                    }
                }
                var sortKey = Data()
                let specs = view.sort.isEmpty ? [BaseSortSpec(property: "file.name", ascending: true)] : view.sort
                for spec in specs {
                    sortKey.append(BaseSortKey.encode(evaluator.property(id: spec.property), ascending: spec.ascending))
                }
                rows[index].append(RowKey(view: index, groupKey: groupKey, sortKey: sortKey, noteID: id))
                included = true
            }
            guard included else { continue }
            var object: [String: BaseCell] = [:]
            for column in columns where column != "file.name" && column != "file.basename" {
                let value = evaluator.property(id: column)
                if let cell = cell(value, links: links, db: db, sourcePath: basePath) { object[column] = cell }
            }
            cells[id] = String(decoding: try encoder.encode(object), as: UTF8.self)
        }

        var result = Result(definitionJSON: "")
        var documentViews: [BaseDocument.View] = []
        for (index, view) in definition.views.enumerated() {
            var viewRows = rows[index]
            let limit = min(view.limit ?? maximumRowsPerView, maximumRowsPerView)
            if viewRows.count > limit {
                viewRows.sort(by: RowKey.precedes)
                viewRows = Array(viewRows.prefix(limit))
            }
            if view.groupBy != nil {
                for row in viewRows {
                    let key = GroupKey(view: index, key: row.groupKey)
                    result.groups[key, default: (label: labels[key] ?? nil, count: 0)].count += 1
                }
            }
            result.rows += viewRows
            documentViews.append(BaseDocument.View(
                type: view.type,
                name: view.name,
                columns: view.order.map { BaseDocument.Column(id: $0, displayName: displayName(of: $0, in: definition)) },
                grouped: view.groupBy != nil,
                rowCount: viewRows.count
            ))
        }
        let used = Set(result.rows.map(\.noteID))
        result.cells = cells.filter { used.contains($0.key) }
        var errors = definition.errors
        if !evaluator.unsupported.isEmpty {
            errors.append("unsupported: " + evaluator.unsupported.sorted().joined(separator: ", "))
        }
        let document = BaseDocument(views: documentViews, error: errors.isEmpty ? nil : errors.joined(separator: "\n"))
        result.definitionJSON = String(decoding: try encoder.encode(document), as: UTF8.self)
        return result
    }

    static func matches(_ filter: BaseFilter, _ evaluator: BaseEvaluator) -> Bool {
        switch filter {
        case .expression(let expr): evaluator.evaluate(expr, locals: [:]).isTruthy
        case .and(let parts): parts.allSatisfy { matches($0, evaluator) }
        case .or(let parts): parts.contains { matches($0, evaluator) }
        case .not(let parts): !parts.contains { matches($0, evaluator) }
        }
    }

    static func displayName(of id: String, in definition: BaseDefinition) -> String? {
        if let name = definition.displayNames[id] { return name }
        if id.hasPrefix("note.") { return definition.displayNames[String(id.dropFirst(5))] }
        return definition.displayNames["note." + id]
    }

    static func decodeProperties(_ json: String?) -> [(String, BaseValue)] {
        guard let json, let data = json.data(using: .utf8),
              let pairs = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }
        return pairs.compactMap { pair in
            guard pair.count == 2, let key = pair[0] as? String else { return nil }
            return (key, BaseValue.fromJSON(pair[1]))
        }
    }

    /// The cell stored for a value; nil for an empty one.
    static func cell(_ value: BaseValue, links: LinkLookup, db: Database, sourcePath: String, depth: Int = 0) -> BaseCell? {
        switch value {
        case .null, .file, .scope, .regex: return nil
        case .bool(let b): return .bool(b)
        case .number(let n): return n.isFinite ? .number(n) : nil
        case .date(let d, let hasTime): return .date(BaseDates.display(d, hasTime: hasTime))
        case .string(let s):
            if s.isEmpty { return nil }
            if s.hasPrefix("[["), s.hasSuffix("]]"), let link = links.link(in: s, db: db, sourcePath: sourcePath) { return link }
            return .text(s)
        case .link(let target, let display, let path):
            let resolved = path ?? links.resolve(target, db: db, sourcePath: sourcePath)
            return .link(display: display ?? BaseValue.linkName(target), path: resolved)
        case .list(let items):
            guard depth < 4 else { return .text(value.displayString) }
            let cells = items.prefix(1000).compactMap { cell($0, links: links, db: db, sourcePath: sourcePath, depth: depth + 1) }
            return cells.isEmpty ? nil : .list(cells)
        case .object:
            return .text(value.displayString)
        }
    }

    /// Writes the differences between `result` and the stored rows, in key
    /// order: hash order differs between runs, and with it how pages split,
    /// so the same base would otherwise give a different file each time.
    /// Returns the number of rows written or deleted.
    static func store(_ db: Database, baseID: Int64, result: Result, storedDefinition: String?) throws -> Int {
        var written = 0
        if storedDefinition != result.definitionJSON {
            try db.execute(sql: "UPDATE bases SET definition = ? WHERE asset_id = ?", arguments: [result.definitionJSON, baseID])
            written += 1
        }

        var oldCells: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT note_id, cells FROM base_cells WHERE base_id = ?", arguments: [baseID]) {
            oldCells[row[0]] = row[1]
        }
        let deleteCell = try db.cachedStatement(sql: "DELETE FROM base_cells WHERE base_id = ? AND note_id = ?")
        let upsertCell = try db.cachedStatement(sql: "INSERT OR REPLACE INTO base_cells(base_id, note_id, cells) VALUES (?, ?, ?)")
        for noteID in oldCells.keys.sorted() where result.cells[noteID] == nil {
            try deleteCell.execute(arguments: [baseID, noteID])
            written += 1
        }
        for (noteID, cells) in result.cells.sorted(by: { $0.key < $1.key }) where oldCells[noteID] != cells {
            try upsertCell.execute(arguments: [baseID, noteID, cells])
            written += 1
        }

        var oldRows = Set<RowKey>()
        for row in try Row.fetchAll(db, sql: "SELECT view, group_key, sort_key, note_id FROM base_rows WHERE base_id = ?", arguments: [baseID]) {
            oldRows.insert(RowKey(view: row[0], groupKey: row[1], sortKey: row[2], noteID: row[3]))
        }
        let newRows = Set(result.rows)
        let deleteRow = try db.cachedStatement(sql: "DELETE FROM base_rows WHERE base_id = ? AND view = ? AND group_key = ? AND sort_key = ? AND note_id = ?")
        let insertRow = try db.cachedStatement(sql: "INSERT INTO base_rows(base_id, view, group_key, sort_key, note_id) VALUES (?, ?, ?, ?, ?)")
        for row in oldRows.subtracting(newRows).sorted(by: RowKey.inKeyOrder) {
            try deleteRow.execute(arguments: [baseID, row.view, row.groupKey, row.sortKey, row.noteID])
            written += 1
        }
        for row in newRows.subtracting(oldRows).sorted(by: RowKey.inKeyOrder) {
            try insertRow.execute(arguments: [baseID, row.view, row.groupKey, row.sortKey, row.noteID])
            written += 1
        }

        var oldGroups: [GroupKey: (String?, Int)] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT view, group_key, label, row_count FROM base_groups WHERE base_id = ?", arguments: [baseID]) {
            oldGroups[GroupKey(view: row[0], key: row[1])] = (row[2], row[3])
        }
        let deleteGroup = try db.cachedStatement(sql: "DELETE FROM base_groups WHERE base_id = ? AND view = ? AND group_key = ?")
        let upsertGroup = try db.cachedStatement(sql: "INSERT OR REPLACE INTO base_groups(base_id, view, group_key, label, row_count) VALUES (?, ?, ?, ?, ?)")
        for key in oldGroups.keys.sorted(by: GroupKey.inKeyOrder) where result.groups[key] == nil {
            try deleteGroup.execute(arguments: [baseID, key.view, key.key])
            written += 1
        }
        for (key, group) in result.groups.sorted(by: { GroupKey.inKeyOrder($0.key, $1.key) }) {
            if let old = oldGroups[key], old.0 == group.label, old.1 == group.count { continue }
            try upsertGroup.execute(arguments: [baseID, key.view, key.key, group.label, group.count])
            written += 1
        }
        return written
    }
}

/// Resolves wikilinks found in property values (`related: "[[Note]]"`) to
/// note paths with the indexer's link rules, caching by target.
final class LinkLookup {
    private var cache: [String: String?] = [:]
    private let scanner = ObsidianScanner()

    func link(in text: String, db: Database, sourcePath: String) -> BaseCell? {
        guard let link = scanner.scan(text).links.first, link.kind == .wiki, !link.isEmbed, text == "[[" + link.raw + "]]" else { return nil }
        let target = link.target.path
        let display = link.target.display ?? BaseValue.linkName(target)
        return .link(display: display, path: resolve(target, db: db, sourcePath: sourcePath))
    }

    func resolve(_ target: String, db: Database, sourcePath: String) -> String? {
        if let cached = cache[target] { return cached }
        let resolution = LinkResolver.classify(kind: .wiki, targetPath: target, sourcePath: sourcePath)
        var path: String?
        if case .note(let key, _, _, _) = resolution,
           let rows = try? Row.fetchAll(db, sql: "SELECT id, path FROM notes WHERE basename_key = ?", arguments: [key]) {
            let candidates = rows.map { ResolutionCandidate(id: $0[0], path: $0[1]) }
            if let id = LinkResolver.choose(resolution, candidates: candidates, sourcePath: sourcePath) {
                path = candidates.first { $0.id == id }?.path
            }
        }
        cache[target] = path
        return path
    }
}

/// Order-preserving binary encoding of values, so SQLite's memcmp order on
/// BLOBs is the base's sort order. Each value is a type byte and a payload;
/// descending values are bitwise complemented. Empty values always sort
/// last (their byte, 0xF0, is never complemented and is above every
/// complemented type byte).
enum BaseSortKey {
    static func encode(_ value: BaseValue, ascending: Bool) -> Data {
        var bytes: [UInt8]
        switch value {
        case _ where value.isEmptyValue:
            return Data([0xF0])
        case .bool(let b):
            bytes = [0x10, b ? 1 : 0]
        case .number(let n):
            bytes = [0x20] + orderedBytes(n)
        case .date(let d, _):
            bytes = [0x20] + orderedBytes(d.timeIntervalSince1970)
        default:
            bytes = [0x30] + escaped(value.displayString.lowercased())
        }
        if !ascending { bytes = bytes.map { ~$0 } }
        return Data(bytes)
    }

    /// IEEE 754 bits made to sort like the numbers they encode.
    static func orderedBytes(_ n: Double) -> [UInt8] {
        let bits = n.isNaN ? UInt64.max : n.bitPattern
        let ordered = bits & (1 << 63) != 0 ? ~bits : bits | (1 << 63)
        return (0..<8).map { UInt8(truncatingIfNeeded: ordered >> (56 - 8 * $0)) }
    }

    /// UTF-8 with 0x00 escaped as 0x00 0xFF and a 0x00 0x00 terminator, so a
    /// prefix sorts before its extensions in both directions.
    static func escaped(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count + 2)
        for byte in s.utf8 {
            out.append(byte)
            if byte == 0 { out.append(0xFF) }
        }
        out += [0, 0]
        return out
    }
}
