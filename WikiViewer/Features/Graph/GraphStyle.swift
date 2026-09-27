//
//  GraphStyle.swift
//  WikiViewer
//
//  Colours and the reader's graph preferences, shared by the overview, the
//  cluster view and the local graph.
//

import SwiftUI
import WikiViewerKit

enum GraphColorMode: String, CaseIterable, Identifiable {
    case cluster, type, status
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .cluster: "Cluster"
        case .type: "Type"
        case .status: "Status"
        }
    }
}

/// Graph preferences, stored in UserDefaults.
enum GraphPreferences {
    static let colorModeKey = "WikiViewer.graph.colorMode"
    static let hiddenTypesKey = "WikiViewer.graph.hiddenTypes"

    /// Hidden types are stored as one newline-separated string.
    static func decode(_ stored: String) -> Set<String> {
        Set(stored.split(separator: "\n").map(String.init))
    }

    static func encode(_ types: Set<String>) -> String {
        types.sorted().joined(separator: "\n")
    }
}

enum GraphPalette {
    /// Distinct hues that read on light and dark backgrounds.
    static let clusters: [Color] = [
        Color(red: 0.90, green: 0.35, blue: 0.40), Color(red: 0.26, green: 0.62, blue: 0.95),
        Color(red: 0.36, green: 0.74, blue: 0.40), Color(red: 0.96, green: 0.56, blue: 0.20),
        Color(red: 0.62, green: 0.42, blue: 0.90), Color(red: 0.18, green: 0.76, blue: 0.80),
        Color(red: 0.93, green: 0.36, blue: 0.76), Color(red: 0.80, green: 0.70, blue: 0.20),
        Color(red: 0.45, green: 0.55, blue: 0.95), Color(red: 0.62, green: 0.45, blue: 0.30),
        Color(red: 0.30, green: 0.60, blue: 0.55), Color(red: 0.75, green: 0.50, blue: 0.60),
    ]

    static func cluster(_ id: Int64?) -> Color {
        guard let id else { return .gray }
        return clusters[Int(UInt64(bitPattern: id) % UInt64(clusters.count))]
    }

    /// The wiki layer's page types keep the colours wiki-lens gives them.
    static let knownTypes: [String: Color] = [
        "concept": Color(red: 0.96, green: 0.51, blue: 0.19),
        "source": Color(red: 0.26, green: 0.39, blue: 0.85),
        "entity": Color(red: 0.24, green: 0.71, blue: 0.29),
        "question": Color(red: 0.94, green: 0.20, blue: 0.90),
    ]

    static let knownStatuses: [String: Color] = [
        "seed": Color(white: 0.55),
        "developing": Color(red: 0.26, green: 0.83, blue: 0.96),
        "mature": Color(red: 0.24, green: 0.71, blue: 0.29),
        "evergreen": Color(red: 0.90, green: 0.78, blue: 0.10),
    ]

    static func type(_ name: String?) -> Color {
        guard let name else { return .gray }
        return knownTypes[name] ?? hashed(name)
    }

    static func status(_ name: String?) -> Color {
        guard let name else { return .gray }
        return knownStatuses[name] ?? hashed(name)
    }

    /// A stable palette colour for any other value.
    static func hashed(_ name: String) -> Color {
        var hash: UInt64 = 1469598103934665603
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return clusters[Int(hash % UInt64(clusters.count))]
    }

    static func color(for node: GraphNode, mode: GraphColorMode) -> Color {
        switch mode {
        case .cluster: cluster(node.cluster)
        case .type: type(node.type)
        case .status: status(node.status)
        }
    }

    static let missing = Color(red: 0.85, green: 0.30, blue: 0.30)
}

extension GraphNode {
    /// Screen radius of a note, growing with its incoming links.
    var screenRadius: CGFloat {
        min(11, 2.5 + 1.2 * log2(1 + CGFloat(weight)))
    }

    /// Which notes are named first: the most linked, but concepts and
    /// questions before entities and sources, whose titles are long and
    /// many (wiki-lens names clusters and landmarks the same way).
    var labelPriority: Double {
        let factor: Double = switch type {
        case "concept": 4
        case "question": 3
        case "entity": 1.2
        case "source": 0.5
        default: 1
        }
        return Double(weight + 1) * factor
    }

    /// "type · status", or nil if it has neither.
    var kindDescription: String? {
        let parts = [type, status].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
