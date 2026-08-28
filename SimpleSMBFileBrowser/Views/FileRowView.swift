import SwiftUI

/// One row in the list view.
struct FileRowView: View {
    let item: FileItem
    let isSelected: Bool
    /// True while the pane is in multi-select mode.
    var isSelecting: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                // An explicit indicator rather than relying on the List's own
                // highlight: selection is driven by a tap gesture so it behaves
                // the same on iOS and macOS, and the row has to show that state
                // itself.
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .transition(.scale.combined(with: .opacity))
            }
            Image(systemName: item.symbolName)
                .font(.title3)
                .foregroundStyle(item.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = detailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Size and date on one line. Dynamic Type can make this wrap, which is
    /// why it's a separate line rather than trailing accessories.
    private var detailText: String? {
        var parts: [String] = []
        if let size = item.formattedSize { parts.append(size) }
        if let date = item.modifiedDate {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var label = item.isDirectory ? "Folder, \(item.name)" : item.name
        if let detail = detailText { label += ", \(detail)" }
        return label
    }
}

/// One cell in the grid/icon view.
struct FileGridCell: View {
    let item: FileItem
    let isSelected: Bool

    /// Scales the icon with Dynamic Type instead of pinning it to 34pt.
    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title) private var iconHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: item.symbolName)
                .font(.system(size: iconSize))
                .foregroundStyle(item.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(height: iconHeight)

            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if let size = item.formattedSize {
                Text(size)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(minHeight: iconHeight * 2.7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.isDirectory ? "Folder, \(item.name)" : item.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
