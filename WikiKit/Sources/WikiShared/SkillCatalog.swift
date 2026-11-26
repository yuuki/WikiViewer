//
//  SkillCatalog.swift
//  WikiShared
//
//  The vault's agent skills a device may ask the Mac to run. `wikiindex
//  requests` reads them from `<vault>/.claude/skills/<name>/SKILL.md` and
//  publishes their names and descriptions as `<publish>/requests/skills.json`,
//  next to the request status files; the app reads it through the same
//  transport and offers the skills in a picker. Only the Mac decides what is
//  in it, and the worker refuses a `skill` request for any name it does not
//  list at the time it runs.
//

import Foundation

public struct SkillCatalog: Codable, Sendable, Equatable {
    public struct Skill: Codable, Sendable, Equatable, Identifiable, Hashable {
        /// The skill's name, as Claude Code invokes it (`/name`).
        public var name: String
        /// What the skill does and when to use it (the SKILL.md description).
        public var description: String
        /// What to pass the skill (`argument-hint`), if it says.
        public var argumentHint: String?
        /// Whether the Mac lets this skill use the web (nil: it does not).
        /// Questions and learning paths never do.
        public var usesWeb: Bool?

        public var id: String { name }

        public init(name: String, description: String, argumentHint: String? = nil, usesWeb: Bool = false) {
            self.name = name
            self.description = description
            self.argumentHint = argumentHint
            self.usesWeb = usesWeb ? true : nil
        }
    }

    public static let currentVersion = 1

    public var version: Int
    public var updatedAt: Date
    /// Sorted by name.
    public var skills: [Skill]

    public init(updatedAt: Date = Date(), skills: [Skill]) {
        version = Self.currentVersion
        self.updatedAt = Date(timeIntervalSince1970: updatedAt.timeIntervalSince1970.rounded(.down))
        self.skills = skills.sorted { $0.name < $1.name }
    }

    public func skill(named name: String) -> Skill? { skills.first { $0.name == name } }

    // MARK: Limits

    public static let maximumEncodedSize = 512 * 1024
    public static let maximumSkills = 500
    public static let maximumDescriptionLength = 2_000
    public static let maximumNameLength = 64

    /// Published path of the catalog.
    public static let publishedPath = "requests/skills.json"

    /// Lower-case letters, digits, `-`, `_` and `.`, starting with a letter or
    /// digit: the names Claude Code gives skill folders. Nothing that could
    /// read as a path, an option or another command.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maximumNameLength, let first = name.unicodeScalars.first,
              ("a"..."z").contains(first) || ("0"..."9").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || "-_.".unicodeScalars.contains($0) }
    }

    /// Decodes untrusted bytes, dropping entries that are not valid and
    /// shortening long descriptions.
    public static func decode(_ data: Data) throws -> SkillCatalog {
        guard data.count <= maximumEncodedSize else { throw HostRequest.ValidationError.tooLarge("skills") }
        var catalog = try HostRequest.decoder.decode(SkillCatalog.self, from: data)
        guard catalog.version == currentVersion else { throw HostRequest.ValidationError.unsupportedVersion(catalog.version) }
        catalog.skills = catalog.skills.prefix(maximumSkills).compactMap { skill in
            guard isValidName(skill.name) else { return nil }
            var skill = skill
            skill.description = String(skill.description.prefix(maximumDescriptionLength))
            skill.argumentHint = skill.argumentHint.map { String($0.prefix(200)) }
            return skill
        }
        return catalog
    }

    public func encoded() throws -> Data {
        let data = try HostRequest.encoder.encode(self)
        guard data.count <= Self.maximumEncodedSize else { throw HostRequest.ValidationError.tooLarge("skills") }
        return data
    }
}
