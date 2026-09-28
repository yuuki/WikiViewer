//
//  EmbedView.swift
//  WikiViewer
//
//  ![[image.png]] and ![[note]] embeds. Images are fetched lazily and
//  decoded at display size; embedded notes are loaded when they scroll into
//  view and render one level deep (their own embeds become links).
//

import SwiftUI
import WikiShared
import WikiViewerKit

struct EmbedView: View {
    let target: EmbedTarget

    var body: some View {
        switch target {
        case .asset(let id, let name, let sizeSpec):
            AssetEmbedView(assetID: id, name: name, sizeSpec: sizeSpec)
        case .note(let id, let title, let heading, let blockID):
            NoteEmbedView(noteID: id, title: title, heading: heading, blockID: blockID)
        case .missing(let raw):
            Label("Missing embed: \(raw)", systemImage: "questionmark.square.dashed")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct AssetEmbedView: View {
    let assetID: Int64
    let name: String
    let sizeSpec: String?
    @Environment(Library.self) private var library
    @Environment(\.displayScale) private var displayScale
    @Environment(\.embeddedAssets) private var embeddedAssets
    @State private var loadedAsset: AssetInfo?
    @State private var image: CGImage?
    @State private var failure: String?
    @State private var availableWidth: CGFloat = 0
    @State private var viewing: AssetInfo?

    /// `|300` or `|300x200` from the embed.
    var requestedWidth: CGFloat? {
        guard let spec = sizeSpec, let w = Double(spec.split(separator: "x").first ?? "") else { return nil }
        return CGFloat(w)
    }

    /// Known before `load()` when the note prefetched its embedded assets.
    var asset: AssetInfo? { loadedAsset ?? embeddedAssets[assetID] }

    /// Width cap shared by the image and its placeholder: the requested
    /// width, but never wider than the image itself.
    func maxWidth(pixelWidth: Int) -> CGFloat {
        min(requestedWidth ?? .infinity, CGFloat(pixelWidth) / displayScale)
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 6))
                    .frame(maxWidth: maxWidth(pixelWidth: asset?.width ?? image.width))
                    .accessibilityLabel(name)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("Opens the image full screen"))
                    .onTapGesture { viewing = asset }
            } else if let asset, asset.kind == .base {
                // ![[x.base]]: a link to the base's own screen.
                NavigationLink(value: Route.base(path: asset.path)) {
                    AttachmentRow(asset: asset, note: nil)
                }
                .buttonStyle(.plain)
            } else if let asset, asset.kind != .image || asset.blobSHA256 == nil || failure != nil {
                Button { viewing = asset } label: {
                    AttachmentRow(asset: asset, note: failure)
                }
                .buttonStyle(.plain)
            } else {
                // Sized like the image it stands for: the row keeps its height
                // while the image loads and after it is dropped off-screen.
                // Otherwise a row above the scroll anchor that changes height
                // shifts the scroll offset, and one at the edge of the screen
                // can flip between the two sizes, appearing and disappearing.
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: asset?.width.map { maxWidth(pixelWidth: $0) } ?? requestedWidth)
                    .overlay { ProgressView() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .task(id: TaskKey(session: library.session?.id, width: availableWidth > 0)) {
            await load()
        }
        // LazyVStack keeps the state of rows it has built; drop the bitmap
        // when the row leaves the screen (the byte-bounded cache may keep a
        // copy, and `.task` reloads it on reappear).
        .onDisappear { image = nil }
        .fullScreenCover(item: $viewing) { AssetViewer(asset: $0) }
    }

    struct TaskKey: Hashable {
        var session: String?
        var width: Bool
    }

    var aspectRatio: CGFloat {
        guard let w = asset?.width, let h = asset?.height, w > 0, h > 0 else { return 4.0 / 3.0 }
        return CGFloat(w) / CGFloat(h)
    }

    func load() async {
        guard let session = library.session, availableWidth > 0 else { return }
        do {
            var found = asset
            if found == nil { found = try await session.assets.asset(id: assetID) }
            guard let info = found else { return }
            loadedAsset = info
            guard info.kind == .image, let sha = info.blobSHA256 else { return }
            let points = min(requestedWidth ?? availableWidth, availableWidth)
            let maxPixels = min(Int(points * displayScale), 2048)
            let key = ImageCache.Key(sha256: sha, maxPixelSize: maxPixels)
            if let cached = library.imageCache.image(for: key) {
                image = cached
                return
            }
            let url = try await library.blobURL(for: info)
            guard let decoded = await ImageDownsampler.downsampleInBackground(at: url, maxPixelSize: maxPixels) else {
                failure = "Could not decode image"
                return
            }
            library.imageCache.insert(decoded, for: key)
            image = decoded
        } catch is CancellationError {
            return
        } catch {
            failure = "Not available offline"
        }
    }
}

extension EnvironmentValues {
    /// A note's embedded assets by id, prefetched with the note.
    @Entry var embeddedAssets: [Int64: AssetInfo] = [:]
}

struct AttachmentRow: View {
    let asset: AssetInfo
    let note: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name).font(.subheadline)
                Text([ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file), note ?? placeholder].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: BlockView.cornerRadius))
    }

    var symbol: String { Self.symbol(for: asset.kind) }

    static func symbol(for kind: ViewerSchema.AssetKind) -> String {
        switch kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .audio: "waveform"
        case .video: "film"
        case .other: "doc"
        case .base: "tablecells"
        }
    }

    var placeholder: String? {
        switch asset.kind {
        case .image: asset.blobSHA256 == nil ? "Not included in snapshot" : nil
        case .base: String(localized: "Base")
        default: "Preview not supported yet"
        }
    }
}

struct NoteEmbedView: View {
    let noteID: Int64
    let title: String
    let heading: String?
    let blockID: String?
    @Environment(Library.self) private var library
    @State private var path: String?
    @State private var rendered: RenderedNote?

    /// Upper bound on embedded text loaded into memory.
    static let maxCharacters = 32_000

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let path {
                NavigationLink(value: Route.note(path: path, anchor: heading != nil || blockID != nil ? Anchor(heading: heading, blockID: blockID) : nil)) {
                    Label(title + (heading.map { " › \($0)" } ?? ""), systemImage: "arrow.turn.down.right")
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if let rendered {
                ForEach(rendered.blocks) { BlockView(block: $0) }
            } else {
                ProgressView()
            }
        }
        // A card, unlike the bar of a quote or callout: this is another note.
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: BlockView.cornerRadius).strokeBorder(.separator)
        }
        .environment(\.headingLevelOffset, 2)
        .onDisappear { rendered = nil }
        .task(id: library.session?.id) {
            guard let session = library.session else { return }
            path = try? await session.notes.summary(id: noteID)?.path
            guard let body = try? await session.notes.bodyPrefix(id: noteID, maxCharacters: Self.maxCharacters) else { return }
            let links = (try? await session.links.outgoingLinks(of: noteID)) ?? []
            let excerpt = await NoteRenderer.excerptInBackground(body: body, heading: heading, blockID: blockID)
            rendered = await NoteRenderer.renderInBackground(body: excerpt, noteID: noteID, links: links, allowEmbeds: false)
        }
    }
}
