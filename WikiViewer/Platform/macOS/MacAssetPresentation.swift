//
//  MacAssetPresentation.swift
//  WikiViewer
//
//  Attachments on macOS: an image in the snapshot opens in Quick Look
//  (zoom, full screen and sharing come from the system); anything else
//  opens AssetViewer in a sheet, which says why there is no preview.
//

#if os(macOS)
import QuickLook
import SwiftUI
import WikiViewerKit

struct MacAssetPresentation: ViewModifier {
    @Binding var item: AssetInfo?
    @Environment(Library.self) private var library
    @State private var pending: AssetInfo?
    @State private var previewURL: URL?
    @State private var sheetAsset: AssetInfo?

    func body(content: Content) -> some View {
        content
            .quickLookPreview($previewURL)
            .sheet(item: $sheetAsset) { asset in
                AssetViewer(asset: asset)
                    .frame(minWidth: 420, minHeight: 300)
            }
            // Hand the request over at once, so the same attachment can be
            // opened again after Quick Look closes.
            .onChange(of: item) {
                guard let item else { return }
                pending = item
                self.item = nil
            }
            .task(id: pending) {
                guard let asset = pending else { return }
                if AssetViewer.canPreview(asset), let url = try? await library.blobURL(for: asset) {
                    previewURL = AssetViewer.namedCopy(of: url, for: asset)
                } else if !Task.isCancelled {
                    sheetAsset = asset
                }
                pending = nil
            }
    }
}
#endif
