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
/// Saves surgically via `BepInExConfig.applying`: only the specific
/// changed `Key = value` lines are rewritten, so every comment, blank
/// line, and untouched entry in the file is preserved byte-for-byte.
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
    }

    private func save() {
        guard let originalText else { return }
        busy = true
        defer { busy = false }

        var changes: [Int: String] = [:]
        for entry in configFile.allEntries {
            if let edited = editedValues[entry.id] {
                changes[entry.lineIndex] = edited
            }
        }
        guard !changes.isEmpty else { return }

        let newText = BepInExConfig.applying(changes, to: originalText)
        do {
            try newText.write(to: url, atomically: true, encoding: .utf8)
            load()
            statusLine = "Saved."
        } catch {
            statusLine = "Couldn't save: \(error.localizedDescription)"
        }
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
}
