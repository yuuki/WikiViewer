import Foundation
import Testing
@testable import WikiShared

struct SkillCatalogTests {
    @Test func catalogRoundTripsSorted() throws {
        let catalog = SkillCatalog(skills: [SkillCatalog.Skill(name: "wiki-query", description: "Q"),
                                            SkillCatalog.Skill(name: "wiki-gap", description: "G", argumentHint: "[topic]")])
        #expect(catalog.skills.map(\.name) == ["wiki-gap", "wiki-query"])
        #expect(try SkillCatalog.decode(try catalog.encoded()) == catalog)
    }

    @Test func decodingDropsUnsafeNamesAndShortensDescriptions() throws {
        let json = """
        {"version": 1, "updatedAt": "2026-10-08T00:00:00Z", "skills": [
          {"name": "../etc", "description": "x"},
          {"name": "ok", "description": "\(String(repeating: "d", count: SkillCatalog.maximumDescriptionLength + 10))"}
        ]}
        """
        let catalog = try SkillCatalog.decode(Data(json.utf8))
        #expect(catalog.skills.map(\.name) == ["ok"])
        #expect(catalog.skills[0].description.count == SkillCatalog.maximumDescriptionLength)
        #expect(throws: HostRequest.ValidationError.unsupportedVersion(2)) {
            try SkillCatalog.decode(Data(#"{"version": 2, "updatedAt": "2026-10-08T00:00:00Z", "skills": []}"#.utf8))
        }
    }
}
