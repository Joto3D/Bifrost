import SwiftUI

/// Browse tab: searches and lists the Thunderstore package index for
/// Valheim, with a detail view for the selected mod.
struct ModBrowserView: View {
    private enum SortOption: String, CaseIterable, Identifiable {
        case rating = "Top Rated"
        case downloads = "Most Downloaded"
        case recentlyUpdated = "Recently Updated"

        var id: String { rawValue }
    }

    private enum LoadState {
        case loading
        case loaded([ThunderstorePackage])
        case failed(String)
    }

    @Environment(AppState.self) private var appState
    @State private var client = ThunderstoreClient()
    @State private var loadState: LoadState = .loading
    @State private var searchText = ""
    @State private var sortOption: SortOption = .rating
    @State private var selectedPackageID: ThunderstorePackage.ID?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            detail
        }
        .searchable(text: $searchText, prompt: "Search mods")
        .task {
            await loadIndex(force: false)
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        switch loadState {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading Thunderstore package index…")
                    .foregroundStyle(.secondary)
                Text("This can take a moment on first load.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Couldn't load mods")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await loadIndex(force: true) }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let packages):
            let visible = filteredAndSorted(packages)
            VStack(spacing: 0) {
                Picker("Sort", selection: $sortOption) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(8)

                List(visible, selection: $selectedPackageID) { package in
                    ModRow(package: package, iconURL: client.iconURL(for: package), installed: appState.manifest.mods.contains { $0.fullName == package.fullName })
                        .tag(package.id)
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if case .loaded(let packages) = loadState,
           let selectedPackageID,
           let package = packages.first(where: { $0.id == selectedPackageID }) {
            ModDetailView(package: package, iconURL: client.iconURL(for: package), index: packages)
        } else {
            Text("Select a mod")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func filteredAndSorted(_ packages: [ThunderstorePackage]) -> [ThunderstorePackage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [ThunderstorePackage]
        if query.isEmpty {
            filtered = packages
        } else {
            filtered = packages.filter { package in
                package.name.lowercased().contains(query)
                    || package.owner.lowercased().contains(query)
                    || (package.latestVersion?.description.lowercased().contains(query) ?? false)
            }
        }

        switch sortOption {
        case .rating:
            return filtered.sorted { $0.ratingScore > $1.ratingScore }
        case .downloads:
            return filtered.sorted { $0.totalDownloads > $1.totalDownloads }
        case .recentlyUpdated:
            return filtered.sorted { $0.dateUpdated > $1.dateUpdated }
        }
    }

    private func loadIndex(force: Bool) async {
        loadState = .loading
        do {
            let packages = try await client.fetchIndex(force: force)
            loadState = .loaded(packages)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }
}

private struct ModRow: View {
    let package: ThunderstorePackage
    let iconURL: URL?
    let installed: Bool

    var body: some View {
        HStack(spacing: 12) {
            ModIconView(url: iconURL, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if installed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help("Installed")
                    }
                }
                Text(package.owner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let description = package.latestVersion?.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
                    Label(package.totalDownloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down.circle")
                    Label(package.ratingScore.formatted(), systemImage: "star.fill")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
