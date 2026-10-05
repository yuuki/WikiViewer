//
//  SettingsView.swift
//  WikiViewer
//
//  Where notes come from and how current they are first; snapshot
//  internals and diagnostics one level down.
//

import SwiftUI
import UniformTypeIdentifiers
import WikiViewerKit

struct SettingsView: View {
    @Environment(Library.self) private var library
    @State private var pickingFolder = false
    @State private var httpURL = ""
    @State private var folderError: String?
    @State private var showsURLError = false
    @AppStorage(ObsidianLink.vaultNameKey) private var obsidianVaultName = ""
    @State private var requestToken = RequestToken.load() ?? ""
    #if os(macOS)
    @AppStorage(NoteTextScale.defaultsKey) private var noteTextScale = 1.0
    #endif

    var body: some View {
        Form {
            Section {
                LabeledContent("Source", value: Self.sourceLabel(library.source))
                if let published = library.session?.info.createdDate {
                    LabeledContent("Snapshot") {
                        Text(published, format: .relative(presentation: .named))
                    }
                }
                statusRow
                Button("Check for Updates") {
                    Task { await library.checkForUpdates() }
                }
                .disabled(library.source == nil || library.updateStatus == .checking)
            } header: {
                Text("Updates")
            } footer: {
                Text("While the app is open it follows the source and switches to each new snapshot once it is downloaded and verified.")
            }

            Section {
                Button("Choose Folder…", systemImage: "folder") { pickingFolder = true }
                if let folderError { Text(folderError).font(.footnote).foregroundStyle(.red) }
                // A label, so the field lines up with Choose Folder above it.
                Label {
                    HStack {
                        TextField("Address", text: $httpURL, prompt: Text(verbatim: "https://host/publish"))
                            .labelsHidden()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            #endif
                            .autocorrectionDisabled()
                            .onSubmit(useHTTPSource)
                        Button("Use", action: useHTTPSource)
                            .disabled(httpURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } icon: {
                    Image(systemName: "globe")
                        .foregroundStyle(.tint)
                }
                // Only after the address is submitted: an address being typed
                // is not yet wrong.
                if showsURLError {
                    Text("Enter an address starting with https:// (or http://) and a host name.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Update Source")
            } footer: {
                #if os(macOS)
                Text("A folder can be the directory wikiindex publishes into on this Mac, or an iCloud Drive folder another Mac publishes into. An address points at a published directory served over HTTPS.")
                #else
                Text("A folder can be any location in the Files app, including an iCloud Drive folder your Mac publishes into. An address points at a published directory served over HTTPS.")
                #endif
            }

            #if os(macOS)
            Section {
                Picker("Text Size", selection: $noteTextScale) {
                    ForEach(NoteTextScale.steps, id: \.self) { step in
                        Text(step.formatted(.percent.precision(.fractionLength(0)))).tag(step)
                    }
                }
            } header: {
                Text("Reading")
            } footer: {
                Text("The size of note text. View > Bigger (⌘=) and Smaller (⌘-) change it too.")
            }
            #endif

            Section {
                if case .http = library.source {
                    LabeledContent("Request token") {
                        SecureField("Request token", text: $requestToken, prompt: Text("From --token-file"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                    }
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit { library.setRequestToken(requestToken) }
                        .onDisappear { library.setRequestToken(requestToken) }
                }
                NavigationLink("Requests") { RequestsView() }
            } header: {
                Text("Requests to Claude")
            } footer: {
                Text(requestsFooter)
            }

            ReadingHistorySettings()

            Section {
                TextField("Vault name", text: $obsidianVaultName)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            } header: {
                Text("Obsidian")
            } footer: {
                Text("The vault's name as shown in Obsidian. Used by Edit in Obsidian and shared links.")
            }

            Section {
                NavigationLink("Snapshot and Storage") { SnapshotDetailsView() }
            }
        }
        .navigationTitle("Settings")
        .onChange(of: httpURL) { showsURLError = false }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            chooseFolder(result)
        }
    }

    private var requestsFooter: String {
        switch library.source {
        case .http: String(localized: "Questions about notes go to the Mac through wikiindex serve, which needs this token (its --token-file). Answers arrive as notes.")
        case .folder: String(localized: "Questions about notes are written to the inbox folder inside the update folder, where wikiindex requests on the Mac picks them up. Answers arrive as notes.")
        default: String(localized: "Connect your vault's folder or address to ask Claude on your Mac about notes.")
        }
    }

    @ViewBuilder
    var statusRow: some View {
        switch library.updateStatus {
        case .idle: EmptyView()
        case .checking: LabeledContent("Status") { ProgressView() }
        case .downloading(let gen): LabeledContent("Status", value: String(localized: "Downloading generation \(gen)…"))
        case .upToDate(let date): LabeledContent("Status", value: String(localized: "Up to date (\(date.formatted(date: .omitted, time: .shortened)))"))
        case .updated(let gen, let date): LabeledContent("Status", value: String(localized: "Updated to \(gen) at \(date.formatted(date: .omitted, time: .shortened))"))
        case .failed(let message):
            VStack(alignment: .leading) {
                Text("Last update failed").foregroundStyle(.red)
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    static func sourceLabel(_ source: SourceConfiguration?) -> String {
        switch source {
        case nil: String(localized: "None")
        case .folder(_, let name): String(localized: "Folder: \(name)")
        case .http(let url): url.host() ?? url.absoluteString
        case .bundledDemo: String(localized: "Demo vault")
        }
    }

    /// An http(s) URL with a host, or nil.
    static func validSourceURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    func useHTTPSource() {
        guard let url = Self.validSourceURL(httpURL) else {
            showsURLError = true
            return
        }
        showsURLError = false
        library.setSource(.http(url))
        Task { await library.checkForUpdates() }
    }

    func chooseFolder(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let bookmark = try url.bookmarkData(options: SourceConfiguration.bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            library.setSource(.folder(bookmark: bookmark, displayName: url.lastPathComponent))
            folderError = nil
            Task { await library.checkForUpdates() }
        } catch {
            folderError = error.localizedDescription
        }
    }
}

/// Snapshot internals, diagnostics and the destructive or demo actions,
/// kept off the main settings screen.
struct SnapshotDetailsView: View {
    @Environment(Library.self) private var library
    @State private var diskUsage: Int64?
    @State private var footprint: UInt64?
    @State private var confirmReset = false
    @State private var confirmDemo = false

    var body: some View {
        Form {
            Section("Snapshot") {
                if let info = library.session?.info {
                    LabeledContent("Generation", value: "\(info.generation)")
                    LabeledContent("Published", value: info.createdDate?.formatted(date: .abbreviated, time: .shortened) ?? info.createdAt)
                    LabeledContent("Notes", value: info.noteCount.formatted())
                    LabeledContent("Image blobs", value: info.assetCount.formatted())
                    LabeledContent("Schema", value: "v\(info.schemaVersion)")
                    LabeledContent("Builder", value: info.builder)
                } else {
                    Text("No snapshot installed").foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Memory footprint", value: footprint.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "—")
                LabeledContent("Local storage", value: diskUsage.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                LabeledContent("Decoded image cache", value: ByteCountFormatter.string(fromByteCount: Int64(library.imageCache.totalBytes), countStyle: .memory))
                Button("Refresh") { Task { await refreshDiagnostics() } }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Snapshots are verified (size, SHA-256, SQLite integrity) before the app switches to them; the previous one is kept as a fallback.")
            }

            Section {
                Button("Use Demo Vault…") { confirmDemo = true }
                    .disabled(library.source == .bundledDemo)
                Button("Delete Local Snapshots…", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("Snapshot and Storage")
        .inlineNavigationTitle()
        .task { await refreshDiagnostics() }
        .confirmationDialog("Switch to the demo vault? Your update source is replaced; choose it again to switch back.", isPresented: $confirmDemo, titleVisibility: .visible) {
            Button("Use Demo Vault") {
                library.setSource(.bundledDemo)
                Task { await library.checkForUpdates() }
            }
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

    func refreshDiagnostics() async {
        footprint = MemoryDiagnostics.physicalFootprint()
        diskUsage = await library.store.diskUsageInBackground()
    }
}
