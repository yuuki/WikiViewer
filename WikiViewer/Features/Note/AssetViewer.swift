//
//  AssetViewer.swift
//  WikiViewer
//
//  Full-screen view of one attachment: images zoom and pan and can be
//  shared; other kinds say why there is no preview.
//

import SwiftUI
import WikiShared
import WikiViewerKit

struct AssetViewer: View {
    let asset: AssetInfo
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var shareURL: URL?
    @State private var failure: String?

    /// Enough pixels to zoom in about 2× on a large screen, bounded so a huge
    /// photo never becomes a huge bitmap.
    static let maxPixelSize = 4096

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ZoomableImage(image: image, scale: displayScale, label: asset.name)
                } else if canPreview, failure == nil {
                    ProgressView()
                } else {
                    ContentUnavailableView {
                        Label(asset.name, systemImage: AttachmentRow.symbol(for: asset.kind))
                    } description: {
                        Text(failure ?? unavailableReason)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(image == nil ? Color.platformBackground : .black)
            .navigationTitle(asset.name)
            .inlineNavigationTitle()
            #if os(iOS)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(image == nil ? nil : .dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                if let shareURL {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: shareURL)
                    }
                }
            }
        }
        .task { await load() }
    }

    private var canPreview: Bool { Self.canPreview(asset) }

    /// An image whose downsized copy is in the snapshot.
    static func canPreview(_ asset: AssetInfo) -> Bool {
        asset.kind == .image && asset.blobSHA256 != nil
    }

    private var unavailableReason: String {
        let size = ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)
        if asset.kind == .image {
            return String(localized: "\(size) · Not included in the snapshot")
        }
        return String(localized: "\(size) · This file type can't be previewed")
    }

    private func load() async {
        guard canPreview else { return }
        do {
            let url = try await library.blobURL(for: asset)
            guard let decoded = await ImageDownsampler.downsampleInBackground(at: url, maxPixelSize: Self.maxPixelSize) else {
                failure = String(localized: "Could not decode image")
                return
            }
            image = decoded
            shareURL = Self.namedCopy(of: url, for: asset)
        } catch is CancellationError {
        } catch {
            failure = String(localized: "Not available offline")
        }
    }

    /// Blobs are named by their hash; share (or preview) a copy under the
    /// vault's name, with the extension of the blob's own format (the
    /// snapshot may hold a downsized JPEG of a HEIC photo).
    static func namedCopy(of url: URL, for asset: AssetInfo) -> URL? {
        var name = asset.name
        if let blobExt = asset.blobExt, !blobExt.isEmpty {
            name = (name as NSString).deletingPathExtension + "." + blobExt
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
        let target = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            return url
        }
    }
}

/// Pinch to zoom, drag to pan, double-tap to toggle 2×.
struct ZoomableImage: View {
    let image: CGImage
    let scale: CGFloat
    let label: String
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    static let maxZoom: CGFloat = 6

    var body: some View {
        Image(decorative: image, scale: scale)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .scaleEffect(zoom)
            .offset(offset)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isImage)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        zoom = min(max(committedZoom * value.magnification, 1), Self.maxZoom)
                    }
                    .onEnded { _ in
                        committedZoom = zoom
                        if zoom == 1 { resetPan() }
                    }
                    .simultaneously(with: DragGesture()
                        .onChanged { value in
                            guard zoom > 1 else { return }
                            offset = CGSize(width: committedOffset.width + value.translation.width,
                                            height: committedOffset.height + value.translation.height)
                        }
                        .onEnded { _ in committedOffset = offset })
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(duration: 0.3)) {
                    if zoom > 1 {
                        zoom = 1
                        committedZoom = 1
                        resetPan()
                    } else {
                        zoom = 2
                        committedZoom = 2
                    }
                }
            }
    }

    private func resetPan() {
        offset = .zero
        committedOffset = .zero
    }
}
