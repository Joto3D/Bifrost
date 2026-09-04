import SwiftUI

/// Browse tab: searches and lists the Thunderstore package index for
/// Valheim, with a detail view for the selected mod. Behavior is
/// unchanged from the original list — this pass only richens the row and
/// loading/empty presentation.
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
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
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
            VStack(spacing: Theme.Spacing.m) {
                ProgressView()
                Text("Loading thousands of mods…")
                    .font(.subheadline.weight(.medium))
                Text("This can take a moment on first load.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: Theme.Spacing.m) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Couldn't load mods")
                    .font(Theme.headingFont(15))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await loadIndex(force: true) }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let packages):
            let visible = filteredAndSorted(packages)
            VStack(spacing: 0) {
                sortBar
                    .padding(Theme.Spacing.s)

                if visible.isEmpty {
                    emptySearchState
                } else {
                    List(visible, selection: $selectedPackageID) { package in
                        ModRow(package: package, iconURL: client.iconURL(for: package), installed: appState.manifest.mods.contains { $0.fullName == package.fullName })
                            .tag(package.id)
                    }
                    .listStyle(.plain)
                }
            }
        }
    }

    private var sortBar: some View {
        Picker("Sort", selection: $sortOption) {
            ForEach(SortOption.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }

    private var emptySearchState: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No mods match \u{201c}\(searchText)\u{201d}")
                .font(Theme.headingFont(14))
            Text("Try a different name, author, or fewer words.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detail: some View {
        if case .loaded(let packages) = loadState,
           let selectedPackageID,
           let package = packages.first(where: { $0.id == selectedPackageID }) {
            ModDetailView(package: package, iconURL: client.iconURL(for: package), index: packages)
        } else {
            VStack(spacing: Theme.Spacing.s) {
                Image(systemName: "shippingbox")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Select a mod")
                    .foregroundStyle(.secondary)
            }
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

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            ModIconView(url: iconURL, size: 56)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if installed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .help("Installed")
                    }
                }
                Text("by \(package.owner)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let description = package.latestVersion?.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Chip(text: package.totalDownloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down.circle")
                    Chip(text: package.ratingScore.formatted(), systemImage: "star.fill", tint: .yellow)
                    Chip(text: updatedAgo, systemImage: "clock")
                }

                if !package.categories.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(package.categories.prefix(4), id: \.self) { category in
                            Chip(text: category, tint: .accentColor)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.s)
        .padding(.horizontal, Theme.Spacing.xs)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.05 : 0))
        }
        .onHover { isHovered = $0 }
        .animation(Theme.settle, value: isHovered)
    }

    private var updatedAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: package.dateUpdated, relativeTo: Date())
    }
}
