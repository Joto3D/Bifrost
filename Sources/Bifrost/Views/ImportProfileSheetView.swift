import SwiftUI
import UniformTypeIdentifiers

/// "Import…" sheet, opened from `ProfilesSheetView`'s toolbar: paste a
/// share code — Bifrost's own native base64, or an r2modman/Thunderstore
/// Mod Manager profile code, auto-detected via
/// `ProfileShare.looksLikeR2ModManCode` since the two formats never look
/// alike — or pick a `.bifrostprofile` file. Either way, review the
/// resulting `ProfileShare.ImportPlan` (what will install, what's already
/// on this machine, and what can't be resolved and why) before confirming
/// installs everything resolvable and creates a new profile from it — the
/// same preview-before-you-commit shape `ServerJoinSheetView` uses for its
/// own guided flow.
struct ImportProfileSheetView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var thunderstoreClient = ThunderstoreClient()
    @State private var codeText = ""
    @State private var filePickerPresented = false
    @State private var plan: ProfileShare.ImportPlan?
    @State private var isParsing = false
    @State private var isApplying = false
    @State private var errorLine: String?
    @State private var progressLine: String?
    @State private var createdProfile: Profile?

    private static let profileFileType = UTType(filenameExtension: "bifrostprofile") ?? .json

    var body: some View {
        NavigationStack {
            Group {
                if let createdProfile {
                    doneView(createdProfile)
                } else if let plan {
                    planView(plan)
                } else {
                    pasteView
                }
            }
            .navigationTitle("Import Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(createdProfile == nil ? "Cancel" : "Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .presentationBackground(.regularMaterial)
        .fileImporter(
            isPresented: $filePickerPresented,
            allowedContentTypes: [Self.profileFileType, .json]
        ) { result in
            switch result {
            case .success(let url):
                Task { await parseFile(url) }
            case .failure(let error):
                errorLine = "Couldn't open file: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Paste step

    private var pasteView: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Paste a share code from a friend — Bifrost's own, or an r2modman/Thunderstore Mod Manager profile code — or pick a .bifrostprofile file.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Paste share code here", text: $codeText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            if let errorLine {
                Text(errorLine)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Button("Import from File…") { filePickerPresented = true }
                    .disabled(isParsing)
                Spacer()
                if isParsing {
                    ProgressView().controlSize(.small)
                }
                Button("Parse Code") { Task { await parseCode() } }
                    .buttonStyle(.aurora)
                    .frame(maxWidth: 160)
                    .disabled(codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isParsing)
            }
        }
        .padding(Theme.Spacing.xl)
    }

    // MARK: - Plan step

    private func planView(_ plan: ProfileShare.ImportPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Text("Importing \u{201C}\(plan.importedName)\u{201D}")
                    .font(.title3.weight(.semibold))

                if plan.isEmpty {
                    Text("Nothing here can be imported — see below for why.")
                        .foregroundStyle(.secondary)
                }

                if !plan.resolvable.isEmpty {
                    planSection(title: "Will install", systemImage: "arrow.down.circle") {
                        ForEach(plan.resolvable) { mod in
                            HStack {
                                Text(mod.fullName)
                                Spacer()
                                if mod.wasSubstituted {
                                    Text("v\(mod.requestedVersion) \u{2192} v\(mod.resolvedVersion)")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                } else {
                                    Text("v\(mod.resolvedVersion)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !plan.alreadyInstalled.isEmpty {
                    planSection(title: "Already installed", systemImage: "checkmark.circle") {
                        ForEach(plan.alreadyInstalled) { mod in
                            HStack {
                                Text(mod.fullName)
                                Spacer()
                                Text("v\(mod.installedVersion)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !plan.unresolvable.isEmpty {
                    planSection(title: "Can't import", systemImage: "exclamationmark.triangle") {
                        ForEach(plan.unresolvable) { mod in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mod.fullName)
                                Text(explanation(for: mod.reason))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if let errorLine {
                    Text(errorLine)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Back") {
                    self.plan = nil
                    errorLine = nil
                }
                .disabled(isApplying)

                Spacer()

                if isApplying, let progressLine {
                    Text(progressLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isApplying {
                    ProgressView().controlSize(.small)
                }

                Button("Install & Create Profile (\(plan.installableCount))") { Task { await apply(plan) } }
                    .buttonStyle(.aurora)
                    .frame(maxWidth: 240)
                    .disabled(isApplying || plan.isEmpty || appState.status.gameFound == nil)
            }
            .padding(Theme.Spacing.l)
            .background(.regularMaterial)
        }
    }

    private func planSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader(title: title, systemImage: systemImage)
            content()
        }
        .padding(Theme.Spacing.l)
        .bifrostCard()
    }

    private func explanation(for reason: ProfileShare.ImportPlan.UnresolvableReason) -> String {
        switch reason {
        case .notInIndex:
            return "Not found in the Thunderstore index — it may have been removed, made private, or your index cache is stale."
        case .nexusOnly(let modId):
            if let modId {
                return "Hosted on Nexus Mods (id \(modId)) — install it there, then add it to this profile manually."
            }
            return "Hosted on Nexus Mods — install it there, then add it to this profile manually."
        }
    }

    // MARK: - Done step

    private func doneView(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Label("Imported \u{201C}\(profile.name)\u{201D}", systemImage: "checkmark.seal.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
            Text("\(profile.mods.count) mod\(profile.mods.count == 1 ? "" : "s") added. Use \u{201C}Apply\u{201D} on it from the Profiles list when you're ready to switch to it.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.aurora)
                    .frame(maxWidth: 160)
            }
        }
        .padding(Theme.Spacing.xl)
    }

    // MARK: - Actions

    private func parseCode() async {
        let trimmed = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isParsing = true
        errorLine = nil
        defer { isParsing = false }
        do {
            let index = try await thunderstoreClient.fetchIndex(force: false)
            if ProfileShare.looksLikeR2ModManCode(trimmed) {
                plan = try await ProfileShare.importR2Code(trimmed, index: index, manifest: appState.manifest)
            } else {
                plan = try ProfileShare.plan(nativeString: trimmed, index: index, manifest: appState.manifest)
            }
        } catch {
            errorLine = "Couldn't import: \(String(describing: error))"
        }
    }

    private func parseFile(_ url: URL) async {
        isParsing = true
        errorLine = nil
        defer { isParsing = false }
        do {
            let index = try await thunderstoreClient.fetchIndex(force: false)
            plan = try ProfileShare.plan(nativeFileURL: url, index: index, manifest: appState.manifest)
        } catch {
            errorLine = "Couldn't import: \(String(describing: error))"
        }
    }

    private func apply(_ plan: ProfileShare.ImportPlan) async {
        guard let gameDir = appState.status.gameFound else {
            errorLine = "Locate Valheim first (Home tab)."
            return
        }
        isApplying = true
        errorLine = nil
        defer { isApplying = false }
        do {
            let index = try await thunderstoreClient.fetchIndex(force: false)
            let profile = try await ProfileShare.apply(
                plan,
                index: index,
                modManager: appState.modManager,
                profileStore: appState.profileStore,
                gameDir: gameDir,
                onProgress: { progress in
                    Task { @MainActor in progressLine = Self.describe(progress) }
                }
            )
            await appState.refreshManifest()
            await appState.refreshProfiles()
            createdProfile = profile
        } catch {
            errorLine = "Couldn't install: \(error.localizedDescription)"
        }
    }

    private static func describe(_ progress: ModManager.Progress) -> String {
        switch progress {
        case .installingLoader: return "Installing BepInEx…"
        case .downloading(let fullName): return "Downloading \(fullName)…"
        case .extracting(let fullName): return "Extracting \(fullName)…"
        case .copyingFiles(let fullName): return "Installing \(fullName)…"
        case .done(let fullName): return "Installed \(fullName)"
        }
    }
}
