import SwiftUI

/// Folder chooser for Move/Copy within one provider.
///
/// Deliberately minimal: it browses directories only, so the user cannot pick
/// a file as a destination.
struct DestinationPickerView: View {
    let provider: any FileProviding
    let startingPath: String
    let title: String
    let onChoose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    @State private var directories: [FileItem] = []
    @State private var isLoading = false
    @State private var failure: BrowseFailure?
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""

    init(
        provider: any FileProviding,
        startingPath: String,
        title: String,
        onChoose: @escaping (String) -> Void
    ) {
        self.provider = provider
        self.startingPath = startingPath
        self.title = title
        self.onChoose = onChoose
        self._path = State(initialValue: startingPath)
    }

    var body: some View {
        NavigationStack {
            List {
                if path != provider.rootPath {
                    Button {
                        Task { await navigateUp() }
                    } label: {
                        Label("..", systemImage: "arrow.up.left")
                    }
                }
                ForEach(directories) { directory in
                    Button {
                        Task { await navigate(to: directory.path) }
                    } label: {
                        Label(directory.name, systemImage: "folder")
                    }
                }
                if directories.isEmpty, !isLoading {
                    Text("No subfolders")
                        .foregroundStyle(.secondary)
                }
            }
            .overlay { if isLoading { ProgressView() } }
            .navigationTitle(title)
            .safeAreaInset(edge: .top) {
                Text(currentLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassBar()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreatingFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose") {
                        onChoose(path)
                        dismiss()
                    }
                    .accessibilityIdentifier("destinationPicker.choose")
                }
            }
            .alert("New Folder", isPresented: $isCreatingFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Cancel", role: .cancel) { newFolderName = "" }
                Button("Create") {
                    let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    newFolderName = ""
                    guard !name.isEmpty else { return }
                    Task {
                        try? await provider.createDirectory(at: provider.joining(name, to: path))
                        await load()
                    }
                }
            }
            .alert(
                failure?.title ?? "Error",
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
            ) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure?.message ?? "")
            }
        }
        .task { await load() }
    }

    private var currentLabel: String {
        path == provider.rootPath ? provider.label : (path as NSString).lastPathComponent
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await provider.connect()
            let contents = try await provider.list(at: path)
            directories = contents.filter(\.isDirectory).sorted(by: SortOption.default)
        } catch {
            directories = []
            failure = BrowseFailure(error: error, target: provider.label)
        }
    }

    private func navigate(to newPath: String) async {
        path = newPath
        await load()
    }

    private func navigateUp() async {
        if provider.isRemote {
            path = BrowsePath.parent(of: path) ?? provider.rootPath
        } else {
            let candidate = (path as NSString).deletingLastPathComponent
            path = candidate.count < provider.rootPath.count ? provider.rootPath : candidate
        }
        await load()
    }
}
