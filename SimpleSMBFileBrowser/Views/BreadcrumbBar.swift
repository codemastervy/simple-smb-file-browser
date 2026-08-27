import SwiftUI

/// Path trail shown on iPad and Mac. iPhone gets a back button instead, since
/// a trail doesn't fit at that width.
struct BreadcrumbBar: View {
    let crumbs: [(title: String, path: String)]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            onSelect(crumb.path)
                        } label: {
                            Text(crumb.title)
                                .font(.callout)
                                .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
                                .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .onChange(of: crumbs.count) { _, newCount in
                // Keep the current directory visible when navigating deeper.
                withAnimation { proxy.scrollTo(newCount - 1, anchor: .trailing) }
            }
        }
        .glassBar()
        .accessibilityIdentifier("browser.breadcrumbs")
    }
}
