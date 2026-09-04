import SwiftUI

/// Full detail view for a single Thunderstore package: description,
/// version/dependency info, a link out to the Thunderstore page, and an
/// Install button that resolves dependencies, confirms the plan, and
/// installs it via `ModManager`.
struct ModDetailView: View {
    private enum InstallState: Equatable {
        case idle
        case resolving
        case confirming([ModManager.ResolvedInstall])
        case installing(String?)
        case failed(String)
    }

    private enum ReadmeState: Equatable {
        case idle
        case loading
        case loaded(String)
        case failed(String)
    }

    let package: ThunderstorePackage
    let iconURL: URL?
    /// The full, already-loaded Thunderstore index — used to resolve
    /// dependencies without a redundant re-fetch.
    let index: [ThunderstorePackage]

    @Environment(AppState.self) private var appState
    @State private var installState: InstallState = .idle
    @State private var readmeState: ReadmeState = .idle
    @State private var associatedConfigURL: URL?
    @State private var keybinds: [BepInExConfig.Entry] = []
    @State private var configEditorPresented = false

    private let readableWidth: CGFloat = 640

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header

                chipsRow

                Link(destination: package.packageURL) {
                    Label("Open on Thunderstore", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(maxWidth: readableWidth, alignment: .leading)

                if case .failed(let message) = installState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: readableWidth, alignment: .leading)
                }

                if let description = package.latestVersion?.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        SectionHeader(title: "Description")
                        Text(description)
                            .frame(maxWidth: readableWidth, alignment: .leading)
                    }
                }

                if let version = package.latestVersion, !version.dependencies.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        SectionHeader(title: "Dependencies", systemImage: "link")
                        FlowLayout(spacing: 6) {
                            ForEach(version.dependencies, id: \.self) { dependency in
                                Chip(text: dependency, systemImage: "shippingbox")
                            }
                        }
                        .frame(maxWidth: readableWidth, alignment: .leading)
                    }
                }

                if associatedConfigURL != nil || !keybinds.isEmpty {
                    configSection
                }

                readmeSection
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(package.name)
        .onChange(of: package.id) {
            installState = .idle
            readmeState = .idle
            associatedConfigURL = nil
            keybinds = []
        }
        .task(id: "\(package.id)-\(appState.manifest.mods.count)") {
            await loadConfigAssociation()
        }
        .sheet(isPresented: $configEditorPresented) {
            if let associatedConfigURL {
                ConfigEditorView(url: associatedConfigURL, title: package.fullName)
            }
        }
        .alert(
            "Install \(package.name)?",
            isPresented: Binding(
                get: { if case .confirming = installState { return true }; return false },
                set: { if !$0 { installState = .idle } }
            )
        ) {
            Button("Install") {
                if case .confirming(let plan) = installState {
                    Task { await runInstall(plan: plan) }
                }
            }
            Button("Cancel", role: .cancel) { installState = .idle }
        } message: {
            if case .confirming(let plan) = installState {
                Text("Will install: \(plan.map(describe).joined(separator: ", "))")
            }
        }
    }

    @ViewBuilder
    private var installControl: some View {
        if let installedMod = appState.manifest.mods.first(where: { $0.fullName == package.fullName }) {
            Label("Installed ✓ (\(installedMod.version))", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
        } else {
            switch installState {
            case .idle, .failed, .confirming:
                Button {
                    Task { await startInstall() }
                } label: {
                    Label("Install", systemImage: "square.and.arrow.down")
                        .padding(.horizontal, Theme.Spacing.s)
                }
                .buttonStyle(.aurora)
                .fixedSize()
                .disabled(appState.status.gameFound == nil)
                .help(appState.status.gameFound == nil ? "Valheim not found — check the Home tab" : "")

            case .resolving:
                Label("Resolving dependencies…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)

            case .installing(let line):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(line ?? "Installing…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Chips

    private var chipsRow: some View {
        FlowLayout(spacing: 6) {
            if let version = package.latestVersion {
                Chip(text: version.downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down.circle")
                Chip(text: byteFormatter.string(fromByteCount: Int64(version.fileSize)), systemImage: "internaldrive")
            }
            Chip(text: package.ratingScore.formatted(), systemImage: "star.fill", tint: .yellow)
            ForEach(package.categories.prefix(6), id: \.self) { category in
                Chip(text: category, tint: .accentColor)
            }
        }
        .frame(maxWidth: readableWidth, alignment: .leading)
    }

    // MARK: - Config / keybinds

    private var configSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader(title: "Config", systemImage: "slider.horizontal.3")

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                if !keybinds.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(keybinds) { entry in
                            Chip(text: "\(entry.key): \(entry.rawValue)", systemImage: "keyboard")
                        }
                    }
                }
                if associatedConfigURL != nil {
                    Button {
                        configEditorPresented = true
                    } label: {
                        Label("Edit Config", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: readableWidth, alignment: .leading)
            .bifrostCard()
        }
    }

    /// Finds this mod's associated `.cfg` file (if installed and one
    /// matches — see `BepInExConfig.associate`) and parses its
    /// `KeyboardShortcut` entries for the compact summary above. Re-runs
    /// whenever the package changes or the manifest's mod count changes
    /// (install/uninstall), via the `.task(id:)` in `body`.
    private func loadConfigAssociation() async {
        guard appState.manifest.mods.contains(where: { $0.fullName == package.fullName }),
              let gameDir = appState.status.gameFound else {
            associatedConfigURL = nil
            keybinds = []
            return
        }
        let configDir = gameDir.appendingPathComponent("BepInEx/config")
        guard let url = BepInExConfig.findAssociatedConfig(in: configDir, fullName: package.fullName, name: package.name) else {
            associatedConfigURL = nil
            keybinds = []
            return
        }
        associatedConfigURL = url
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            keybinds = []
            return
        }
        keybinds = BepInExConfig.parse(text).keyboardShortcuts
    }

    // MARK: - README

    private var readmeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader(title: "README", systemImage: "doc.text")

            Group {
                switch readmeState {
                case .idle:
                    Button {
                        Task { await fetchReadme() }
                    } label: {
                        Label("Load README", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading README…")
                            .foregroundStyle(.secondary)
                    }
                case .loaded(let markdown):
                    Text(Self.renderedReadme(markdown))
                        .textSelection(.enabled)
                        .lineSpacing(3)
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Couldn't load README: \(message)")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button("Retry") {
                            Task { await fetchReadme() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: readableWidth, alignment: .leading)
            .bifrostCard()
        }
    }

    /// Renders Thunderstore's README markdown with full block-level
    /// parsing (headings, lists, links — real package READMEs use all
    /// three); falls back to inline-only parsing, then to plain text, if
    /// the markdown doesn't parse cleanly.
    private static func renderedReadme(_ markdown: String) -> AttributedString {
        if let full = try? AttributedString(markdown: markdown, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)) {
            return full
        }
        if let inline = try? AttributedString(markdown: markdown, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return inline
        }
        return AttributedString(markdown)
    }

    /// Fetches `https://thunderstore.io/api/experimental/package/{owner}/
    /// {name}/{version}/readme/` — a `{"markdown": "..."}` JSON body
    /// (verified against the live API) — and caches the result in
    /// `ReadmeCache` per package+version so revisiting the same version
    /// doesn't re-fetch.
    private func fetchReadme() async {
        guard let version = package.latestVersion else {
            readmeState = .failed("No published version")
            return
        }
        let cacheKey = "\(package.owner)/\(package.name)/\(version.versionNumber)"
        if let cached = await ReadmeCache.shared.markdown(for: cacheKey) {
            readmeState = .loaded(cached)
            return
        }

        readmeState = .loading
        guard let url = URL(string: "https://thunderstore.io/api/experimental/package/\(package.owner)/\(package.name)/\(version.versionNumber)/readme/") else {
            readmeState = .failed("Invalid README URL")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                readmeState = .failed("HTTP \(status)")
                return
            }
            let decoded = try JSONDecoder().decode(ReadmeResponse.self, from: data)
            await ReadmeCache.shared.setMarkdown(decoded.markdown, for: cacheKey)
            readmeState = .loaded(decoded.markdown)
        } catch {
            readmeState = .failed(error.localizedDescription)
        }
    }

    private struct ReadmeResponse: Decodable {
        let markdown: String
    }

    private func describe(_ item: ModManager.ResolvedInstall) -> String {
        switch item {
        case .loader:
            return "BepInEx loader"
        case .mod(let fullName, _, let version):
            return "\(fullName) \(version.versionNumber)"
        }
    }

    private func startInstall() async {
        installState = .resolving
        do {
            let plan = try await appState.modManager.resolve(package: package, index: index)
            installState = .confirming(plan)
        } catch {
            installState = .failed("Couldn't resolve dependencies: \(error.localizedDescription)")
        }
    }

    private func runInstall(plan: [ModManager.ResolvedInstall]) async {
        guard let gameDir = appState.status.gameFound else {
            installState = .failed("Valheim not found — check the Home tab")
            return
        }
        installState = .installing(nil)
        do {
            try await appState.modManager.install(resolved: plan, gameDir: gameDir) { progress in
                Task { @MainActor in
                    installState = .installing(Self.describe(progress))
                }
            }
            await appState.refreshManifest()
            await appState.syncActiveProfileWithManifest()
            installState = .idle
        } catch {
            installState = .failed("Install failed: \(error.localizedDescription)")
        }
    }

    private static func describe(_ progress: ModManager.Progress) -> String {
        switch progress {
        case .installingLoader: return "Installing BepInEx loader…"
        case .downloading(let fullName): return "Downloading \(fullName)…"
        case .extracting(let fullName): return "Extracting \(fullName)…"
        case .copyingFiles(let fullName): return "Copying \(fullName) into place…"
        case .done(let fullName): return "\(fullName) installed"
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.l) {
            ModIconView(url: iconURL, size: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(package.name)
                    .font(Theme.titleFont(20))
                Text("by \(package.owner)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let version = package.latestVersion {
                    Text("v\(version.versionNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            installControl
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bifrostCard()
    }

    private var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }
}

/// Shared icon view used by both the browse list rows and the detail
/// header.
struct ModIconView: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: Theme.settle)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            default:
                RoundedRectangle(cornerRadius: size * 0.2)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}

/// In-memory cache of fetched READMEs, keyed by "owner/name/version" so
/// revisiting a package's detail view within the same run doesn't re-fetch
/// a version whose README never changes. An actor rather than plain state
/// since `ModDetailView` instances come and go with navigation — this
/// needs to outlive any one of them.
actor ReadmeCache {
    static let shared = ReadmeCache()

    private var cache: [String: String] = [:]

    func markdown(for key: String) -> String? { cache[key] }
    func setMarkdown(_ markdown: String, for key: String) { cache[key] = markdown }
}
