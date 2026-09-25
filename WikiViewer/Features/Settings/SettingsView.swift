//
//  SettingsView.swift
//  WikiViewer
//
//  Snapshot freshness, update source, diagnostics.
//

import SwiftUI
import UniformTypeIdentifiers
import WikiViewerKit

struct SettingsView: View {
    @Environment(Library.self) private var library
    @State private var pickingFolder = false
    @State private var httpURL = ""
    @State private var diskUsage: Int64?
    @State private var footprint: UInt64?
    @State private var confirmReset = false
    @State private var folderError: String?

    var body: some View {
        Form {
            Section("Snapshot") {
                if let info = library.session?.info {
                    LabeledContent("Generation", value: "\(info.generation)")
                    LabeledContent("Published", value: Self.formatDate(info.createdAt))
                    LabeledContent("Notes", value: info.noteCount.formatted())
                    LabeledContent("Image blobs", value: info.assetCount.formatted())
                    LabeledContent("Schema", value: "v\(info.schemaVersion)")
                    LabeledContent("Builder", value: info.builder)
                } else {
                    Text("No snapshot installed").foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Source", value: library.source?.label ?? "None")
                Button("Check for Updates") {
                    Task { await library.checkForUpdates() }
                }
                .disabled(library.source == nil || library.updateStatus == .checking)
                statusRow
            } header: {
                Text("Updates")
            } footer: {
                Text("The viewer downloads immutable snapshots, validates their size, SHA-256 and SQLite integrity, then switches atomically. The previous snapshot is kept as a fallback.")
            }

            Section {
                Button("Choose Folder…") { pickingFolder = true }
                if let folderError { Text(folderError).font(.footnote).foregroundStyle(.red) }
                HStack {
                    TextField("https://host/publish", text: $httpURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Use") {
                        if let url = URL(string: httpURL.trimmingCharacters(in: .whitespaces)), url.scheme == "https" || url.scheme == "http" {
                            library.setSource(.http(url))
                            Task { await library.checkForUpdates() }
                        }
                    }
                    .disabled(URL(string: httpURL)?.scheme == nil)
                }
                Button("Use Bundled Demo") {
                    library.setSource(.bundledDemo)
                    Task { await library.checkForUpdates() }
                }
            } header: {
                Text("Update Source")
            } footer: {
                Text("A folder can be any location in the Files app, including an iCloud Drive folder the Mac mini publishes into. HTTP(S) points at a published directory (manifest.json, generations/, assets/).")
            }

            Section("Diagnostics") {
                LabeledContent("Memory footprint", value: footprint.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "—")
                LabeledContent("Local storage", value: diskUsage.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                LabeledContent("Decoded image cache", value: ByteCountFormatter.string(fromByteCount: Int64(library.imageCache.totalBytes), countStyle: .memory))
                Button("Refresh") { Task { await refreshDiagnostics() } }
                Button("Delete Local Snapshots…", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("Settings")
        .task { await refreshDiagnostics() }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            chooseFolder(result)
        }
        .confirmationDialog("Delete all downloaded snapshots and images on this device? The Obsidian vault is not affected.", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await library.resetLocalData()
                    await refreshDiagnostics()
                }
            }
        }
    }

    @ViewBuilder
    var statusRow: some View {
        switch library.updateStatus {
        case .idle: EmptyView()
        case .checking: LabeledContent("Status") { ProgressView() }
        case .downloading(let gen): LabeledContent("Status", value: "Downloading generation \(gen)…")
        case .upToDate(let date): LabeledContent("Status", value: "Up to date (\(date.formatted(date: .omitted, time: .shortened)))")
        case .updated(let gen, let date): LabeledContent("Status", value: "Updated to \(gen) at \(date.formatted(date: .omitted, time: .shortened))")
        case .failed(let message):
            VStack(alignment: .leading) {
                Text("Last update failed").foregroundStyle(.red)
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    func chooseFolder(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            library.setSource(.folder(bookmark: bookmark, displayName: url.lastPathComponent))
            folderError = nil
            Task { await library.checkForUpdates() }
        } catch {
            folderError = error.localizedDescription
        }
    }

    func refreshDiagnostics() async {
        footprint = MemoryDiagnostics.physicalFootprint()
        diskUsage = await library.store.diskUsageInBackground()
    }

    static func formatDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
