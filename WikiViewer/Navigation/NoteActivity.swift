//
//  NoteActivity.swift
//  WikiViewer
//
//  Handoff: the note on screen is offered as a user activity, so the
//  iPhone and the Mac can continue reading it on the other. The note is
//  named by its vault path, which both devices' snapshots share.
//

import Foundation
import WikiViewerKit

enum NoteActivity {
    /// Listed in NSUserActivityTypes (Config/WikiViewer-Info.plist).
    static let type = "app.wikiviewer.note"
    static let pathKey = "path"

    static func describe(_ activity: NSUserActivity, path: String, title: String) {
        activity.title = title
        activity.userInfo = [pathKey: path]
        activity.targetContentIdentifier = path
        activity.isEligibleForHandoff = true
    }

    /// The note an activity continues, if it names one.
    static func route(of activity: NSUserActivity) -> Route? {
        guard let path = activity.userInfo?[pathKey] as? String, !path.isEmpty else { return nil }
        return .note(path: path, anchor: nil)
    }
}
