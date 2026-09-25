//
//  WikiURL.swift
//  WikiViewerKit
//
//  In-app link targets carried by rendered text (AttributedString `.link`).
//

import Foundation

public enum WikiLinkAction: Sendable, Equatable {
    case note(id: Int64, heading: String?, blockID: String?)
    case missing(target: String)
    case tag(String)
    case asset(id: Int64)
    case external(URL)

    static let scheme = "wikiviewer"

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .note(let id, let heading, let blockID):
            c.host = "note"
            c.path = "/\(id)"
            var items: [URLQueryItem] = []
            if let heading { items.append(URLQueryItem(name: "h", value: heading)) }
            if let blockID { items.append(URLQueryItem(name: "b", value: blockID)) }
            c.queryItems = items.isEmpty ? nil : items
        case .missing(let target):
            c.host = "missing"
            c.queryItems = [URLQueryItem(name: "t", value: target)]
        case .tag(let name):
            c.host = "tag"
            c.queryItems = [URLQueryItem(name: "n", value: name)]
        case .asset(let id):
            c.host = "asset"
            c.path = "/\(id)"
        case .external(let url):
            return url
        }
        // URLComponents leaves "&", "=", "+" unescaped in query values;
        // encode them so "Q&A" round-trips as one value.
        if let items = c.queryItems {
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+#")
            c.percentEncodedQueryItems = items.map {
                URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: allowed))
            }
        }
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme else {
            guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
            self = .external(url)
            return
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let idString = url.path.split(separator: "/").first.map(String.init)
        switch url.host {
        case "note":
            guard let idString, let id = Int64(idString) else { return nil }
            self = .note(id: id, heading: query["h"], blockID: query["b"])
        case "missing":
            self = .missing(target: query["t"] ?? "")
        case "tag":
            self = .tag(query["n"] ?? "")
        case "asset":
            guard let idString, let id = Int64(idString) else { return nil }
            self = .asset(id: id)
        default:
            return nil
        }
    }
}
