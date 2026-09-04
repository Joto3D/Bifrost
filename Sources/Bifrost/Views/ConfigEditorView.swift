import SwiftUI
import AppKit

/// Browses every `.cfg` file under `BepInEx/config`, grouped into mod
/// configs (heuristically associated via `BepInExConfig.associate`, see
/// `InstalledModsView`'s discovery pass) and unmatched "Other configs".
/// Selecting a row opens `ConfigEditorView` for that file.
struct ConfigsListView: View {
    let configs: [BepInExConfig.DiscoveredConfig]
    let onSelect: (BepInExConfig.DiscoveredConfig) -> Void
    var onRefresh: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private var matched: [BepInExConfig.DiscoveredConfig] {
        configs.filter { $0.associatedFullName != nil }
    }
    private var unmatched: [BepInExConfig.DiscoveredConfig] {
        configs.filter { $0.associatedFullName == nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                if configs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("No .cfg files found")
                            .font(Theme.headingFont(15))
                        Text("Config files show up here once a mod that uses BepInEx's config system has been run at least once.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !matched.isEmpty {
                            Section("Mod Configs") {
                                ForEach(matched) { config in row(config) }
                            }
                        }
                        if !unmatched.isEmpty {
                            Section("Other Configs") {
                                ForEach(unmatched) { config in row(config) }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Configs")
            .toolbar {
                if let onRefresh {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            onRefresh()
                        } label: {
                            Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 380)
        .presentationBackground(.regularMaterial)
    }

    @ViewBuilder
    private func row(_ config: BepInExConfig.DiscoveredConfig) -> some View {
        Button {
            onSelect(config)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.associatedFullName ?? config.fileName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if config.associatedFullName != nil {
                        Text(config.fileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

/// Per-file BepInEx `.cfg` editor: parses the file (`BepInExConfig`) and
/// renders each section as a grouped form of typed controls matching the
/// setting's own `# Setting type:` — a `Toggle` for booleans, a `Picker`
/// for an enumerated `# Acceptable values:` list, a labeled binding
/// display plus raw text field for `KeyboardShortcut`, and a plain text
/// field for everything else (numeric types included — no `NumberFormatter`
/// round trip, so what's typed is exactly what's written back).
///
/// Saves surgically via `BepInExConfig.applying(values:to:)`: at save time
/// the file is re-read from disk and the user's edits are re-targeted by
/// (section, key) — not the line index captured when the sheet opened —
/// so a rewrite that happened while the editor was open (Valheim mods
/// commonly rewrite their own `.cfg` at game exit) doesn't get clobbered
/// by a stale snapshot, and doesn't silently revert the user's own save
/// either. Every comment, blank line, and untouched entry — whether from
/// the original open or added by that external rewrite — is preserved
/// byte-for-byte.
struct ConfigEditorView: View {
    let url: URL
    let title: String

    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeStore.self) private var themeStore

    @State private var originalText: String?
    @State private var configFile: BepInExConfig.ConfigFile = .empty
    /// Entry id -> edited raw value, only for entries whose value actually
    /// differs from what was parsed. Empty means no unsaved changes.
    @State private var editedValues: [String: String] = [:]
    @State private var loadError: String?
    @State private var statusLine: String?
    @State private var confirmingClose = false
    @State private var busy = false

    /// The file's on-disk modification date at the moment it was last
    /// (re)loaded — the baseline `pollForExternalChanges()` compares
    /// against to detect a rewrite that happened while this sheet stayed
    /// open.
    @State private var loadedModificationDate: Date?
    /// True once polling has noticed the file changed on disk *while the
    /// user had unsaved edits* — surfaced as a non-blocking banner rather
    /// than clobbering their edits with an auto-reload. Cleared on the
    /// next successful load (including the reload a save performs).
    @State private var externalChangeDetected = false
    /// True while `pgrep -x Valheim` finds the game running, polled
    /// alongside the staleness check — the game only reads `.cfg` files at
    /// startup, so a save while it's running doesn't take effect until the
    /// next launch, and some mods rewrite their own config at exit.
    @State private var valheimRunning = false

    private var isDirty: Bool { !editedValues.isEmpty }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { requestClose() }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        if isDirty {
                            AuroraBadge(text: "Unsaved", systemImage: "circle.fill")
                        }
                        Button("Reveal in Finder") { revealInFinder() }
                        Button("Revert") { load() }
                            .disabled(!isDirty)
                        Button("Save") { save() }
                            .disabled(!isDirty || busy)
                    }
                }
                .safeAreaInset(edge: .top) {
                    VStack(spacing: 0) {
                        if valheimRunning {
                            InfoBanner(
                                text: "Valheim is running — changes are saved to the file, but the game only reads configs at startup, so they take effect next launch. Some mods rewrite their config on exit and may overwrite what you save now.",
                                systemImage: "gamecontroller.fill",
                                tint: .orange
                            )
                        }
                        if externalChangeDetected {
                            InfoBanner(
                                text: "This file changed on disk (the game may have rewritten it). Your unsaved edits will be re-applied on top when you save.",
                                systemImage: "arrow.triangle.2.circlepath",
                                tint: .blue
                            )
                        }
                    }
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
        .frame(minWidth: 560, minHeight: 480)
        .presentationBackground(.regularMaterial)
        .task { load() }
        .task { await pollForExternalChanges() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkForExternalChange()
        }
        .interactiveDismissDisabled(isDirty)
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: $confirmingClose
        ) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have unsaved edits to \(url.lastPathComponent).")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if configFile.sections.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                ForEach(configFile.sections) { section in
                    Section(section.name) {
                        ForEach(section.entries) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func entryRow(_ entry: BepInExConfig.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            control(for: entry)

            if let description = entry.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if let defaultValue = entry.defaultValue {
                    Text("Default: \(defaultValue)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let range = entry.acceptableRange {
                    Text(range)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if let defaultValue = entry.defaultValue, currentValue(for: entry) != defaultValue {
                    Button("Reset to Default") {
                        setCurrentValue(defaultValue, for: entry)
                    }
                    .font(.caption2.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(themeStore.current.accentGradient)
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func control(for entry: BepInExConfig.Entry) -> some View {
        if entry.isBoolean {
            Toggle(entry.key, isOn: Binding(
                get: { currentBoolValue(for: entry) },
                set: { setCurrentValue(entry.rawValue(for: $0), for: entry) }
            ))
        } else if let acceptableValues = entry.acceptableValues, !acceptableValues.isEmpty {
            Picker(entry.key, selection: Binding(
                get: { currentValue(for: entry) },
                set: { setCurrentValue($0, for: entry) }
            )) {
                ForEach(acceptableValues, id: \.self) { value in
                    Text(value).tag(value)
                }
            }
        } else if entry.settingType == "KeyboardShortcut" {
            keyboardShortcutControl(for: entry)
        } else {
            LabeledContent(entry.key) {
                TextField("Value", text: Binding(
                    get: { currentValue(for: entry) },
                    set: { setCurrentValue($0, for: entry) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(Self.isNumericType(entry.settingType) ? .body.monospacedDigit() : .body)
                .multilineTextAlignment(Self.isNumericType(entry.settingType) ? .trailing : .leading)
                .frame(maxWidth: Self.isNumericType(entry.settingType) ? 140 : .infinity)
            }
        }
    }

    @ViewBuilder
    private func keyboardShortcutControl(for entry: BepInExConfig.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.key)
                Spacer()
                Text(currentValue(for: entry).isEmpty ? "(none)" : currentValue(for: entry))
                    .font(.body.monospaced().weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            TextField("e.g. H + LeftShift", text: Binding(
                get: { currentValue(for: entry) },
                set: { setCurrentValue($0, for: entry) }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }

    private static func isNumericType(_ settingType: String?) -> Bool {
        guard let settingType else { return false }
        return ["Single", "Double", "Int32", "UInt32", "Int64", "UInt64", "Int16", "UInt16", "Byte", "SByte"].contains(settingType)
    }

    // MARK: - Edited-value plumbing

    private func currentValue(for entry: BepInExConfig.Entry) -> String {
        editedValues[entry.id] ?? entry.rawValue
    }

    private func currentBoolValue(for entry: BepInExConfig.Entry) -> Bool {
        let raw = currentValue(for: entry)
        return raw.trimmingCharacters(in: .whitespaces).lowercased() == "true" || raw.trimmingCharacters(in: .whitespaces).lowercased() == "on"
    }

    private func setCurrentValue(_ value: String, for entry: BepInExConfig.Entry) {
        if value == entry.rawValue {
            editedValues.removeValue(forKey: entry.id)
        } else {
            editedValues[entry.id] = value
        }
    }

    // MARK: - Load / save / close

    private func load() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            loadError = "Couldn't read \(url.lastPathComponent)."
            return
        }
        originalText = text
        configFile = BepInExConfig.parse(text)
        editedValues = [:]
        loadError = nil
        statusLine = nil
        externalChangeDetected = false
        loadedModificationDate = Self.modificationDate(of: url)
    }

    /// Saves by re-reading the file from disk right now and re-targeting
    /// every pending edit by (section, key) via
    /// `BepInExConfig.applying(values:to:)` — never against the
    /// `originalText` snapshot from when the sheet opened. That snapshot
    /// can be stale: Valheim mods commonly rewrite their own `.cfg` when
    /// the game exits, and that can happen at any point while this editor
    /// sits open. Saving against a stale snapshot would silently clobber
    /// whatever the game just wrote; re-reading here means the on-disk
    /// state right before the write — including anything just written
    /// externally — is what the user's edits land on top of. Edits whose
    /// (section, key) no longer exists in the current file are skipped and
    /// reported rather than silently dropped.
    private func save() {
        let edits: [BepInExConfig.KeyedChange] = configFile.allEntries.compactMap { entry in
            guard let edited = editedValues[entry.id] else { return nil }
            return BepInExConfig.KeyedChange(section: entry.section, key: entry.key, value: edited)
        }
        guard !edits.isEmpty else { return }

        busy = true
        defer { busy = false }

        guard let currentDiskText = try? String(contentsOf: url, encoding: .utf8) else {
            statusLine = "Couldn't save: \(url.lastPathComponent) is no longer readable."
            return
        }

        let result = BepInExConfig.applying(values: edits, to: currentDiskText)
        do {
            try result.text.write(to: url, atomically: true, encoding: .utf8)
            load()
            statusLine = Self.saveStatusLine(skippedCount: result.skipped.count, valheimRunning: valheimRunning)
        } catch {
            statusLine = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private static func saveStatusLine(skippedCount: Int, valheimRunning: Bool) -> String {
        var line = "Saved."
        if skippedCount == 1 {
            line += " 1 setting no longer exists and was skipped."
        } else if skippedCount > 1 {
            line += " \(skippedCount) settings no longer exist and were skipped."
        }
        if valheimRunning {
            line += " (applies next game launch)"
        }
        return line
    }

    private func requestClose() {
        if isDirty {
            confirmingClose = true
        } else {
            dismiss()
        }
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Staleness / game-running polling

    /// Runs for as long as this sheet is on screen (SwiftUI cancels a
    /// `.task` automatically when its view disappears): every ~2s, checks
    /// whether the file changed on disk since it was last loaded and
    /// whether Valheim is currently running.
    private func pollForExternalChanges() async {
        while !Task.isCancelled {
            checkForExternalChange()
            await refreshValheimRunning()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// If the file's modification date has moved past what it was at last
    /// load: silently reloads when there are no unsaved edits (nothing for
    /// the user to lose), or — when there are — just raises
    /// `externalChangeDetected` so a banner can explain that the pending
    /// edits will still be re-applied correctly on top at save time (see
    /// `save()`), without yanking the file out from under whatever they're
    /// mid-edit on.
    private func checkForExternalChange() {
        guard let loadedModificationDate,
              let currentModificationDate = Self.modificationDate(of: url),
              currentModificationDate > loadedModificationDate
        else { return }

        if isDirty {
            externalChangeDetected = true
        } else {
            load()
        }
    }

    private func refreshValheimRunning() async {
        let running = (try? await ShellRunner.run("/usr/bin/pgrep", ["-x", "Valheim"]))?.status == 0
        if running != valheimRunning {
            valheimRunning = running
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// A quiet, non-blocking full-width notice strip — used for the
/// "Valheim is running" and "file changed on disk" states in
/// `ConfigEditorView`, neither of which should block editing or saving.
private struct InfoBanner: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.14))
    }
}
