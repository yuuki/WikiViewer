import CoreGraphics
import Foundation
import Testing
@testable import WikiViewerKit

@Suite struct MermaidTests {
    /// 7 pt per character, 16 pt per line.
    static func measure(_ text: String) -> CGSize {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return CGSize(width: CGFloat(lines.map(\.count).max() ?? 0) * 7, height: CGFloat(lines.count) * 16)
    }

    func layout(_ source: String) throws -> MermaidLayout {
        let chart = try #require(MermaidFlowchart(source: source))
        return MermaidLayout(chart: chart, fontSize: 14, measure: Self.measure)
    }

    @Test func nodesShapesAndLabels() throws {
        let chart = try #require(MermaidFlowchart(source: """
        flowchart LR
            A[Start] --> B{Decision}
            B -->|Yes| C(("Round<br>two"))
            B -- No --> D[(Database)]
            C -.-> E([Stadium]) ==> F{{Hex}}
            D --- G>"Flag"]:::warn
            %% a comment
            style A fill:#f9f
            classDef warn fill:#f00
        """))
        #expect(chart.direction == .right)
        #expect(chart.nodes.map(\.id) == ["A", "B", "C", "D", "E", "F", "G"])
        #expect(chart.nodes.map(\.shape) == [.rectangle, .rhombus, .circle, .cylinder, .stadium, .hexagon, .asymmetric])
        #expect(chart.nodes[2].label == "Round\ntwo")
        #expect(chart.edges.map(\.label) == [nil, "Yes", "No", nil, nil, nil])
        #expect(chart.edges.map(\.stroke) == [.solid, .solid, .solid, .dotted, .thick, .solid])
        #expect(chart.edges.map(\.head) == [.arrow, .arrow, .arrow, .arrow, .arrow, nil])
        #expect(chart.edges[3].from == "C" && chart.edges[3].to == "E")
        #expect(chart.edges[4].from == "E" && chart.edges[4].to == "F")
    }

    @Test func groupsArrowsAndQuotedEdgeLabels() throws {
        let chart = try #require(MermaidFlowchart(source: """
        graph TD;
            A & B --> C;
            C <--> D
            D --o E
            E --x F
            F -. "wait" .-> G
            G == go ==> H
            user-db --> H
        """))
        #expect(chart.edges.count == 8)
        #expect(chart.edges[0].from == "A" && chart.edges[1].from == "B")
        #expect(chart.edges[2].tail == .arrow && chart.edges[2].head == .arrow)
        #expect(chart.edges[3].head == .circle)
        #expect(chart.edges[4].head == .cross)
        #expect(chart.edges[5].label == "wait" && chart.edges[5].stroke == .dotted)
        #expect(chart.edges[6].label == "go" && chart.edges[6].stroke == .thick)
        #expect(chart.nodes.contains { $0.id == "user-db" })
    }

    @Test func subgraphs() throws {
        let chart = try #require(MermaidFlowchart(source: """
        flowchart TB
            front --> orders
            subgraph Orders
                orders --> db[orders-db]
            end
            subgraph cond["Three conditions"]
                direction LR
                C1 --> C2
                subgraph inner [Inner]
                    C3
                end
            end
            cond --> front
        """))
        #expect(chart.membership["orders"] == "Orders")
        #expect(chart.membership["db"] == "Orders")
        #expect(chart.membership["front"] == nil)
        #expect(chart.membership["C3"] == "inner")
        #expect(chart.subgraphs.map(\.title) == ["Orders", "Three conditions", "Inner"])
        #expect(chart.subgraphs[1].direction == .right)
        #expect(chart.subgraphs[2].parent == "cond")
        // An edge to a subgraph's id ends at the subgraph, not a new node.
        #expect(!chart.nodes.contains { $0.id == "cond" })
    }

    @Test func quotedLabelsSpanLines() throws {
        let chart = try #require(MermaidFlowchart(source: """
        flowchart LR
            m["Metrics:
                - dcgm-exporter"] -->|pull| a["Agent; otel"]
        """))
        #expect(chart.nodes.map(\.label) == ["Metrics:\n- dcgm-exporter", "Agent; otel"])
        #expect(chart.edges.count == 1)
    }

    @Test func otherDiagramsAndBrokenSyntaxAreNotCharts() {
        #expect(MermaidFlowchart(source: "sequenceDiagram\n  A->>B: hi") == nil)
        #expect(MermaidFlowchart(source: "pie\n  \"a\" : 1") == nil)
        #expect(MermaidFlowchart(source: "flowchart XY\n A --> B") == nil)
        #expect(MermaidFlowchart(source: "flowchart TD\n A[unclosed --> B") == nil)
        #expect(MermaidFlowchart(source: "flowchart TD\n subgraph S\n A\n end\n end") == nil)
    }

    @Test func rendererMakesMermaidBlocks() {
        let body = "Before\n\n```mermaid\nflowchart TD\n  A[Hello] --> B[World]\n```\n\n```mermaid\npie\n  \"a\" : 1\n```"
        let rendered = NoteRenderer.render(body: body, noteID: 1, links: [])
        guard rendered.blocks.count == 3, case .mermaid(let chart, let source) = rendered.blocks[1].kind else {
            Issue.record("expected a mermaid block")
            return
        }
        #expect(chart.nodes.count == 2)
        #expect(source.hasPrefix("flowchart TD"))
        #expect(rendered.blocks[1].plainText.contains("Hello"))
        guard case .code(let language, _, _) = rendered.blocks[2].kind else {
            Issue.record("a pie chart stays code")
            return
        }
        #expect(language == "mermaid")
    }

    @Test func layoutKeepsNodesApartAndEdgesOnTheirEnds() throws {
        let layout = try layout("""
        flowchart TB
            A[Start] --> B{Is it?}
            B -->|Yes| C[OK]
            C --> D[Rethink]
            D --> B
            B ---->|No| E[End]
            A --> E
        """)
        #expect(layout.nodes.count == 5)
        for (i, a) in layout.nodes.enumerated() {
            for b in layout.nodes[(i + 1)...] {
                #expect(!a.frame.intersects(b.frame), "\(a.label) overlaps \(b.label)")
            }
        }
        let bounds = CGRect(origin: .zero, size: layout.size)
        for node in layout.nodes { #expect(bounds.contains(node.frame)) }
        // Top to bottom: Start above the decision above OK.
        let y = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.label, $0.frame.midY) })
        #expect(y["Start"]! < y["Is it?"]!)
        #expect(y["Is it?"]! < y["OK"]!)
        for edge in layout.edges {
            #expect(edge.points.count >= 2)
            if let label = edge.labelFrame {
                for node in layout.nodes { #expect(!label.intersects(node.frame), "label \(edge.label ?? "") on \(node.label)") }
            }
        }
        // The back edge D → B still starts at D and ends at B.
        let back = try #require(layout.edges.first { edge in
            let start = edge.points.first!, end = edge.points.last!
            let d = layout.nodes.first { $0.label == "Rethink" }!.frame.insetBy(dx: -1, dy: -1)
            let b = layout.nodes.first { $0.label == "Is it?" }!.frame.insetBy(dx: -1, dy: -1)
            return d.contains(start) && b.contains(end)
        })
        #expect(back.head == .arrow)
    }

    @Test func layoutDirectionsAndClusters() throws {
        let layout = try layout("""
        flowchart LR
            X --> S1
            subgraph G [Group]
                direction TB
                S1 --> S2
            end
            G --> Y
        """)
        let frame = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.label, $0.frame) })
        let cluster = try #require(layout.clusters.first)
        #expect(cluster.title == "Group")
        #expect(cluster.frame.contains(frame["S1"]!) && cluster.frame.contains(frame["S2"]!))
        #expect(!cluster.frame.intersects(frame["X"]!) && !cluster.frame.intersects(frame["Y"]!))
        // Left to right outside, top to bottom inside the group.
        #expect(frame["X"]!.maxX < cluster.frame.minX && cluster.frame.maxX < frame["Y"]!.minX)
        #expect(frame["S1"]!.maxY < frame["S2"]!.minY)
    }
}
