//
//  NavigationHistory.swift
//  WikiViewerKit
//
//  A stack of screens with browser-like history: going back keeps the
//  screens left for going forward again, until something new is opened.
//

/// The path and what going forward would restore. `path` may also be set
/// directly (a NavigationStack's own back button pops it): a shorter prefix
/// counts as going back, anything else as opening something new.
public struct NavigationHistory<Element: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var path: [Element] = []
    /// Entries to go forward to, the next one last.
    public private(set) var forwardPath: [Element] = []
    /// At most this many entries are kept; the oldest are dropped.
    public let maxDepth: Int

    public init(maxDepth: Int = .max) {
        self.maxDepth = maxDepth
    }

    public var canGoBack: Bool { !path.isEmpty }
    public var canGoForward: Bool { !forwardPath.isEmpty }
    public var top: Element? { path.last }

    public mutating func push(_ element: Element) {
        path.append(element)
        forwardPath.removeAll()
        trim()
    }

    /// Replaces the top entry (or pushes onto an empty path), clearing what
    /// was ahead: for browsing a list, where each selection is not a step
    /// of its own.
    public mutating func replaceTop(with element: Element) {
        if !path.isEmpty { path.removeLast() }
        push(element)
    }

    public mutating func back() {
        guard let element = path.popLast() else { return }
        forwardPath.append(element)
    }

    public mutating func forward() {
        guard let element = forwardPath.popLast() else { return }
        path.append(element)
    }

    /// Takes a path set from outside (a NavigationStack binding, a restored
    /// window).
    public mutating func setPath(_ newPath: [Element]) {
        if newPath.count < path.count, Array(path.prefix(newPath.count)) == newPath {
            forwardPath += path[newPath.count...].reversed()
            path = newPath
        } else if newPath != path {
            path = newPath
            forwardPath.removeAll()
            trim()
        }
    }

    private mutating func trim() {
        if path.count > maxDepth { path.removeFirst(path.count - maxDepth) }
    }
}
