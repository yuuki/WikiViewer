//
//  SkillScanner.swift
//  IndexerCore
//
//  Reads the vault's agent skills into the `SkillCatalog` that `wikiindex
//  requests` publishes for the app. Skills are folders with a SKILL.md
//  under `.claude/skills` (what Claude Code loads) and `.agents/skills`
//  (shared with other agents). Folders are often symbolic links between the
//  two, so each is resolved and a skill whose SKILL.md is already listed is
//  not listed again; for a name in both places with different contents,
//  `.claude/skills` wins, as it does for Claude Code.
//
//  Only the frontmatter is read: the name, the description and the argument
//  hint. A skill that may not be invoked by the model
//  (`disable-model-invocation`) or by the user (`user-invocable: false`) is
//  left out, as is anything the Mac's own allow- or deny-list excludes.
//
//  A skill may use the web when it says so (`allowed-tools` with WebFetch
//  or WebSearch) or its name matches one of `webPatterns`: skills such as
//  ingesting a URL cannot work without it. Everything else, and every
//  question or learning path, runs without the web (THREAT_MODEL.md).
//

import Foundation
import WikiShared
import Yams

public struct SkillScanner: Sendable {
    /// Folders of skills, relative to the vault, in order of precedence.
    public static let folders = [".claude/skills", ".agents/skills"]
    /// The folder Claude Code loads skills from (invocable with the Skill tool).
    static let claudeFolder = ".claude/skills"
    /// SKILL.md files larger than this are skipped.
    static let maximumFileSize = 256 * 1024

    /// One skill and where it is on the Mac (never published).
    public struct Entry: Sendable, Equatable {
        public var skill: SkillCatalog.Skill
        /// The SKILL.md, symbolic links resolved.
        public var file: URL
        /// Whether Claude Code knows it by this name (it is in `.claude/skills`);
        /// otherwise the runner has Claude read `file` and follow it.
        public var isClaudeSkill: Bool
    }

    public var vault: URL
    /// If set, only these skills are offered.
    public var allowed: Set<String>?
    /// Never offered.
    public var denied: Set<String> = []
    /// Names (shell patterns, `*` and `?`) of skills that may use the web.
    public var webPatterns: [String]
    /// False: no skill may use the web, whatever its SKILL.md says.
    public var allowsWeb = true

    /// Skills of the research vault that fetch what they work on.
    public static let defaultWebPatterns = ["wiki-ingest*", "autoresearch", "create-*-note", "paper-curation", "hn-curation", "defuddle"]

    public init(vault: URL, allowed: Set<String>? = nil, denied: Set<String> = [], webPatterns: [String] = SkillScanner.defaultWebPatterns) {
        self.vault = vault
        self.allowed = allowed
        self.denied = denied
        self.webPatterns = webPatterns
    }

    /// Whether `name` matches one of `webPatterns`.
    func webAllowed(byName name: String) -> Bool {
        webPatterns.contains { fnmatch($0, name, 0) == 0 }
    }

    /// The skills the vault has now, sorted by name.
    public func scan(now: Date = Date()) -> SkillCatalog {
        SkillCatalog(updatedAt: now, skills: entries().map(\.skill))
    }

    /// The skill named `name`, if offered now.
    public func entry(named name: String) -> Entry? {
        entries().first { $0.skill.name == name }
    }

    /// Every skill offered, sorted by name, each listed once.
    public func entries() -> [Entry] {
        var byName: [String: Entry] = [:]
        var seenFiles: Set<String> = []
        for folder in Self.folders {
            let root = vault.appendingPathComponent(folder, isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for name in names.sorted() where SkillCatalog.isValidName(name) {
                guard byName[name] == nil, allowed?.contains(name) ?? true, !denied.contains(name) else { continue }
                let file = root.appendingPathComponent(name).appendingPathComponent("SKILL.md").resolvingSymlinksInPath()
                guard !seenFiles.contains(file.path), var skill = Self.read(file, name: name) else { continue }
                skill.usesWeb = allowsWeb && (skill.usesWeb == true || webAllowed(byName: name)) ? true : nil
                seenFiles.insert(file.path)
                byName[name] = Entry(skill: skill, file: file, isClaudeSkill: folder == Self.claudeFolder)
                if byName.count == SkillCatalog.maximumSkills { break }
            }
        }
        return byName.values.sorted { $0.skill.name < $1.skill.name }
    }

    /// The skill described by one SKILL.md (links already resolved), or nil
    /// if it cannot be offered. The folder name names the skill: that is
    /// what Claude Code invokes.
    static func read(_ file: URL, name: String) -> SkillCatalog.Skill? {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= maximumFileSize,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return parse(text, name: name)
    }

    static func parse(_ text: String, name: String) -> SkillCatalog.Skill? {
        guard let yaml = Frontmatter.split(text).yaml,
              case .mapping(let mapping)? = try? Yams.compose(yaml: yaml) else { return nil }
        func string(_ key: String) -> String? {
            mapping[Node(key)]?.string.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        func flag(_ key: String) -> Bool? { mapping[Node(key)]?.bool }
        if flag("disable-model-invocation") == true || flag("user-invocable") == false { return nil }
        // `allowed-tools` is a string ("Read Write WebFetch" or comma
        // separated) or a list.
        let tools: [String]
        switch mapping[Node("allowed-tools")] {
        case .scalar(let scalar)?: tools = scalar.string.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        case .sequence(let sequence)?: tools = sequence.compactMap(\.string)
        default: tools = []
        }
        let declaresWeb = tools.contains { $0.hasPrefix("WebFetch") || $0.hasPrefix("WebSearch") }
        let description = (string("description") ?? "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        let hint = string("argument-hint").flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        return SkillCatalog.Skill(name: name, description: String(description.prefix(SkillCatalog.maximumDescriptionLength)),
                                  argumentHint: hint, usesWeb: declaresWeb)
    }
}
