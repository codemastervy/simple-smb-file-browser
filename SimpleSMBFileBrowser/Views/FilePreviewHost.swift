import SwiftUI
import QuickLook

/// Hosts QuickLook for the currently previewed file, plus the progress and
/// error surfaces around preparing it.
///
/// `quickLookPreview` works on both iOS and macOS, so no platform-specific
/// representable is needed here.
struct FilePreviewHost: ViewModifier {
    @Bindable var preview: PreviewCoordinator

    @State private var previewURL: URL?

    func body(content: Content) -> some View {
        content
            .quickLookPreview($previewURL)
            .onChange(of: preview.request?.id) { _, _ in
                previewURL = preview.request?.url
            }
            .onChange(of: previewURL) { _, newValue in
                // QuickLook clears the binding when the user closes it; that's
                // the signal to clean up the staged temporary file.
                if newValue == nil, preview.request != nil {
                    preview.dismiss()
                }
            }
            .overlay(alignment: .bottom) {
                if preview.isPreparing { preparingBanner }
            }
            .alert(
                preview.failure?.title ?? "Couldn't Open File",
                isPresented: Binding(
                    get: { preview.failure != nil },
                    set: { if !$0 { preview.clearFailure() } }
                )
            ) {
                Button("OK", role: .cancel) { preview.clearFailure() }
            } message: {
                Text(preview.failure?.message ?? "")
            }
    }

    private var preparingBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Preparing preview")
                    .font(.footnote.weight(.medium))
                if let name = preview.preparingItemName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Cancel") { preview.cancel() }
                .font(.footnote)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassPanel()
        .softDepth()
        .padding(16)
        .accessibilityIdentifier("preview.preparing")
    }
}

extension View {
    func filePreview(_ preview: PreviewCoordinator) -> some View {
        modifier(FilePreviewHost(preview: preview))
    }
}
