import Foundation
import Testing
@testable import WikiViewerKit

@Suite struct NavigationHistoryTests {
    @Test func backAndForwardRestoreTheSameEntries() {
        var history = NavigationHistory<Int>()
        history.push(1)
        history.push(2)
        history.push(3)
        history.back()
        history.back()
        #expect(history.path == [1])
        #expect(history.canGoForward)
        history.forward()
        #expect(history.path == [1, 2])
        history.forward()
        #expect(history.path == [1, 2, 3])
        #expect(!history.canGoForward)
    }

    @Test func openingSomethingNewDropsWhatWasAhead() {
        var history = NavigationHistory<Int>()
        history.push(1)
        history.push(2)
        history.back()
        history.push(9)
        #expect(history.path == [1, 9])
        #expect(!history.canGoForward)
    }

    @Test func backOnAnEmptyPathDoesNothing() {
        var history = NavigationHistory<Int>()
        history.back()
        history.forward()
        #expect(history.path.isEmpty)
        #expect(!history.canGoBack)
    }

    @Test func replacingTheTopKeepsTheEntriesBelow() {
        var history = NavigationHistory<Int>()
        history.replaceTop(with: 1)
        #expect(history.path == [1])
        history.push(2)
        history.back()
        history.replaceTop(with: 5)
        #expect(history.path == [5])
        #expect(!history.canGoForward)
    }

    @Test func depthIsBoundedByDroppingTheOldest() {
        var history = NavigationHistory<Int>(maxDepth: 3)
        for i in 1...5 { history.push(i) }
        #expect(history.path == [3, 4, 5])
    }

    @Test func aShorterPrefixSetFromOutsideIsGoingBack() {
        var history = NavigationHistory<Int>()
        history.setPath([1, 2, 3])
        history.setPath([1])
        #expect(history.path == [1])
        history.forward()
        history.forward()
        #expect(history.path == [1, 2, 3])
    }

    @Test func anyOtherPathSetFromOutsideIsNew() {
        var history = NavigationHistory<Int>()
        history.setPath([1, 2])
        history.back()
        history.setPath([7, 8])
        #expect(history.path == [7, 8])
        #expect(!history.canGoForward)
    }

    @Test func settingTheSamePathKeepsTheForwardEntries() {
        var history = NavigationHistory<Int>()
        history.push(1)
        history.push(2)
        history.back()
        history.setPath([1])
        #expect(history.canGoForward)
    }
}

@Suite struct RouteDispatchTests {
    let note = Route.note(path: "a/b.md", anchor: nil)

    @Test func documentsOpenInTheDetailColumnFromAnywhere() {
        for origin in [RouteDispatch.Origin.list, .document] {
            #expect(RouteDispatch.dispatch(note, from: origin) == .openDocument(note))
            #expect(RouteDispatch.dispatch(.graphCluster(id: 3, focus: nil), from: origin) == .openDocument(.graphCluster(id: 3, focus: nil)))
            #expect(RouteDispatch.dispatch(.base(path: "x.base"), from: origin) == .openDocument(.base(path: "x.base")))
        }
    }

    @Test func listsOpenedFromAListStackUpInItsSection() {
        #expect(RouteDispatch.dispatch(.folder(path: "a/b"), from: .list) == .pushList(.folder(path: "a/b")))
        #expect(RouteDispatch.dispatch(.tag(name: "x"), from: .list) == .pushList(.tag(name: "x")))
    }

    @Test func listsOpenedFromADocumentSwitchSection() {
        #expect(RouteDispatch.dispatch(.folder(path: "a/b"), from: .document)
                == .showList(.files, [.folder(path: "a"), .folder(path: "a/b")]))
        #expect(RouteDispatch.dispatch(.tag(name: "p/q"), from: .document) == .showList(.tags, [.tag(name: "p/q")]))
        #expect(RouteDispatch.dispatch(.tags, from: .document) == .showList(.tags, []))
        #expect(RouteDispatch.dispatch(.recents, from: .document) == .showList(.files, [.recents]))
        #expect(RouteDispatch.dispatch(.search, from: .document) == .showList(.search, []))
    }

    @Test func folderChainWalksUpToTheRoot() {
        #expect(Route.folderChain("") == [])
        #expect(Route.folderChain("a") == [.folder(path: "a")])
        #expect(Route.folderChain("a/b/c") == [.folder(path: "a"), .folder(path: "a/b"), .folder(path: "a/b/c")])
    }

    @Test func listsAndDocumentsAreTold() {
        #expect(Route.folder(path: "").isList)
        #expect(Route.search.isList)
        #expect(!Route.graph.isList)
        #expect(!Route.missing(target: "x").isList)
    }

    @Test func routesKeepTheirEncoding() throws {
        // Saved window state must decode after the type moved modules.
        let json = #"[{"note":{"path":"a.md","anchor":{"text":"q"}}},{"folder":{"path":"x"}}]"#
        let routes = try JSONDecoder().decode([Route].self, from: Data(json.utf8))
        #expect(routes == [.note(path: "a.md", anchor: NoteAnchor(text: "q")), .folder(path: "x")])
    }
}
