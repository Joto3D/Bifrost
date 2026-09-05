import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Full profile management sheet, opened from the Installed tab's
/// "Profiles…" toolbar button: list every profile (active one marked),
/// create empty / create from current, duplicate, rename, delete. Applying
/// a profile from here goes through the same preview/confirm/apply/missing
/// flow as the Home tab's picker (see `StatusPanel`).
struct ProfilesSheetView: View {
    private struct PendingSwitch: Identifiable {
        let id = UUID()
        let profileID: UUID
        let preview: ProfileStore.ApplyPreview
    }

    private struct PendingMissing: Identifiable {
        let id = UUID()
        let profileID: UUID
        let missing: [String]
    }

    private enum NamePromptKind: Identifiable {
        case createEmpty
        case createFromCurrent
        case duplicate(Profile)
        case rename(Profile)

        var id: String {
            switch self {
            case .createEmpty: return "createEmpty"
            case .createFromCurrent: return "createFromCurrent"
            case .duplicate(let profile): return "duplicate-\(profile.id)"
            case .rename(let profile): return "rename-\(profile.id)"
            }
        }

        var title: String {
            switch self {
            case .createEmpty: return "New Profile"
            case .createFromCurrent: return "New Profile from Current"
            case .duplicate: return "Duplicate Profile"
            case .rename: return "Rename Profile"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var thunderstoreClient = ThunderstoreClient()
    @State private var busy = false
    @State private var statusLine: String?

    @State private var pendingSwitch: PendingSwitch?
    @State private var pendingMissing: PendingMissing?
    @State private var pendingDelete: Profile?
    @State private var namePromptKind: NamePromptKind?
    @State private var namePromptText = ""
    @State private var importSheetPresented = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(appState.profiles.profiles.sorted(by: { $0.name < $1.name })) { profile in
                    row(for: profile)
                }
            }
            .listStyle(.inset)
            .navigationTitle("Profiles")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("New Profile") { presentNamePrompt(.createEmpty, defaultText: "New Profile") }
                        .disabled(busy)
                    Button("New from Current") { presentNamePrompt(.createFromCurrent, defaultText: "New Profile") }
                        .disabled(busy)
                    Button("Import…") { importSheetPresented = true }
                        .disabled(busy)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $importSheetPresented) {
                ImportProfileSheetView()
            }
            .safeAreaInset(edge: .bottom) {
                if let statusLine {
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .presentationBackground(.regularMaterial)
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { profile in
            Button("Delete", role: .destructive) { Task { await delete(profile) } }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text("Removes the profile \"\(profile.name)\". Installed mods are left untouched.")
        }
        .confirmationDialog(
            "Switch profile?",
            isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
            presenting: pendingSwitch
        ) { pending in
            Button("Switch") { Task { await performSwitch(profileID: pending.profileID) } }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(switchMessage(for: pending.preview))
        }
        .confirmationDialog(
            "Install missing mods?",
            isPresented: Binding(get: { pendingMissing != nil }, set: { if !$0 { pendingMissing = nil } }),
            presenting: pendingMissing
        ) { pending in
            Button("Install Missing (\(pending.missing.count))") { Task { await installMissing(pending) } }
            Button("Not Now", role: .cancel) {}
        } message: { pending in
            Text("This profile also wants: \(pending.missing.joined(separator: ", "))")
        }
        .alert(
            namePromptKind?.title ?? "",
            isPresented: Binding(get: { namePromptKind != nil }, set: { if !$0 { namePromptKind = nil } })
        ) {
            TextField("Name", text: $namePromptText)
            Button("Cancel", role: .cancel) { namePromptKind = nil }
            Button("OK") { Task { await commitNamePrompt() } }
                .disabled(namePromptText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private func row(for profile: Profile) -> some View {
        let isActive = profile.id == appState.profiles.activeProfileID

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.body.weight(.semibold))
                    if isActive {
                        AuroraBadge(text: "Active", systemImage: "checkmark")
                    }
                }
                let enabledCount = profile.mods.filter { $0.enabled }.count
                Text("\(profile.mods.count) mod\(profile.mods.count == 1 ? "" : "s") (\(enabledCount) enabled)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isActive {
                Button("Apply") { Task { await requestSwitch(to: profile.id) } }
                    .disabled(busy)
            }
            Button("Duplicate") { presentNamePrompt(.duplicate(profile), defaultText: profile.name + " Copy") }
                .disabled(busy)
            Button("Rename") { presentNamePrompt(.rename(profile), defaultText: profile.name) }
                .disabled(busy)
            Menu {
                Button("Copy Share Code") { copyShareCode(profile) }
                Button("Export to File…") { exportToFile(profile) }
                Button("Copy r2modman Code") { Task { await copyR2Code(profile) } }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(busy)
            .menuIndicator(.hidden)
            .fixedSize()
            Button(role: .destructive) {
                pendingDelete = profile
            } label: {
                Image(systemName: "trash")
            }
            .disabled(busy || isActive)
        }
        .padding(.vertical, 4)
        .opacity(busy ? 0.6 : 1)
    }

    private func presentNamePrompt(_ kind: NamePromptKind, defaultText: String) {
        namePromptText = defaultText
        namePromptKind = kind
    }

    private func commitNamePrompt() async {
        guard let kind = namePromptKind else { return }
        let name = namePromptText.trimmingCharacters(in: .whitespaces)
        namePromptKind = nil
        guard !name.isEmpty else { return }

        busy = true
        defer { busy = false }
        do {
            switch kind {
            case .createEmpty:
                await appState.profileStore.create(name: name, fromCurrent: false)
            case .createFromCurrent:
                await appState.profileStore.create(name: name, fromCurrent: true)
            case .duplicate(let profile):
                try await appState.profileStore.duplicate(id: profile.id, newName: name)
            case .rename(let profile):
                try await appState.profileStore.rename(id: profile.id, to: name)
            }
            await appState.refreshProfiles()
            statusLine = nil
        } catch {
            statusLine = "Couldn't save profile: \(error.localizedDescription)"
        }
    }

    private func delete(_ profile: Profile) async {
        pendingDelete = nil
        busy = true
        defer { busy = false }
        do {
            try await appState.profileStore.delete(id: profile.id)
            await appState.refreshProfiles()
        } catch {
            statusLine = "Couldn't delete \(profile.name): \(error.localizedDescription)"
        }
    }

    private func switchMessage(for preview: ProfileStore.ApplyPreview) -> String {
        var lines: [String] = []
        if !preview.toDisable.isEmpty {
            lines.append("Will disable: \(preview.toDisable.joined(separator: ", "))")
        }
        if !preview.missing.isEmpty {
            lines.append("Not installed yet: \(preview.missing.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private func requestSwitch(to profileID: UUID) async {
        statusLine = nil
        do {
            let preview = try await appState.previewApplyProfile(id: profileID)
            if preview.isNoOp {
                await performSwitch(profileID: profileID)
            } else {
                pendingSwitch = PendingSwitch(profileID: profileID, preview: preview)
            }
        } catch {
            statusLine = "Couldn't preview profile switch: \(error.localizedDescription)"
        }
    }

    private func performSwitch(profileID: UUID) async {
        guard let gameDir = appState.status.gameFound else {
            statusLine = "Valheim not found — check the Home tab"
            return
        }
        busy = true
        defer { busy = false }
        do {
            let result = try await appState.applyProfile(id: profileID, gameDir: gameDir)
            if !result.missing.isEmpty {
                pendingMissing = PendingMissing(profileID: profileID, missing: result.missing)
            }
        } catch {
            statusLine = "Couldn't switch profile: \(error.localizedDescription)"
        }
    }

    // MARK: - Sharing

    /// Copies `profile`'s native share code (base64 JSON — see
    /// `ProfileShare.export`) to the clipboard, warning in `statusLine`
    /// about any `source == "local"` mods that got left out (they have no
    /// identity a recipient could ever resolve).
    private func copyShareCode(_ profile: Profile) {
        let outcome = ProfileShare.export(profile: profile, manifest: appState.manifest)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outcome.encodedString, forType: .string)
        statusLine = outcome.skippedLocalMods.isEmpty
            ? "Copied share code for \"\(profile.name)\" to the clipboard."
            : "Copied share code for \"\(profile.name)\" (skipped local-only mods: \(outcome.skippedLocalMods.joined(separator: ", ")))."
    }

    /// Presents a save panel and writes `profile` to the chosen
    /// `.bifrostprofile` file (see `ProfileShare.exportFile`).
    private func exportToFile(_ profile: Profile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(profile.name).bifrostprofile"
        panel.allowedContentTypes = [UTType(filenameExtension: "bifrostprofile") ?? .json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let skipped = try ProfileShare.exportFile(profile: profile, manifest: appState.manifest, to: url)
            statusLine = skipped.isEmpty
                ? "Exported \"\(profile.name)\" to \(url.lastPathComponent)."
                : "Exported \"\(profile.name)\" to \(url.lastPathComponent) (skipped local-only mods: \(skipped.joined(separator: ", ")))."
        } catch {
            statusLine = "Couldn't export \"\(profile.name)\": \(error.localizedDescription)"
        }
    }

    /// Uploads `profile` as an r2modman-compatible profile code (see
    /// `ProfileShare.exportR2Code`) and copies the resulting code to the
    /// clipboard — a live network round trip, so this sets `busy` like any
    /// other in-flight action.
    private func copyR2Code(_ profile: Profile) async {
        statusLine = "Uploading r2modman code for \"\(profile.name)\"…"
        busy = true
        defer { busy = false }
        do {
            let code = try await ProfileShare.exportR2Code(profile: profile, manifest: appState.manifest)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            statusLine = "Copied r2modman code for \"\(profile.name)\" to the clipboard: \(code)"
        } catch {
            statusLine = "Couldn't create an r2modman code for \"\(profile.name)\": \(error.localizedDescription)"
        }
    }

    private func installMissing(_ pending: PendingMissing) async {
        guard let gameDir = appState.status.gameFound else { return }
        busy = true
        defer { busy = false }
        do {
            let index = try await thunderstoreClient.fetchIndex(force: false)
            let result = try await appState.installMissingAndReapply(
                fullNames: pending.missing,
                profileID: pending.profileID,
                gameDir: gameDir,
                index: index
            )
            statusLine = result.missing.isEmpty ? nil : "Still missing: \(result.missing.joined(separator: ", "))"
        } catch {
            statusLine = "Couldn't install missing mods: \(error.localizedDescription)"
        }
    }
}
