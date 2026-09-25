//
//  Diagnostics.swift
//  WikiViewerKit
//

import CoreGraphics
import Darwin
import Foundation

public enum MemoryDiagnostics {
    /// The process's physical footprint in bytes — the number Jetsam uses
    /// (same as Xcode's memory gauge). nil if unavailable.
    public static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

extension NoteRenderer {
    /// Renders off the caller's actor (never on the main thread).
    @concurrent
    public static func renderInBackground(body: String, noteID: Int64, links: [OutgoingLink], allowEmbeds: Bool = true) async -> RenderedNote {
        render(body: body, noteID: noteID, links: links, allowEmbeds: allowEmbeds)
    }

    @concurrent
    public static func excerptInBackground(body: String, heading: String?, blockID: String?) async -> String {
        excerpt(body: body, heading: heading, blockID: blockID)
    }
}

extension ImageDownsampler {
    /// Decodes off the caller's actor.
    @concurrent
    public static func downsampleInBackground(at url: URL, maxPixelSize: Int) async -> CGImage? {
        downsample(at: url, maxPixelSize: maxPixelSize)
    }
}
