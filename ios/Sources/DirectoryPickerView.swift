import Foundation
import SwiftUI

enum DirectoryPickerRecentStore {
    private static let defaultsKey = "helm.new-session.recent-directories"
    private static let maxRecentDirectories = 3

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    static func record(_ directory: String) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var updated = load().filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        updated.insert(trimmed, at: 0)
        if updated.count > maxRecentDirectories {
            updated.removeLast(updated.count - maxRecentDirectories)
        }
        UserDefaults.standard.set(updated, forKey: defaultsKey)
    }
}

private struct DirectoryBreadcrumb: Identifiable {
    let path: String
    let title: String

    var id: String { path }
}

struct DirectoryPickerView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var pathFieldFocused: Bool

    let initialPath: String
    let onSelect: (String) -> Void

    @State private var currentPath: String
    @State private var suggestions: [DirectorySuggestion] = []
    @State private var recentDirectories: [String]
    @State private var showHidden = false
    @State private var isLoading = false
    @State private var loadError: String?

    init(
        initialPath: String,
        onSelect: @escaping (String) -> Void
    ) {
        self.initialPath = initialPath
        self.onSelect = onSelect
        _currentPath = State(initialValue: initialPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "~/" : initialPath)
        _recentDirectories = State(initialValue: DirectoryPickerRecentStore.load())
    }

    private var exactSuggestion: DirectorySuggestion? {
        suggestions.first(where: \.isExact)
    }

    private var childSuggestions: [DirectorySuggestion] {
        filteredSuggestions.filter { !$0.isExact }
    }

    private var filteredSuggestions: [DirectorySuggestion] {
        suggestions.filter { suggestion in
            if suggestion.isExact {
                return true
            }
            return showHidden || !lastPathComponent(of: suggestion.path).hasPrefix(".")
        }
    }

    private var selectedPath: String {
        exactSuggestion?.path ?? currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSelect: Bool {
        exactSuggestion != nil
    }

    private var breadcrumbs: [DirectoryBreadcrumb] {
        let path = exactSuggestion?.path ?? currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return [] }
        guard path != "/" else { return [DirectoryBreadcrumb(path: "/", title: "/")] }

        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var segments: [DirectoryBreadcrumb] = [DirectoryBreadcrumb(path: "/", title: "/")]
        var runningPath = ""
        for component in components {
            runningPath += "/\(component)"
            segments.append(DirectoryBreadcrumb(path: runningPath, title: component))
        }
        return segments
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.badge.gearshape")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppPalette.accent)

                            TextField("Working directory", text: $currentPath)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($pathFieldFocused)
                                .accessibilityIdentifier("newsession.directoryPicker.pathField")
                        }
                        .padding(12)
                        .inputFieldSurface(cornerRadius: 16)

                        if let exactSuggestion {
                            HStack(spacing: 8) {
                                Text(exactSuggestion.displayPath)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(AppPalette.secondaryText)
                                    .lineLimit(1)

                                Text("Ready")
                                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                                    .foregroundStyle(AppPalette.accent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(AppPalette.accent.opacity(0.12), in: Capsule())

                                Spacer()
                            }
                        }

                        if !breadcrumbs.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(breadcrumbs) { crumb in
                                        Button {
                                            currentPath = crumb.path
                                        } label: {
                                            Text(crumb.title)
                                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                                .foregroundStyle(crumb.path == selectedPath ? AppPalette.primaryText : AppPalette.secondaryText)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 7)
                                                .subtleActionCapsule()
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("newsession.directoryPicker.breadcrumb.\(crumb.path)")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                if !recentDirectories.isEmpty {
                    Section("Recent") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(recentDirectories, id: \.self) { directory in
                                    Button {
                                        currentPath = directory
                                    } label: {
                                        Text(displayPath(directory))
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(AppPalette.primaryText)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 9)
                                            .subtleActionCapsule()
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("newsession.directoryPicker.recent.\(directory)")
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if let exactSuggestion {
                    Section("Current Folder") {
                        directoryRow(
                            displayPath: exactSuggestion.displayPath,
                            detail: "Select this folder",
                            symbolName: "checkmark.circle.fill",
                            tint: AppPalette.accent
                        ) {
                            selectDirectory(exactSuggestion.path)
                        }
                        .accessibilityIdentifier("newsession.directoryPicker.current")
                    }
                }

                Section(childSuggestions.isEmpty ? "Directories" : "Folders Inside") {
                    if isLoading {
                        WorkingStatusLabel(
                            text: "Loading folders…",
                            preset: .rollingLine,
                            tint: AppPalette.secondaryText
                        )
                        .padding(.vertical, 8)
                    } else if let loadError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(loadError)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(AppPalette.secondaryText)
                            Button("Retry") {
                                Task { await loadSuggestions() }
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 8)
                    } else if childSuggestions.isEmpty {
                        Text("No child directories here yet.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(AppPalette.secondaryText)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(childSuggestions) { suggestion in
                            directoryRow(
                                displayPath: suggestion.displayPath,
                                detail: "Open folder",
                                symbolName: "folder.fill",
                                tint: AppPalette.secondaryText
                            ) {
                                currentPath = suggestion.path
                            }
                            .accessibilityIdentifier("newsession.directoryPicker.child.\(suggestion.path)")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Choose Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        navigateUp()
                    } label: {
                        Image(systemName: "arrow.up.to.line")
                    }
                    .disabled(!canNavigateUp)
                    .accessibilityLabel("Go Up")
                    .accessibilityIdentifier("newsession.directoryPicker.up")

                    Button {
                        showHidden.toggle()
                    } label: {
                        Image(systemName: showHidden ? "eye.fill" : "eye.slash")
                    }
                    .accessibilityLabel(showHidden ? "Hide Hidden Folders" : "Show Hidden Folders")
                    .accessibilityIdentifier("newsession.directoryPicker.hidden")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Selected")
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(AppPalette.secondaryText)
                        Text(displayPath(selectedPath))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(AppPalette.primaryText)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button("Use This Folder") {
                        selectDirectory(selectedPath)
                    }
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(AppPalette.accent, in: Capsule())
                    .foregroundStyle(.white)
                    .disabled(!canSelect)
                    .opacity(canSelect ? 1 : 0.55)
                    .accessibilityIdentifier("newsession.directoryPicker.select")
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(.ultraThinMaterial)
            }
            .task {
                await loadSuggestions()
            }
            .task(id: currentPath) {
                do {
                    try await Task.sleep(nanoseconds: 120_000_000)
                } catch {
                    return
                }
                await loadSuggestions()
            }
        }
    }

    private var canNavigateUp: Bool {
        selectedPath != "/" && selectedPath.hasPrefix("/")
    }

    @ViewBuilder
    private func directoryRow(
        displayPath: String,
        detail: String,
        symbolName: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayPath)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(AppPalette.primaryText)
                        .lineLimit(1)

                    Text(detail)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(AppPalette.secondaryText)
                }

                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadSuggestions() async {
        let interval = HelmLogger.uiSignposter.beginInterval("DirectoryPickerLoad")
        defer { HelmLogger.uiSignposter.endInterval("DirectoryPickerLoad", interval) }

        let query = currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "~/" : currentPath
        isLoading = true
        defer { isLoading = false }

        do {
            suggestions = try await store.fetchDirectorySuggestions(prefix: query)
            loadError = nil
        } catch {
            suggestions = []
            loadError = "Directory listing unavailable right now."
        }
    }

    private func navigateUp() {
        guard canNavigateUp else { return }

        let normalized = selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != "/" else { return }
        let parent = URL(fileURLWithPath: normalized).deletingLastPathComponent().path
        currentPath = parent.isEmpty ? "/" : parent
    }

    private func selectDirectory(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        DirectoryPickerRecentStore.record(trimmed)
        recentDirectories = DirectoryPickerRecentStore.load()
        onSelect(trimmed)
        dismiss()
    }

    private func lastPathComponent(of path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }
        return path
    }
}
