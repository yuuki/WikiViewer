//
//  RequestInbox.swift
//  IndexerCore
//
//  The folder requests from the app wait in (HostRequest), and the checks
//  `wikiindex serve` applies before putting one there. A folder transport
//  (iCloud Drive) has the app write into `<publish>/inbox/` directly; over
//  HTTP the server writes there on its behalf. Either way the inbox is
//  outside the vault, and `wikiindex requests` is the only reader.
//

import Foundation
import WikiShared

public final class RequestInbox: Sendable {
    public let directory: URL
    private let token: String

    /// Shortest token accepted, so a guessable one is never configured.
    public static let minimumTokenLength = 16

    public init(directory: URL, token: String) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= Self.minimumTokenLength else {
            throw IndexerError.invalidConfiguration("the request token must be at least \(Self.minimumTokenLength) characters")
        }
        self.directory = directory
        self.token = token
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Reads the token from a file, which must not be readable by others.
    public static func token(fromFile url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 != 0 {
            throw IndexerError.invalidConfiguration("\(url.path) is readable by other users; chmod 600 it")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Constant-time comparison of `Bearer <token>`.
    public func authorize(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let given = Array(header.dropFirst(7).trimmingCharacters(in: .whitespaces).utf8)
        let expected = Array(token.utf8)
        var difference = UInt8(given.count == expected.count ? 0 : 1)
        for i in 0..<expected.count {
            difference |= expected[i] ^ (i < given.count ? given[i] : 0)
        }
        return difference == 0
    }

    public enum Acceptance: Equatable {
        case accepted, invalid, failed
    }

    /// Validates a request and writes it to the inbox (atomically). A
    /// request already there is accepted again without rewriting it, so the
    /// app may retry a send whose answer it never saw.
    public func accept(_ body: Data) -> Acceptance {
        guard let request = try? HostRequest.decode(body) else { return .invalid }
        let file = directory.appendingPathComponent(request.fileName)
        if FileManager.default.fileExists(atPath: file.path) { return .accepted }
        do {
            try Self.writeAtomically(body, to: file)
            Log.info("request \(request.id.uuidString.lowercased()) (\(request.kind.rawValue)) queued")
            return .accepted
        } catch {
            Log.warning("request inbox: \(error)")
            return .failed
        }
    }

    /// Writes a temporary file next to `url` and renames it into place, so
    /// a reader never sees a partial file.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary.path, url.path) != 0 {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
