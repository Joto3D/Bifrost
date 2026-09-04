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

    let package: ThunderstorePackage
    let iconURL: URL?
    /// The full, already-loaded Thunderstore index — used to resolve
    /// dependencies without a redundant re-fetch.
    let index: [ThunderstorePackage]

    @Environment(AppState.self) private var appState
    @State private var installState: InstallState = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let version = package.latestVersion {
                    GroupBox("Version") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Latest", value: version.versionNumber)
                            LabeledContent("Downloads", value: version.downloads.formatted())
                            LabeledContent("Size", value: byteFormatter.string(fromByteCount: Int64(version.fileSize)))

                            if !version.dependencies.isEmpty {
                                Divider()
                                Text("Dependencies")
                                    .font(.subheadline.weight(.semibold))
                                ForEach(version.dependencies, id: \.self) { dependency in
                                    Text(dependency)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let description = package.latestVersion?.description, !description.isEmpty {
                    GroupBox("Description") {
                        Text(description)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }

                HStack(spacing: 12) {
                    Link(destination: package.packageURL) {
                        Label("Open on Thunderstore", systemImage: "arrow.up.right.square")
                    }

                    Spacer()

                    installControl
                }

                if case .failed(let message) = installState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
        }
        .navigationTitle(package.name)
        .onChange(of: package.id) { installState = .idle }
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
                .foregroundStyle(.green)
        } else {
            switch installState {
            case .idle, .failed, .confirming:
                Button {
                    Task { await startInstall() }
                } label: {
                    Label("Install", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
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
        HStack(alignment: .top, spacing: 16) {
            ModIconView(url: iconURL, size: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(package.name)
                    .font(.title2.bold())
                Text("by \(package.owner)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label("\(package.totalDownloads.formatted())", systemImage: "arrow.down.circle")
                    Label("\(package.ratingScore.formatted())", systemImage: "star.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
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
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
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
