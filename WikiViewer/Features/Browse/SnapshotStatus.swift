//
//  SnapshotStatus.swift
//  WikiViewer
//
//  How current the open snapshot is, shown where the reader starts rather
//  than only in Settings, so stale content is never silent.
//

import SwiftUI
import WikiViewerKit

/// One line for the Files tab's subtitle: updating, or the snapshot's age.
struct SnapshotFreshness {
    let status: Library.UpdateStatus
    let published: Date?

    func text(now: Date) -> Text? {
        switch status {
        case .checking:
            return Text("Checking for updates…")
        case .downloading:
            return Text("Updating…")
        default:
            guard let published else { return nil }
            let age = published.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
            return Text("Snapshot from \(age)")
        }
    }
}

/// Shown at the top of the Files tab while the last update failed.
struct UpdateFailureBanner: View {
    let message: String
    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            Button {
                app.showSettings()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Couldn't Update")
                            .font(.subheadline.weight(.semibold))
                        Text("Showing the last downloaded snapshot. \(message)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens update settings"))
        }
    }
}

/// Shown at the top of the Files tab while the bundled demo is the source,
/// so the demo is never mistaken for the reader's own vault. One row, like
/// the update failure banner, so the vault stays on the first screen.
struct DemoVaultBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            Button {
                app.showSettings()
            } label: {
                HStack {
                    // A label, so the text lines up with the rows below.
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Demo Vault")
                                .font(.subheadline.weight(.semibold))
                            Text("Connect Your Vault")
                                .font(.footnote)
                                .foregroundStyle(.tint)
                        }
                    } icon: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.tint)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens update settings"))
        }
    }
}
