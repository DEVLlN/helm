import SwiftUI
import UIKit

enum SessionsRoute: Hashable {
    case thread(String)
    case newSession
    case archivedSessions
}

private enum SessionListSection: String {
    case active
    case recent
}

private struct SessionWorkspaceGroup: Identifiable {
    let section: SessionListSection
    let cwd: String
    let displayPath: String
    let title: String
    let threads: [RemoteThread]

    var id: String { "\(section.rawValue)|\(cwd)" }
}

private enum SessionCardPosition {
    case standalone
    case groupHeaderCollapsed
    case groupHeaderExpanded
    case groupRowFirst
    case groupRowMiddle
    case groupRowLast
    case groupRowSingle
}

private enum SessionSwipeAction {
    case moveToRecent
    case archive
}

private extension View {
    func plainListRow(topPadding: CGFloat = 5, bottomPadding: CGFloat = 5) -> some View {
        self
            .listRowInsets(EdgeInsets(top: topPadding, leading: 16, bottom: bottomPadding, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

struct SessionsView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sessionSearchQuery = ""
    @State private var manuallyCollapsedWorkspaceGroupIDs = Set<String>()
    @State private var manuallyExpandedWorkspaceGroupIDs = Set<String>()
    @State private var pendingActiveSessionScroll = true
    @State private var debugLaunchThreadHandled = false
    @State private var renamingThreadID: String?
    @State private var renameDraft = ""
    @State private var activeSwipedThreadID: String?
    @State private var sessionSwipeOffsets: [String: CGFloat] = [:]

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
    private static let debugOpenThreadArgument = "-helm-open-thread"
    private static let sessionSwipeCommitDistance: CGFloat = 112
    private static let sessionSwipeMaxOffset: CGFloat = 136
    private static let sessionSwipeCommitDelay: TimeInterval = 0.12

    var onOpenSettings: () -> Void

    var body: some View {
        NavigationStack(path: Binding(
            get: { store.sessionsNavigationPath },
            set: { store.sessionsNavigationPath = $0 }
        )) {
            Group {
                if store.visibleThreads.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    headerActionButton(systemName: "gearshape.fill", accessibilityLabel: "Settings") {
                        onOpenSettings()
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    headerActionButton(systemName: "archivebox.fill", accessibilityLabel: "Archived Sessions") {
                        setSingleRoute(.archivedSessions)
                    }

                    headerActionButton(systemName: "plus", accessibilityLabel: "New Session") {
                        setSingleRoute(.newSession)
                    }
                }
            }
            .navigationDestination(for: SessionsRoute.self) { route in
                switch route {
                case .thread(let threadID):
                    SessionDetailView(threadID: threadID)
                case .newSession:
                    NewSessionView(initialDraft: store.defaultNewSessionDraft())
                case .archivedSessions:
                    ArchivedSessionsView()
                }
            }
            .alert("Rename Session", isPresented: renameAlertPresented) {
                TextField("Session name", text: $renameDraft)

                Button("Cancel", role: .cancel) {
                    clearRenameDraft()
                }

                Button("Save") {
                    Task { await submitRename() }
                }
            } message: {
                Text("Set a clearer title for this session.")
            }
        }
        .onChange(of: store.sessionAutoCollapseEnabled) { _, enabled in
            withAnimation(groupExpandCollapseAnimation) {
                resetWorkspaceGroupOverrides(forAutoCollapseEnabled: enabled)
            }
        }
        .onChange(of: displayedWorkspaceGroupIDs) { _, _ in
            pruneWorkspaceGroupOverrides()
        }
        .task(id: displayedThreadIDs) {
            maybeOpenDebugLaunchThread()
        }
    }

    // MARK: - Session list

    private var sessionList: some View {
        ScrollViewReader { proxy in
            List {
                if store.needsSetupAttention {
                    compactSetupBanner
                        .plainListRow()
                }

                if store.shouldShowOnboarding {
                    onboardingCard
                        .plainListRow()
                }

                sessionSearchBar
                    .plainListRow(topPadding: 6, bottomPadding: 6)

                if filteredActiveWorkspaceGroups.isEmpty && filteredRecentWorkspaceGroups.isEmpty {
                    searchEmptyState
                        .plainListRow(topPadding: 20, bottomPadding: 10)
                }

                if !filteredActiveWorkspaceGroups.isEmpty {
                    Section {
                        workspaceGroups(filteredActiveWorkspaceGroups)
                    } header: {
                        sectionDivider("Active")
                    }
                }

                if !filteredRecentWorkspaceGroups.isEmpty {
                    Section {
                        workspaceGroups(filteredRecentWorkspaceGroups)
                    } header: {
                        sectionDivider("Recent")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
            .contentMargins(.bottom, 80, for: .scrollContent)
            .environment(\.defaultMinListHeaderHeight, 0)
            .refreshable {
                pendingActiveSessionScroll = true
                await refreshSessionList()
            }
            .onChange(of: store.selectedThreadID) { _, _ in
                scrollToActiveSession(using: proxy)
            }
            .onChange(of: displayedThreadIDs) { _, _ in
                guard pendingActiveSessionScroll else { return }
                scrollToActiveSession(using: proxy, animated: false)
                pendingActiveSessionScroll = false
                maybeOpenDebugLaunchThread()
            }
        }
    }

    private func sessionRowButton(
        _ thread: RemoteThread,
        section: SessionListSection,
        position: SessionCardPosition
    ) -> some View {
        swipeableSessionRow(thread, section: section, position: position)
        .id(sessionScrollID(for: thread.id))
        .accessibilityIdentifier("sessions.thread.\(thread.id)")
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                beginRename(thread)
            }

            switch section {
            case .active:
                Button("Move to Recent", systemImage: "clock.arrow.circlepath") {
                    store.moveSessionToRecent(thread.id)
                }
            case .recent:
                Button("Archive", systemImage: "archivebox.fill", role: .destructive) {
                    Task { await store.archiveSession(thread.id) }
                }
            }
        }
    }

    private func swipeableSessionRow(
        _ thread: RemoteThread,
        section: SessionListSection,
        position: SessionCardPosition
    ) -> some View {
        let action = sessionSwipeAction(for: section)
        let offset = sessionSwipeOffset(for: thread.id)
        let progress = min(1, offset / Self.sessionSwipeCommitDistance)

        return ZStack(alignment: .leading) {
            sessionSwipeBackground(action: action, progress: progress, position: position)

            sessionRow(thread, position: position)
                .offset(x: offset)
        }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(sessionSwipeGesture(for: thread, section: section))
        .onTapGesture {
            handleSessionRowTap(thread.id)
        }
        .animation(groupExpandCollapseAnimation, value: offset)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(sessionSwipeAccessibilityTitle(for: action))) {
            commitSessionSwipeAction(thread, section: section)
        }
    }

    private func sessionSwipeBackground(
        action: SessionSwipeAction,
        progress: CGFloat,
        position: SessionCardPosition
    ) -> some View {
        let tint = sessionSwipeTint(for: action)

        return HStack(spacing: 10) {
            Image(systemName: sessionSwipeSystemImage(for: action))
                .font(.system(.subheadline, design: .rounded, weight: .semibold))

            Text(sessionSwipeTitle(for: action))
                .font(.system(.caption, design: .rounded, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.leading, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            sessionCardShape(position)
                .fill(tint.opacity(0.12 + (0.1 * Double(progress))))
        )
    }

    private func sessionSwipeGesture(for thread: RemoteThread, section: SessionListSection) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                let horizontalDistance = value.translation.width
                let verticalDistance = abs(value.translation.height)
                guard horizontalDistance > 0, horizontalDistance > verticalDistance else { return }

                if let activeSwipedThreadID, activeSwipedThreadID != thread.id {
                    resetSessionSwipe(activeSwipedThreadID)
                }

                activeSwipedThreadID = thread.id
                sessionSwipeOffsets[thread.id] = min(Self.sessionSwipeMaxOffset, max(0, horizontalDistance))
            }
            .onEnded { value in
                let committedDistance = max(value.translation.width, value.predictedEndTranslation.width)
                if committedDistance >= Self.sessionSwipeCommitDistance {
                    completeSessionSwipe(thread, section: section)
                } else {
                    resetSessionSwipe(thread.id)
                }
            }
    }

    private func handleSessionRowTap(_ threadID: String) {
        if sessionSwipeOffset(for: threadID) > 0 {
            resetSessionSwipe(threadID)
            return
        }

        openThreadFromSessionsList(threadID)
    }

    private func completeSessionSwipe(_ thread: RemoteThread, section: SessionListSection) {
        withAnimation(groupExpandCollapseAnimation) {
            sessionSwipeOffsets[thread.id] = Self.sessionSwipeMaxOffset
        }

        let delay = reduceMotion ? 0 : Self.sessionSwipeCommitDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            commitSessionSwipeAction(thread, section: section)
            resetSessionSwipe(thread.id)
        }
    }

    private func commitSessionSwipeAction(_ thread: RemoteThread, section: SessionListSection) {
        switch section {
        case .active:
            store.moveSessionToRecent(thread.id)
        case .recent:
            Task { await store.archiveSession(thread.id) }
        }
    }

    private func resetSessionSwipe(_ threadID: String) {
        withAnimation(groupExpandCollapseAnimation) {
            sessionSwipeOffsets[threadID] = 0
        }

        if activeSwipedThreadID == threadID {
            activeSwipedThreadID = nil
        }
    }

    private func sessionSwipeOffset(for threadID: String) -> CGFloat {
        sessionSwipeOffsets[threadID] ?? 0
    }

    private func sessionSwipeAction(for section: SessionListSection) -> SessionSwipeAction {
        switch section {
        case .active:
            return .moveToRecent
        case .recent:
            return .archive
        }
    }

    private func sessionSwipeTitle(for action: SessionSwipeAction) -> String {
        switch action {
        case .moveToRecent:
            return "Recent"
        case .archive:
            return "Archive"
        }
    }

    private func sessionSwipeAccessibilityTitle(for action: SessionSwipeAction) -> String {
        switch action {
        case .moveToRecent:
            return "Move to Recent"
        case .archive:
            return "Archive"
        }
    }

    private func sessionSwipeSystemImage(for action: SessionSwipeAction) -> String {
        switch action {
        case .moveToRecent:
            return "clock.arrow.circlepath"
        case .archive:
            return "archivebox.fill"
        }
    }

    private func sessionSwipeTint(for action: SessionSwipeAction) -> Color {
        switch action {
        case .moveToRecent:
            return AppPalette.accent
        case .archive:
            return AppPalette.warning
        }
    }

    // MARK: - Session row

    private func sessionRow(
        _ thread: RemoteThread,
        position: SessionCardPosition = .standalone
    ) -> some View {
        let phase = store.runtimeByThreadID[thread.id]?.phase ?? "idle"
        let updatedAt = Date(timeIntervalSince1970: thread.updatedAt / 1000)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                sessionStatusLead(phase)

                VStack(alignment: .leading, spacing: 6) {
                    Text(stableThreadDisplayTitle(thread))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(AppPalette.primaryText)
                        .lineLimit(1)

                    Text(relativeActivitySummary(updatedAt))
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(AppPalette.secondaryText)
                        .transaction { transaction in
                            transaction.animation = nil
                        }

                    sessionStatusChipRow(thread, phase: phase)
                        .padding(.top, 1)
                        .accessibilityIdentifier("sessions.threadChips.\(thread.id)")
                }

                Spacer(minLength: 0)
            }

            StableSessionPreviewBlock(
                threadID: thread.id,
                preview: thread.preview,
                isLive: sessionPreviewAppearsLive(thread, phase: phase),
                font: .system(.caption, design: .monospaced),
                foregroundColor: AppPalette.secondaryText,
                lineLimit: 3,
                panelPadding: 10
            )
        }
        .padding(14)
        .background(
            sessionCardShape(position)
                .fill(AppPalette.panel)
        )
        .overlay(
            sessionCardBorder(position)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessions.sessionRow.\(thread.id)")
    }

    @ViewBuilder
    private func workspaceGroups(_ groups: [SessionWorkspaceGroup]) -> some View {
        ForEach(groups) { group in
            workspaceGroupHeader(group)
                .plainListRow(
                    topPadding: 6,
                    bottomPadding: isWorkspaceGroupCollapsed(group.id) ? 4 : 0
                )
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    groupSwipeActions(group)
                }

            if !isWorkspaceGroupCollapsed(group.id) {
                ForEach(Array(group.threads.enumerated()), id: \.element.id) { index, thread in
                    sessionRowButton(
                        thread,
                        section: group.section,
                        position: cardPosition(forThreadAt: index, count: group.threads.count)
                    )
                        .transition(groupRowTransition)
                        .plainListRow(
                            topPadding: 0,
                            bottomPadding: index == group.threads.count - 1 ? 4 : 0
                        )
                }
            }
        }
    }

    @ViewBuilder
    private func groupSwipeActions(_ group: SessionWorkspaceGroup) -> some View {
        switch group.section {
        case .active:
            Button {
                moveGroupToRecent(group)
            } label: {
                Label("Recent", systemImage: "clock.arrow.circlepath")
            }
            .tint(AppPalette.secondaryText)
        case .recent:
            Button(role: .destructive) {
                Task { await archiveGroup(group) }
            } label: {
                Label("Archive", systemImage: "archivebox.fill")
            }
            .tint(AppPalette.warning)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 60)

                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(AppPalette.secondaryText)

                    Text("No sessions")
                        .font(.system(.title3, design: .rounded, weight: .semibold))

                    Text("Sessions from helm Bridge will appear here. Start one from the Mac, or use the + button to launch a new session.")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(AppPalette.secondaryText)
                        .multilineTextAlignment(.center)
                }

                if store.needsSetupAttention {
                    compactSetupBanner
                }

                if store.shouldShowOnboarding {
                    onboardingCard
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 80)
        }
        .refreshable {
            await refreshSessionList()
        }
    }

    // MARK: - Setup banner

    private var compactSetupBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppPalette.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.setupAttentionTitle)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                Text(store.setupAttentionDetail)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(2)
            }

            Spacer()

            Button("Fix") {
                onOpenSettings()
            }
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .tintedCapsule(tint: AppPalette.warning)
            .foregroundStyle(AppPalette.warning)
        }
        .padding(12)
        .sectionSurface(cornerRadius: 16)
    }

    // MARK: - Onboarding card

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Welcome to helm")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                Spacer()
                Button {
                    store.dismissOnboarding()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppPalette.secondaryText)
                }
                .buttonStyle(.plain)
            }

            Text("helm is the remote surface for Codex on your Mac.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(AppPalette.secondaryText)

            HStack(spacing: 10) {
                Button("Read Pairing") {
                    Task { await store.readLocalPairing() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .subtleActionCapsule()

                Button("Settings") {
                    onOpenSettings()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(AppPalette.accent, in: Capsule())
                .foregroundStyle(.white)
            }
        }
        .padding(16)
        .sectionSurface(cornerRadius: 20)
    }

    // MARK: - Helpers

    private var filteredActiveWorkspaceGroups: [SessionWorkspaceGroup] {
        workspaceGroups(for: store.activeSessionThreads, section: .active)
    }

    private var filteredRecentWorkspaceGroups: [SessionWorkspaceGroup] {
        workspaceGroups(for: store.recentSessionThreads, section: .recent)
    }

    private var displayedThreadIDs: [String] {
        filteredActiveWorkspaceGroups.flatMap(\.threads).map(\.id) +
            filteredRecentWorkspaceGroups.flatMap(\.threads).map(\.id)
    }

    private var displayedWorkspaceGroupIDs: Set<String> {
        Set(filteredActiveWorkspaceGroups.map(\.id) + filteredRecentWorkspaceGroups.map(\.id))
    }

    private var sessionSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppPalette.secondaryText)

            TextField("Search sessions", text: $sessionSearchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.subheadline, design: .rounded))

            if !sessionSearchQuery.isEmpty {
                Button {
                    sessionSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppPalette.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .inputFieldSurface(cornerRadius: 16)
        .accessibilityIdentifier("sessions.searchField")
    }

    private var searchEmptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No matching sessions")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(AppPalette.primaryText)

            Text("Try a different name, workspace, backend, or preview phrase.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(AppPalette.secondaryText)
        }
        .padding(16)
        .sectionSurface(cornerRadius: 18)
    }

    private func workspaceGroups(
        for threads: [RemoteThread],
        section: SessionListSection
    ) -> [SessionWorkspaceGroup] {
        let threadSort = section == .active ? sessionAlphabeticalPrecedes : sessionRecencyPrecedes
        let matchingThreads = threads
            .filter(threadMatchesSearch(_:))
            .sorted(by: threadSort)
        var groups: [SessionWorkspaceGroup] = []
        var groupIndexByCWD: [String: Int] = [:]

        for thread in matchingThreads {
            let workspaceKey = workspaceGroupPath(for: thread)
            let title = workspaceGroupTitle(for: workspaceKey)
            let displayPath = displayWorkspacePath(workspaceKey)

            if let index = groupIndexByCWD[workspaceKey] {
                var updatedThreads = groups[index].threads
                updatedThreads.append(thread)
                groups[index] = SessionWorkspaceGroup(
                    section: section,
                    cwd: workspaceKey,
                    displayPath: displayPath,
                    title: title,
                    threads: updatedThreads
                )
            } else {
                groupIndexByCWD[workspaceKey] = groups.count
                groups.append(
                    SessionWorkspaceGroup(
                        section: section,
                        cwd: workspaceKey,
                        displayPath: displayPath,
                        title: title,
                        threads: [thread]
                    )
                )
            }
        }

        return groups
            .map { group in
                SessionWorkspaceGroup(
                    section: group.section,
                    cwd: group.cwd,
                    displayPath: group.displayPath,
                    title: group.title,
                    threads: group.threads.sorted(by: threadSort)
                )
            }
            .sorted { lhs, rhs in
                if section == .active {
                    let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
                    if titleOrder != .orderedSame {
                        return titleOrder == .orderedAscending
                    }
                    return lhs.cwd.localizedStandardCompare(rhs.cwd) == .orderedAscending
                }

                let lhsUpdatedAt = lhs.threads.first?.updatedAt ?? 0
                let rhsUpdatedAt = rhs.threads.first?.updatedAt ?? 0
                if lhsUpdatedAt == rhsUpdatedAt {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhsUpdatedAt > rhsUpdatedAt
            }
    }

    private func sessionRecencyPrecedes(_ lhs: RemoteThread, _ rhs: RemoteThread) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return threadDisplayName(lhs).localizedCaseInsensitiveCompare(threadDisplayName(rhs)) == .orderedAscending
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    private func sessionAlphabeticalPrecedes(_ lhs: RemoteThread, _ rhs: RemoteThread) -> Bool {
        let titleOrder = stableThreadSortTitle(lhs).localizedStandardCompare(stableThreadSortTitle(rhs))
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }

        let lhsWorkspace = workspaceGroupPath(for: lhs)
        let rhsWorkspace = workspaceGroupPath(for: rhs)
        let workspaceOrder = lhsWorkspace.localizedStandardCompare(rhsWorkspace)
        if workspaceOrder != .orderedSame {
            return workspaceOrder == .orderedAscending
        }

        return lhs.id < rhs.id
    }

    private func stableThreadSortTitle(_ thread: RemoteThread) -> String {
        let trimmedName = thread.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty {
            return trimmedName
        }

        return workspaceGroupPath(for: thread)
    }

    private func stableThreadDisplayTitle(_ thread: RemoteThread) -> String {
        let trimmedName = thread.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty {
            return trimmedName
        }

        return "\(displayWorkspacePath(workspaceGroupPath(for: thread))) · \(shortThreadID(thread.id))"
    }

    private func shortThreadID(_ id: String) -> String {
        String(id.suffix(5)).uppercased()
    }

    private func threadDisplayName(_ thread: RemoteThread) -> String {
        let trimmedName = thread.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty {
            return trimmedName
        }
        let trimmedPreview = thread.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPreview.isEmpty {
            return trimmedPreview
        }
        return "Untitled Session"
    }

    private func threadMatchesSearch(_ thread: RemoteThread) -> Bool {
        let query = sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        let haystack = [
            thread.name ?? "",
            thread.preview,
            thread.cwd,
            thread.workspacePath ?? "",
            thread.backendLabel ?? "",
            thread.launchSource ?? "",
        ]
            .joined(separator: "\n")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        return haystack.contains(
            query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        )
    }

    private func workspaceGroupPath(for thread: RemoteThread) -> String {
        let normalizedWorkspacePath = thread.workspacePath?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedWorkspacePath.isEmpty {
            return normalizedWorkspacePath
        }

        let normalizedCWD = thread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedCWD.isEmpty ? "workspace" : normalizedCWD
    }

    private func workspaceGroupTitle(for path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        return components.last ?? "/"
    }

    private func displayWorkspacePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }
        return path
    }

    private func workspaceGroupCollapsedSummary(_ group: SessionWorkspaceGroup) -> String {
        let liveSummary = workspaceGroupLiveSummary(group)
        let backendSummary = workspaceGroupBackendSummary(group)
        var parts: [String] = []

        if !liveSummary.isEmpty {
            parts.append(liveSummary)
        }

        if !backendSummary.isEmpty {
            parts.append(backendSummary)
        }

        parts.append(group.displayPath)
        return parts.joined(separator: " • ")
    }

    private func workspaceGroupDrawerSummary(
        _ group: SessionWorkspaceGroup,
        representativeTitle: String?
    ) -> String {
        let liveSummary = workspaceGroupLiveSummary(group)
        let backendSummary = workspaceGroupBackendSummary(group)
        let normalizedRepresentativeTitle = representativeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedGroupTitle = group.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []

        if !normalizedGroupTitle.isEmpty,
           normalizedGroupTitle.localizedCaseInsensitiveCompare(normalizedRepresentativeTitle) != .orderedSame {
            parts.append(normalizedGroupTitle)
        }

        if !liveSummary.isEmpty {
            parts.append(liveSummary)
        }

        if !backendSummary.isEmpty {
            parts.append(backendSummary)
        }

        parts.append(group.displayPath)
        return parts.joined(separator: " • ")
    }

    private func workspaceGroupLiveSummary(_ group: SessionWorkspaceGroup) -> String {
        let liveCount = group.threads.filter(workspaceGroupThreadAppearsLive(_:)).count
        guard liveCount > 0 else { return "" }

        if liveCount == group.threads.count, group.threads.count > 1 {
            return "All live"
        }

        return liveCount == 1 ? "1 live" : "\(liveCount) live"
    }

    private func workspaceGroupBackendSummary(_ group: SessionWorkspaceGroup) -> String {
        let backendLabels: [String] = Array(
            Set(
                group.threads.compactMap { thread -> String? in
                    let label = (thread.backendLabel ?? thread.backendId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return label.isEmpty ? nil : label
                }
            )
        )
        .sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        switch backendLabels.count {
        case 0:
            return ""
        case 1:
            return backendLabels[0]
        case 2:
            return backendLabels.joined(separator: " + ")
        default:
            return "\(backendLabels.count) backends"
        }
    }

    private func workspaceGroupThreadAppearsLive(_ thread: RemoteThread) -> Bool {
        if thread.status == "running" {
            return true
        }

        if thread.controller != nil {
            return true
        }

        return store.runtimeByThreadID[thread.id] != nil
    }

    private func workspaceGroupHeader(_ group: SessionWorkspaceGroup) -> some View {
        let isCollapsed = isWorkspaceGroupCollapsed(group.id)
        let representativeThread = group.threads.first
        let representativeUpdatedAt = representativeThread.map { Date(timeIntervalSince1970: $0.updatedAt / 1000) }
        let representativeTitle = representativeThread.map(threadDisplayName)
        let collapsedSummary = workspaceGroupCollapsedSummary(group)
        let usesDrawerStyle = group.section == .recent && isCollapsed
        let drawerSummary = workspaceGroupDrawerSummary(group, representativeTitle: representativeTitle)

        return HStack(spacing: 12) {
            Button {
                toggleWorkspaceGroup(group.id)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppPalette.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(AppPalette.mutedPanel.opacity(0.75), in: Circle())
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(groupExpandCollapseAnimation, value: isCollapsed)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sessions.workspaceGroupChevron.\(group.id)")

            Button {
                toggleWorkspaceGroup(group.id)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: usesDrawerStyle ? 4 : 3) {
                        if usesDrawerStyle {
                            Text(representativeTitle ?? group.title)
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(AppPalette.primaryText)
                                .lineLimit(1)

                            Text(drawerSummary)
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(AppPalette.secondaryText)
                                .lineLimit(1)
                        } else {
                            Text(group.title)
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                .foregroundStyle(AppPalette.primaryText)

                            if isCollapsed, let representativeTitle {
                                Text(representativeTitle)
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(AppPalette.primaryText)
                                    .lineLimit(1)
                            }

                            Text(isCollapsed ? collapsedSummary : group.displayPath)
                                .font(.system(.caption2, design: isCollapsed ? .rounded : .monospaced))
                                .foregroundStyle(AppPalette.secondaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: usesDrawerStyle ? 4 : 6) {
                        if let representativeUpdatedAt {
                            Text(relativeActivitySummary(representativeUpdatedAt))
                                .font(.system(.caption2, design: .rounded, weight: .medium))
                                .foregroundStyle(AppPalette.secondaryText)
                                .lineLimit(1)
                        }

                        Text("\(group.threads.count)")
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(AppPalette.secondaryText)
                            .padding(.horizontal, usesDrawerStyle ? 7 : 8)
                            .padding(.vertical, usesDrawerStyle ? 4 : 5)
                            .subtleActionCapsule()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, usesDrawerStyle ? 10 : 12)
        .background(
            sessionCardShape(isCollapsed ? .groupHeaderCollapsed : .groupHeaderExpanded)
                .fill(AppPalette.panel)
        )
        .overlay(
            sessionCardBorder(isCollapsed ? .groupHeaderCollapsed : .groupHeaderExpanded)
        )
        .accessibilityIdentifier("sessions.workspaceGroup.\(group.id)")
    }

    private func toggleWorkspaceGroup(_ groupID: String) {
        withAnimation(groupExpandCollapseAnimation) {
            if store.sessionAutoCollapseEnabled {
                if manuallyExpandedWorkspaceGroupIDs.contains(groupID) {
                    manuallyExpandedWorkspaceGroupIDs.remove(groupID)
                } else {
                    manuallyExpandedWorkspaceGroupIDs.insert(groupID)
                }
            } else {
                if manuallyCollapsedWorkspaceGroupIDs.contains(groupID) {
                    manuallyCollapsedWorkspaceGroupIDs.remove(groupID)
                } else {
                    manuallyCollapsedWorkspaceGroupIDs.insert(groupID)
                }
            }
        }
    }

    private func isWorkspaceGroupCollapsed(_ groupID: String) -> Bool {
        if store.sessionAutoCollapseEnabled {
            return !manuallyExpandedWorkspaceGroupIDs.contains(groupID)
        }

        return manuallyCollapsedWorkspaceGroupIDs.contains(groupID)
    }

    private func pruneWorkspaceGroupOverrides() {
        manuallyCollapsedWorkspaceGroupIDs.formIntersection(displayedWorkspaceGroupIDs)
        manuallyExpandedWorkspaceGroupIDs.formIntersection(displayedWorkspaceGroupIDs)
    }

    private func resetWorkspaceGroupOverrides(forAutoCollapseEnabled enabled: Bool) {
        if enabled {
            manuallyCollapsedWorkspaceGroupIDs.removeAll()
        } else {
            manuallyExpandedWorkspaceGroupIDs.removeAll()
        }
    }

    @ViewBuilder
    private func sessionStatusLead(_ phase: String) -> some View {
        if phase == "running" {
            WorkingSpriteView(
                tint: FeedStyle.phaseColor(phase),
                font: .system(size: 12, weight: .semibold, design: .monospaced)
            )
            .frame(width: 18, height: 18)
            .padding(.top, 2)
        } else {
            Circle()
                .fill(FeedStyle.phaseColor(phase))
                .frame(width: 10, height: 10)
                .padding(.top, 5)
        }
    }

    private func sessionStatusChipRow(_ thread: RemoteThread, phase: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sessionChip(sessionBackendLabel(for: thread), tint: AppPalette.accent)

                if phase != "idle", phase != "unknown" {
                    sessionChip(FeedStyle.phaseLabel(phase), tint: FeedStyle.phaseColor(phase))
                }
            }
        }
    }

    private func sessionPreviewAppearsLive(_ thread: RemoteThread, phase: String) -> Bool {
        let normalizedPhase = phase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedPhase != "idle", normalizedPhase != "unknown", normalizedPhase != "completed" {
            return true
        }

        if thread.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "running" {
            return true
        }

        return thread.controller != nil
    }

    private func sessionBackendLabel(for thread: RemoteThread) -> String {
        let label = (thread.backendLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty {
            return label
        }

        let backendID = (thread.backendId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return backendID.isEmpty ? "Codex" : backendID
    }

    private func sessionChip(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.1), in: Capsule())
    }

    private func sessionCardShape(_ position: SessionCardPosition) -> UnevenRoundedRectangle {
        switch position {
        case .standalone, .groupHeaderCollapsed:
            return UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 18,
                bottomLeading: 18,
                bottomTrailing: 18,
                topTrailing: 18
            ), style: .continuous)
        case .groupHeaderExpanded:
            return UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 18,
                bottomLeading: 0,
                bottomTrailing: 0,
                topTrailing: 18
            ), style: .circular)
        case .groupRowSingle:
            return UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 0,
                bottomLeading: 18,
                bottomTrailing: 18,
                topTrailing: 0
            ), style: .circular)
        case .groupRowFirst, .groupRowMiddle:
            return UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 0,
                bottomLeading: 0,
                bottomTrailing: 0,
                topTrailing: 0
            ), style: .circular)
        case .groupRowLast:
            return UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 0,
                bottomLeading: 18,
                bottomTrailing: 18,
                topTrailing: 0
            ), style: .circular)
        }
    }

    private var groupExpandCollapseAnimation: Animation? {
        AppMotion.standard(reduceMotion)
    }

    private var groupRowTransition: AnyTransition {
        reduceMotion ? .opacity : AppMotion.fadeScale
    }

    private func sessionCardBorder(_ position: SessionCardPosition) -> some View {
        sessionCardShape(position)
            .strokeBorder(AppPalette.border, lineWidth: 1)
            .overlay(alignment: .top) {
                if hidesTopBorder(for: position) {
                    sessionCardBorderCover
                }
            }
            .overlay(alignment: .bottom) {
                if hidesBottomBorder(for: position) {
                    sessionCardBorderCover
                }
            }
    }

    private var sessionCardBorderCover: some View {
        Rectangle()
            .fill(AppPalette.panel)
            .frame(height: 2)
            .padding(.horizontal, 1)
            .allowsHitTesting(false)
    }

    private func hidesTopBorder(for position: SessionCardPosition) -> Bool {
        switch position {
        case .groupRowFirst, .groupRowMiddle, .groupRowLast, .groupRowSingle:
            return true
        case .standalone, .groupHeaderCollapsed, .groupHeaderExpanded:
            return false
        }
    }

    private func hidesBottomBorder(for position: SessionCardPosition) -> Bool {
        switch position {
        case .groupHeaderExpanded:
            return true
        case .standalone, .groupHeaderCollapsed, .groupRowFirst, .groupRowMiddle, .groupRowLast, .groupRowSingle:
            return false
        }
    }

    private func cardPosition(forThreadAt index: Int, count: Int) -> SessionCardPosition {
        if count <= 1 {
            return .groupRowSingle
        }
        if index == 0 {
            return .groupRowFirst
        }
        if index == count - 1 {
            return .groupRowLast
        }
        return .groupRowMiddle
    }

    private func sessionScrollID(for threadID: String) -> String {
        "thread-\(threadID)"
    }

    private func openThreadFromSessionsList(_ threadID: String) {
        store.openSession(threadID)
        setSingleRoute(.thread(threadID))
    }

    private func setSingleRoute(_ route: SessionsRoute) {
        var path = NavigationPath()
        path.append(route)
        store.sessionsNavigationPath = path
    }

    private func scrollToActiveSession(
        using proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
        let targetID = store.selectedThreadID.flatMap { displayedThreadIDs.contains($0) ? $0 : nil }
            ?? filteredActiveWorkspaceGroups.first?.threads.first?.id
            ?? filteredRecentWorkspaceGroups.first?.threads.first?.id
        guard let targetID else { return }

        let scroll = {
            proxy.scrollTo(sessionScrollID(for: targetID), anchor: .center)
        }

        DispatchQueue.main.async {
            if animated {
                withAnimation(AppMotion.scroll(reduceMotion)) {
                    scroll()
                }
            } else {
                scroll()
            }
        }
    }

    private func refreshSessionList() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await store.refreshThreads() }
            group.addTask { await store.refreshRuntime() }
        }
    }

    private func relativeActivitySummary(_ updatedAt: Date) -> String {
        Self.relativeFormatter.localizedString(for: updatedAt, relativeTo: Date())
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renamingThreadID != nil },
            set: { isPresented in
                if !isPresented {
                    clearRenameDraft()
                }
            }
        )
    }

    private func beginRename(_ thread: RemoteThread) {
        renamingThreadID = thread.id
        renameDraft = thread.name ?? ""
    }

    private func clearRenameDraft() {
        renamingThreadID = nil
        renameDraft = ""
    }

    private func maybeOpenDebugLaunchThread() {
#if DEBUG
        guard !debugLaunchThreadHandled else { return }

        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: Self.debugOpenThreadArgument),
              flagIndex + 1 < arguments.count
        else {
            return
        }

        let threadID = arguments[flagIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty, displayedThreadIDs.contains(threadID) else { return }

        debugLaunchThreadHandled = true
        DispatchQueue.main.async {
            store.openSession(threadID)
            setSingleRoute(.thread(threadID))
        }
#endif
    }

    private func submitRename() async {
        guard let renamingThreadID else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearRenameDraft()
            return
        }

        clearRenameDraft()
        await store.renameSession(renamingThreadID, to: trimmed)
    }

    private func moveGroupToRecent(_ group: SessionWorkspaceGroup) {
        store.moveSessionsToRecent(group.threads.map(\.id))
    }

    private func archiveGroup(_ group: SessionWorkspaceGroup) async {
        await store.archiveSessions(group.threads.map(\.id))
    }

    private func sectionDivider(_ title: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(AppPalette.secondaryText)

            Rectangle()
                .fill(AppPalette.border)
                .frame(height: 1)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .textCase(nil)
    }

    private func headerActionButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppPalette.secondaryText)
                .frame(width: 34, height: 34)
                .subtleActionCapsule()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("sessions.header.\(accessibilityLabel.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

}

// MARK: - Archived Sessions View

struct ArchivedSessionsView: View {
    @Environment(SessionStore.self) private var store

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        List {
            if store.archivedSessionThreads.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No archived sessions")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(AppPalette.primaryText)

                    Text("Swipe right on a recent session to archive it.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(AppPalette.secondaryText)
                }
                .padding(16)
                .sectionSurface(cornerRadius: 18)
                .plainListRow(topPadding: 14, bottomPadding: 10)
            } else {
                ForEach(store.archivedSessionThreads) { thread in
                    Button {
                        Task {
                            await store.openArchivedSession(thread.id)
                            openThread(thread.id)
                        }
                    } label: {
                        archivedSessionRow(thread)
                    }
                    .buttonStyle(.plain)
                    .plainListRow()
                    .accessibilityIdentifier("sessions.archived.thread.\(thread.id)")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .contentMargins(.bottom, 80, for: .scrollContent)
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            await store.refreshThreads()
        }
    }

    private func openThread(_ threadID: String) {
        var path = NavigationPath()
        path.append(SessionsRoute.thread(threadID))
        store.sessionsNavigationPath = path
    }

    private func archivedSessionRow(_ thread: RemoteThread) -> some View {
        let updatedAt = Date(timeIntervalSince1970: thread.updatedAt / 1000)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(displayTitle(for: thread))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(AppPalette.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(Self.relativeFormatter.localizedString(for: updatedAt, relativeTo: Date()))
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(AppPalette.secondaryText)
            }

            Text(displaySubtitle(for: thread))
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(AppPalette.secondaryText)
                .lineLimit(1)

            if !thread.preview.isEmpty {
                Text(thread.preview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .sectionSurface(cornerRadius: 16)
    }

    private func displayTitle(for thread: RemoteThread) -> String {
        let name = thread.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            return name
        }

        let preview = thread.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = preview.split(whereSeparator: \.isNewline).first, !firstLine.isEmpty {
            return String(firstLine)
        }

        return "Session"
    }

    private func displaySubtitle(for thread: RemoteThread) -> String {
        let backend = thread.backendLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = thread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [backend, cwd].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? "Archived" : parts.joined(separator: " · ")
    }
}

// MARK: - New Session View

struct NewSessionView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var workingDirectoryFieldFocused: Bool

    private let workingDirectorySuggestionVisibleCount = 3
    private let workingDirectorySuggestionRowHeight: CGFloat = 58

    @State private var draft: NewSessionDraft
    @State private var launchOptions: SessionLaunchOptions?
    @State private var workingDirectorySuggestions: [DirectorySuggestion] = []
    @State private var isCreating = false
    @State private var isLoadingOptions = false
    @State private var loadedBackendID: String?
    @State private var showingDirectoryPicker = false

    init(initialDraft: NewSessionDraft) {
        _draft = State(initialValue: initialDraft)
    }

    private var availableBackends: [BackendSummary] {
        store.availableBackends.filter(\.available)
    }

    private var currentBackendID: String? {
        draft.backendId ?? store.effectiveCreateBackend?.id
    }

    private var currentBackendLabel: String {
        availableBackends.first(where: { $0.id == currentBackendID })?.label ?? "Backend"
    }

    private var effortOptions: [String] {
        launchOptions?.effortOptions ?? []
    }

    private var modelOptions: [String] {
        launchOptions?.modelOptions ?? []
    }

    private var shouldShowWorkingDirectoryAutocomplete: Bool {
        workingDirectoryFieldFocused && !workingDirectorySuggestions.isEmpty
    }

    private var workingDirectorySuggestionLookupKey: String {
        "\(workingDirectoryFieldFocused ? 1 : 0)|\(draft.workingDirectory)"
    }

    private var workingDirectoryAutocompleteMaxHeight: CGFloat {
        let visibleCount = min(workingDirectorySuggestions.count, workingDirectorySuggestionVisibleCount)
        guard visibleCount > 0 else { return 0 }

        let dividerCount = max(0, visibleCount - 1)
        return CGFloat(visibleCount) * workingDirectorySuggestionRowHeight + CGFloat(dividerCount)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Launch a new session on your Mac.")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(AppPalette.secondaryText)

                VStack(alignment: .leading, spacing: 12) {
                    fieldLabel("Backend")

                    Picker("Backend", selection: Binding(
                        get: { currentBackendID ?? "" },
                        set: { draft.backendId = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(availableBackends) { backend in
                            Text(backend.label).tag(backend.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("newsession.backendPicker")
                }
                .padding(16)
                .sectionSurface(cornerRadius: 20)

                if isCodexBackend {
                    VStack(alignment: .leading, spacing: 12) {
                        fieldLabel("Start In")

                        Picker("Start In", selection: $draft.launchMode) {
                            ForEach(SessionLaunchMode.allCases) { mode in
                                Text(mode.codexPickerLabel).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("newsession.launchModePicker")

                        Text(draft.launchMode.codexDescription)
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(AppPalette.secondaryText)
                    }
                    .padding(16)
                    .sectionSurface(cornerRadius: 20)
                }

                VStack(alignment: .leading, spacing: 12) {
                    fieldLabel("Model")

                    if isLoadingOptions {
                        WorkingStatusLabel(
                            text: "Loading \(currentBackendLabel) options…",
                            preset: .point,
                            tint: AppPalette.secondaryText
                        )
                    }

                    if !modelOptions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Detected from the installed \(currentBackendLabel) CLI.")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(AppPalette.secondaryText)

                            VStack(spacing: 0) {
                                ForEach(modelOptions, id: \.self) { model in
                                    Button {
                                        draft.model = model
                                    } label: {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(model)
                                                    .font(.system(.subheadline, design: .monospaced))
                                                    .foregroundStyle(AppPalette.primaryText)

                                                if selectedModelMatches(model) {
                                                    Text("Selected")
                                                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                                                        .foregroundStyle(AppPalette.accent)
                                                }
                                            }

                                            Spacer()

                                            Image(systemName: selectedModelMatches(model) ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(selectedModelMatches(model) ? AppPalette.accent : AppPalette.secondaryText.opacity(0.45))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("newsession.model.\(model)")

                                    if model != modelOptions.last {
                                        Divider()
                                            .overlay(AppPalette.border)
                                    }
                                }
                            }
                            .sectionSurface(cornerRadius: 16)
                        }
                    } else {
                        Text("No CLI model list detected for this backend yet.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(AppPalette.secondaryText)
                    }

                    if isClaudeBackend {
                        VStack(alignment: .leading, spacing: 8) {
                            fieldLabel("Context")

                            Picker("Context", selection: $draft.claudeContextMode) {
                                Text("normal").tag(ClaudeContextMode.normal)
                                Text("1m").tag(ClaudeContextMode.oneMillion)
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Effort")

                        Picker("Effort", selection: Binding(
                            get: { draft.reasoningEffort },
                            set: { draft.reasoningEffort = $0 }
                        )) {
                            Text("Default").tag(String?.none)
                            ForEach(effortOptions, id: \.self) { option in
                                Text(option).tag(Optional(option))
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .inputFieldSurface(cornerRadius: 16)
                        .accessibilityIdentifier("newsession.effortPicker")
                    }

                    if isCodexBackend {
                        Toggle(isOn: Binding(
                            get: { draft.codexFastMode ?? false },
                            set: { draft.codexFastMode = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("fast")
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                Text("Uses Codex service tier `fast` when enabled and `flex` when disabled.")
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundStyle(AppPalette.secondaryText)
                            }
                        }
                        .tint(AppPalette.accent)
                        .accessibilityIdentifier("newsession.codexFastToggle")
                    }
                }
                .padding(16)
                .sectionSurface(cornerRadius: 20)

                VStack(alignment: .leading, spacing: 12) {
                    fieldLabel("Working Directory")

                    HStack(alignment: .center, spacing: 10) {
                        TextField("Working directory", text: $draft.workingDirectory)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($workingDirectoryFieldFocused)
                            .padding(12)
                            .inputFieldSurface(cornerRadius: 16)
                            .accessibilityIdentifier("newsession.workingDirectoryField")

                        Button {
                            showingDirectoryPicker = true
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppPalette.secondaryText)
                                .frame(width: 44, height: 44)
                                .subtleActionCapsule()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Browse Folders")
                        .accessibilityIdentifier("newsession.browseFolders")
                    }

                    Text("Autocomplete stays inline while typing, and Browse opens a full folder picker with breadcrumbs and recents.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(AppPalette.secondaryText)
                }
                .padding(16)
                .sectionSurface(cornerRadius: 20)

                Button {
                    Task { await startSession() }
                } label: {
                    HStack(spacing: 10) {
                        if isCreating {
                            WorkingSpriteView(
                                preset: .rollingLine,
                                tint: .white,
                                font: .system(.subheadline, design: .monospaced, weight: .semibold),
                                accessibilityLabel: "Starting session"
                            )
                        }
                        Text(isCreating ? "Starting…" : "Start Session")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(isCreating || draft.normalizedWorkingDirectory.isEmpty || isLoadingOptions)
                .accessibilityIdentifier("newsession.start")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .navigationTitle("New Session")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadLaunchOptions()
            await refreshWorkingDirectorySuggestions()
        }
        .task(id: currentBackendID) {
            await loadLaunchOptions()
        }
        .task(id: workingDirectorySuggestionLookupKey) {
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
            } catch {
                return
            }
            await refreshWorkingDirectorySuggestions()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if shouldShowWorkingDirectoryAutocomplete {
                workingDirectoryAutocompletePanel
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .background(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: $showingDirectoryPicker) {
            DirectoryPickerView(initialPath: draft.workingDirectory) { selectedPath in
                draft.workingDirectory = selectedPath
                workingDirectoryFieldFocused = false
            }
        }
    }

    private var isCodexBackend: Bool {
        currentBackendID == "codex"
    }

    private var isClaudeBackend: Bool {
        currentBackendID == "claude-code"
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(AppPalette.secondaryText)
    }

    private func loadLaunchOptions() async {
        guard let backendID = currentBackendID else { return }

        let interval = HelmLogger.uiSignposter.beginInterval("NewSessionLoadLaunchOptions")
        defer { HelmLogger.uiSignposter.endInterval("NewSessionLoadLaunchOptions", interval) }
        isLoadingOptions = true
        defer { isLoadingOptions = false }

        do {
            let options = try await store.fetchSessionLaunchOptions(backendID: backendID)
            launchOptions = options
            let didSwitchBackend = loadedBackendID != backendID
            loadedBackendID = backendID

            if didSwitchBackend && options.modelDefault == nil {
                draft.model = ""
            } else if (didSwitchBackend || draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                      let modelDefault = options.modelDefault {
                draft.model = modelDefault
            }

            if didSwitchBackend {
                draft.launchMode = backendID == "codex" ? store.preferredCodexLaunchMode : .managedShell
            }

            if didSwitchBackend {
                draft.reasoningEffort = options.effortDefault
            } else if draft.reasoningEffort == nil {
                draft.reasoningEffort = options.effortDefault
            }

            if backendID == "codex" {
                if didSwitchBackend || draft.codexFastMode == nil {
                    draft.codexFastMode = options.codexFastDefault ?? false
                }
            } else if didSwitchBackend {
                draft.codexFastMode = nil
            }

            if backendID == "claude-code" {
                if let defaultContext = options.claudeContextDefault,
                   let contextMode = ClaudeContextMode(rawValue: defaultContext),
                   didSwitchBackend || draft.claudeContextMode != contextMode {
                    draft.claudeContextMode = contextMode
                }
            } else if didSwitchBackend {
                draft.claudeContextMode = .normal
            }
        } catch {
            launchOptions = nil
        }
    }

    private func refreshWorkingDirectorySuggestions() async {
        guard workingDirectoryFieldFocused else {
            workingDirectorySuggestions = []
            return
        }

        let trimmed = draft.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = trimmed.isEmpty ? "~/" : trimmed

        let interval = HelmLogger.uiSignposter.beginInterval("NewSessionAutocomplete")
        defer { HelmLogger.uiSignposter.endInterval("NewSessionAutocomplete", interval) }
        do {
            workingDirectorySuggestions = try await store.fetchDirectorySuggestions(prefix: query)
        } catch {
            workingDirectorySuggestions = []
        }
    }

    private func startSession() async {
        guard !isCreating else { return }
        isCreating = true
        defer { isCreating = false }

        var request = draft
        request.backendId = currentBackendID

        if let threadID = await store.createThread(draft: request) {
            DirectoryPickerRecentStore.record(request.normalizedWorkingDirectory)
            dismiss()
            DispatchQueue.main.async {
                var path = NavigationPath()
                path.append(SessionsRoute.thread(threadID))
                store.sessionsNavigationPath = path
            }
        }
    }
    private func selectedModelMatches(_ option: String) -> Bool {
        draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(option.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private var workingDirectoryAutocompletePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Autocompletions")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(AppPalette.secondaryText)

                Spacer()

                Text("Tap to fill")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(AppPalette.secondaryText)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(workingDirectorySuggestions) { suggestion in
                        Button {
                            draft.workingDirectory = suggestion.path
                            DirectoryPickerRecentStore.record(suggestion.path)
                            workingDirectoryFieldFocused = false
                        } label: {
                            HStack(spacing: 10) {
                                Text(suggestion.displayPath)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundStyle(AppPalette.primaryText)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if suggestion.isExact {
                                    Text("Exact")
                                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                                        .foregroundStyle(AppPalette.accent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(AppPalette.accent.opacity(0.12), in: Capsule())
                                }

                                Image(systemName: "arrow.up.left")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AppPalette.secondaryText)
                            }
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: workingDirectorySuggestionRowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if suggestion.id != workingDirectorySuggestions.last?.id {
                            Divider()
                                .overlay(AppPalette.border)
                        }
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: workingDirectoryAutocompleteMaxHeight)
            .sectionSurface(cornerRadius: 16)
        }
    }
}

private struct SessionDetailBottomMarkerPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Session Detail View

struct SessionDetailView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let threadID: String
    @State private var isFollowingLatest = true
    @State private var showJumpToLatestButton = false
    @State private var pendingAutoScrollPauseTask: Task<Void, Never>?
    @State private var pendingFollowScrollTask: Task<Void, Never>?
    @State private var keyboardLayoutTransitionTask: Task<Void, Never>?
    @State private var isKeyboardLayoutTransitioning = false
    @State private var liveTerminalProjection = SessionFeedItemOrdering.LiveTerminalProjection.empty
    @State private var liveTerminalProjectionSignature: LiveTerminalProjectionSignature?
    @State private var queuedMessagesExpanded = false

    private static let bottomAnchorID = "session-detail-bottom"
    private static let scrollCoordinateSpace = "session-detail-scroll"
    private static let bottomFollowThreshold: CGFloat = 84
    private static let liveTerminalProjectionTickIntervalNS: UInt64 = 3_000_000_000

    private struct LiveTerminalProjectionSignature: Equatable {
        private static let liveTerminalItemScanLimit = 320

        let detailUpdatedAtMS: Int64
        let turnCount: Int
        let lastTurnID: String
        let lastTurnItemCount: Int
        let latestLiveTerminalItemID: String
        let latestLiveTerminalStatus: String
        let latestLiveTerminalRawLength: Int
        let latestLiveTerminalDetailLength: Int

        init(detail: RemoteThreadDetail) {
            let normalizedUpdatedAt =
                detail.updatedAt > 10_000_000_000
                    ? detail.updatedAt
                    : detail.updatedAt * 1_000
            detailUpdatedAtMS = Int64(normalizedUpdatedAt.rounded())
            turnCount = detail.turns.count
            lastTurnID = detail.turns.last?.id ?? ""
            lastTurnItemCount = detail.turns.last?.items.count ?? 0
            let latestLiveTerminalItem = Self.latestLiveTerminalItem(in: detail)
            latestLiveTerminalItemID = latestLiveTerminalItem?.id ?? ""
            latestLiveTerminalStatus = latestLiveTerminalItem?.status ?? ""
            latestLiveTerminalRawLength = latestLiveTerminalItem?.rawText?.count ?? 0
            latestLiveTerminalDetailLength = latestLiveTerminalItem?.detail?.count ?? 0
        }

        private static func latestLiveTerminalItem(in detail: RemoteThreadDetail) -> RemoteThreadItem? {
            var scannedItemCount = 0
            for turn in detail.turns.reversed() {
                for item in turn.items.reversed() {
                    scannedItemCount += 1
                    if SessionFeedItemOrdering.isLiveTerminalItem(item) {
                        return item
                    }
                    if scannedItemCount >= liveTerminalItemScanLimit {
                        return nil
                    }
                }
            }
            return nil
        }
    }

    private var threadDetailUpdatedAt: Double? {
        store.threadDetail(for: threadID)?.updatedAt
    }

    private var currentLiveTerminalProjectionSignature: LiveTerminalProjectionSignature? {
        guard let detail = store.threadDetail(for: threadID) else { return nil }
        return LiveTerminalProjectionSignature(detail: detail)
    }

    private var liveTerminalProjectionTickerEnabled: Bool {
        liveTerminalProjection.statusEvent?.isRunning == true ||
            liveTerminalProjection.activityEvent?.isRunning == true
    }

    private var liveTerminalStatusLineEvent: CodexTUIEvent? {
        liveTerminalProjection.pinnedStatusLineEvent
    }

    var body: some View {
        let liveTerminalQueuedMessages = liveTerminalProjection.queuedMessages
        let liveTerminalQueuedMessagesSignature = liveTerminalQueuedMessages.joined(separator: "\u{001F}")

        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                GeometryReader { scrollGeometry in
                    ScrollView {
                        VStack(spacing: 0) {
                            VStack(spacing: 10) {
                                if !store.threadApprovals(for: threadID).isEmpty {
                                    approvalNotice
                                        .padding(.horizontal, 10)
                                        .padding(.top, 4)
                                }

                                SessionFeedView(threadID: threadID)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 4)
                                    .padding(.bottom, 8)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)

                            Color.clear
                                .frame(height: 1)
                                .id(Self.bottomAnchorID)
                                .background(
                                    GeometryReader { markerGeometry in
                                        Color.clear.preference(
                                            key: SessionDetailBottomMarkerPreferenceKey.self,
                                            value: markerGeometry.frame(in: .named(Self.scrollCoordinateSpace)).maxY
                                        )
                                    }
                                )
                        }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: scrollGeometry.size.height,
                            alignment: .bottom
                        )
                    }
                    .coordinateSpace(name: Self.scrollCoordinateSpace)
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                guard value.translation.height > 8 else { return }
                                pauseAutoScroll()
                            }
                    )
                    .refreshable {
                        await store.refreshThreadDetail(threadID: threadID)
                        scrollToBottomIfFollowing(proxy, animated: false)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onAppear {
                        isFollowingLatest = true
                        showJumpToLatestButton = false
                        scrollToBottom(proxy, animated: false)
                        refreshLiveTerminalProjection(force: true)
                    }
                    .onDisappear {
                        pendingAutoScrollPauseTask?.cancel()
                        pendingAutoScrollPauseTask = nil
                        pendingFollowScrollTask?.cancel()
                        pendingFollowScrollTask = nil
                        keyboardLayoutTransitionTask?.cancel()
                        keyboardLayoutTransitionTask = nil
                        isKeyboardLayoutTransitioning = false
                    }
                    .onChange(of: threadDetailUpdatedAt) { _, _ in
                        scheduleScrollToBottomIfFollowing(proxy)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                        handleKeyboardLayoutTransition(using: proxy)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { _ in
                        handleKeyboardLayoutTransition(using: proxy)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                        handleKeyboardLayoutTransition(using: proxy)
                    }
                    .onPreferenceChange(SessionDetailBottomMarkerPreferenceKey.self) { bottomY in
                        updateAutoScrollState(bottomY: bottomY, viewportHeight: scrollGeometry.size.height)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if showJumpToLatestButton {
                            jumpToLatestButton {
                                jumpToLatest(using: proxy)
                            }
                            .padding(.trailing, 16)
                            .padding(.bottom, 12)
                            .transition(AppMotion.fadeScale)
                        }
                    }
                }
            }

            if let statusEvent = liveTerminalStatusLineEvent {
                CodexTUIStatusLineView(event: statusEvent)
                    .transition(AppMotion.fade)
            }

            if !liveTerminalQueuedMessages.isEmpty {
                CodexTUIQueuedMessagesView(
                    messages: liveTerminalQueuedMessages,
                    isExpanded: queuedMessagesExpanded
                ) {
                    withAnimation(AppMotion.quick(reduceMotion)) {
                        queuedMessagesExpanded.toggle()
                    }
                }
                .transition(AppMotion.fade)
            }

            if let statusBar = liveTerminalProjection.statusBar {
                CodexTUIStatusBarView(status: statusBar)
                    .transition(AppMotion.fade)
            }

            SessionInputBar(threadID: threadID, onActivateCommander: {
                store.selectedSection = .command
            })
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .task(id: liveTerminalProjectionTickerEnabled) {
            guard liveTerminalProjectionTickerEnabled else { return }
            while !Task.isCancelled && liveTerminalProjectionTickerEnabled {
                try? await Task.sleep(nanoseconds: Self.liveTerminalProjectionTickIntervalNS)
                refreshLiveTerminalProjection(force: true)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                sessionPrincipal
            }
        }
        .task(id: threadID) {
            let wasSelected = store.selectedThreadID == threadID
            if !wasSelected {
                store.openSession(threadID)
            }
            if wasSelected,
               !store.isOpeningThread(threadID),
               !store.hasPendingBridgeOpen(threadID: threadID) {
                let needsDetail = store.threadDetail(for: threadID) == nil || store.threadDetailError(for: threadID) != nil
                if needsDetail {
                    await store.refreshThreadDetail(threadID: threadID)
                }
            }
            refreshLiveTerminalProjection(force: true)
        }
        .onChange(of: liveTerminalQueuedMessagesSignature) { _, signature in
            guard signature.isEmpty else { return }
            queuedMessagesExpanded = false
        }
        .onChange(of: currentLiveTerminalProjectionSignature) { _, _ in
            refreshLiveTerminalProjection(force: true)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }

        DispatchQueue.main.async {
            if animated {
                withAnimation(AppMotion.scroll(reduceMotion)) {
                    action()
                }
            } else {
                action()
            }
        }
    }

    private func jumpToLatest(using proxy: ScrollViewProxy) {
        pendingAutoScrollPauseTask?.cancel()
        pendingAutoScrollPauseTask = nil
        pendingFollowScrollTask?.cancel()
        pendingFollowScrollTask = nil

        withAnimation(AppMotion.quick(reduceMotion)) {
            isFollowingLatest = true
            showJumpToLatestButton = false
        }
        scrollToBottom(proxy)

        pendingFollowScrollTask = Task { @MainActor in
            for delay in [Duration.milliseconds(60), .milliseconds(160), .milliseconds(320)] {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                isFollowingLatest = true
                showJumpToLatestButton = false
                scrollToBottom(proxy, animated: false)
            }
            pendingFollowScrollTask = nil
        }
    }

    private func scrollToBottomIfFollowing(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard isFollowingLatest else { return }
        scrollToBottom(proxy, animated: animated)
    }

    private func scheduleScrollToBottomIfFollowing(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard isFollowingLatest else { return }
        pendingFollowScrollTask?.cancel()
        pendingFollowScrollTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(35))
            } catch {
                return
            }

            guard !Task.isCancelled, isFollowingLatest else { return }
            scrollToBottom(proxy, animated: animated)
            pendingFollowScrollTask = nil
        }
    }

    private func handleKeyboardLayoutTransition(using proxy: ScrollViewProxy) {
        let shouldPreserveLatest = isFollowingLatest || !showJumpToLatestButton

        isKeyboardLayoutTransitioning = true
        pendingAutoScrollPauseTask?.cancel()
        pendingAutoScrollPauseTask = nil

        if shouldPreserveLatest {
            isFollowingLatest = true
            showJumpToLatestButton = false
            scrollToBottom(proxy, animated: false)
        }

        keyboardLayoutTransitionTask?.cancel()
        keyboardLayoutTransitionTask = Task { @MainActor in
            for delay in [Duration.milliseconds(80), .milliseconds(180), .milliseconds(340)] {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                if shouldPreserveLatest {
                    scrollToBottom(proxy, animated: false)
                }
            }

            isKeyboardLayoutTransitioning = false
        }
    }

    private func updateAutoScrollState(bottomY: CGFloat, viewportHeight: CGFloat) {
        guard viewportHeight > 0 else { return }
        guard !isKeyboardLayoutTransitioning else { return }

        let isNearBottom = bottomY <= viewportHeight + Self.bottomFollowThreshold

        if isNearBottom {
            pendingAutoScrollPauseTask?.cancel()
            pendingAutoScrollPauseTask = nil

            guard !isFollowingLatest || showJumpToLatestButton else { return }
            withAnimation(AppMotion.quick(reduceMotion)) {
                isFollowingLatest = true
                showJumpToLatestButton = false
            }
            return
        }

        guard isFollowingLatest else {
            guard !showJumpToLatestButton else { return }
            withAnimation(AppMotion.quick(reduceMotion)) {
                showJumpToLatestButton = true
            }
            return
        }

        guard pendingAutoScrollPauseTask == nil else { return }
        pendingAutoScrollPauseTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            withAnimation(AppMotion.quick(reduceMotion)) {
                isFollowingLatest = false
                showJumpToLatestButton = true
            }
            pendingAutoScrollPauseTask = nil
        }
    }

    private func pauseAutoScroll() {
        pendingAutoScrollPauseTask?.cancel()
        pendingAutoScrollPauseTask = nil

        guard isFollowingLatest || !showJumpToLatestButton else { return }
        withAnimation(AppMotion.quick(reduceMotion)) {
            isFollowingLatest = false
            showJumpToLatestButton = true
        }
    }

    private func jumpToLatestButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Latest")
                    .font(.system(.caption2, design: .monospaced, weight: .semibold))

                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(AppPalette.primaryText)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(AppPalette.elevatedPanel, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(AppPalette.border, lineWidth: 1)
            )
            .shadow(color: AppPalette.shadow, radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scroll to latest message")
        .accessibilityIdentifier("sessions.detail.scrollToLatest")
    }

    private var sessionPrincipal: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                if let phase = store.runtime(for: threadID)?.phase {
                    if phase == "running" {
                        WorkingSpriteView(
                            tint: FeedStyle.phaseColor(phase),
                            font: .system(size: 11, weight: .semibold, design: .monospaced)
                        )
                    } else {
                        Circle()
                            .fill(FeedStyle.phaseColor(phase))
                            .frame(width: 7, height: 7)
                    }
                }

                Text(store.displayTitle(for: threadID))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .lineLimit(1)
            }

            if let phase = store.runtime(for: threadID)?.phase, phase != "idle", phase != "unknown" {
                Text(FeedStyle.phaseLabel(phase))
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(FeedStyle.phaseColor(phase))
            }
        }
    }

    private func refreshLiveTerminalProjection(force: Bool = false) {
        guard let detail = store.threadDetail(for: threadID) else {
            liveTerminalProjection = .empty
            liveTerminalProjectionSignature = nil
            return
        }

        let signature = LiveTerminalProjectionSignature(detail: detail)
        guard force || signature != liveTerminalProjectionSignature else { return }

        let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(
            from: detail.turns.flatMap(\.items),
            detailUpdatedAt: detail.updatedAt,
            now: .now
        )

        if liveTerminalProjection != projection {
            liveTerminalProjection = projection
        }
        liveTerminalProjectionSignature = signature
    }

    private var approvalNotice: some View {
        let approvals = store.threadApprovals(for: threadID)
        let approval = approvals.first

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(AppPalette.warning)
                Text("\(approvals.count) approval\(approvals.count == 1 ? "" : "s") pending")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                Spacer()
            }

            if let approval {
                Text(approval.title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))

                if let detail = approval.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(AppPalette.secondaryText)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        approvalActionButton("Approve", icon: "checkmark", tint: AppPalette.accent) {
                            Task { await store.decideApproval(approval, decision: "accept") }
                        }

                        if approval.supportsAcceptForSession {
                            approvalActionButton("Accept for Session", icon: "checkmark.shield", tint: AppPalette.accent) {
                                Task { await store.decideApproval(approval, decision: "acceptForSession") }
                            }
                        }

                        approvalActionButton("Decline", icon: "xmark", tint: AppPalette.warning) {
                            Task { await store.decideApproval(approval, decision: "decline") }
                        }

                        approvalActionButton("Cancel", icon: "slash.circle", tint: AppPalette.secondaryText) {
                            Task { await store.decideApproval(approval, decision: "cancel") }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(AppPalette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func approvalActionButton(
        _ title: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(tint.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
