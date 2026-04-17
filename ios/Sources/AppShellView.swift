import SwiftUI
import UIKit

struct AppShellView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if store.shouldShowFirstRunPairingScanner {
                firstRunPairingScanner
            } else {
                appContent
            }
        }
        .tint(AppPalette.accent)
        .appBackground()
        .preferredColorScheme(store.appPreferredColorScheme)
    }

    private var appContent: some View {
        ZStack(alignment: .bottom) {
            currentPage
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Hidden realtime transport
            if store.voiceMode == .openAIRealtime {
                RealtimeCommandTransportView(
                    bridgeURL: store.bridge.baseURL.absoluteString,
                    pairingToken: store.bridge.pairingToken,
                    clientID: store.bridge.identity.id,
                    clientName: store.bridge.identity.name,
                    style: store.commandResponseStyle.rawValue,
                    threadID: store.commandTargetThread?.id,
                    backendID: store.commandTargetBackendSummary?.id,
                    voiceProviderID: store.effectiveVoiceProvider?.id,
                    active: store.realtimeCaptureActive,
                    playbackRequest: store.realtimePlaybackRequest,
                    playbackStopToken: store.realtimePlaybackStopToken,
                    onState: { state, detail in
                        store.handleRealtimeTransportState(state, detail: detail)
                    },
                    onEvent: { title, detail in
                        store.handleRealtimeTransportEvent(title, detail: detail)
                    },
                    onPartialTranscript: { text in
                        store.updateRealtimeTranscriptPreview(text)
                    },
                    onFinalTranscript: { text in
                        store.commitRealtimeTranscript(text)
                    },
                    onCommandExchange: { exchange in
                        store.handleRealtimeCommandExchange(exchange)
                    },
                    onCommandFailure: { threadID, transcript, detail, latencyMS in
                        store.handleRealtimeCommandFailure(
                            threadID: threadID,
                            transcript: transcript,
                            detail: detail,
                            latencyMS: latencyMS
                        )
                    },
                    onPlaybackFinished: {
                        store.handleRealtimePlaybackFinished()
                    },
                    onPlaybackInterrupted: {
                        store.handleRealtimePlaybackInterrupted()
                    }
                )
                .frame(height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
            }

            // Live command banner (when not on command sheet)
            if store.selectedSection == .sessions && store.liveCommandBannerVisible {
                liveCommandBanner
                    .padding(.horizontal, 16)
                    .padding(.bottom, 96)
                    .transition(AppMotion.fade)
            }

            // Floating command button
            if store.selectedSection == .sessions && store.sessionsNavigationPath.isEmpty {
                commandButton
                    .padding(.bottom, 8)
                    .transition(AppMotion.fade)
            }
        }
        .onChange(of: store.selectedSection) { _, newSection in
            if newSection == .command {
                Task {
                    await store.handleCommandSectionActivated()
                }
            }
        }
    }

    private var firstRunPairingScanner: some View {
        PairingQRScannerView(
            title: "Sync Helm with your CLI.",
            detail: "Scan the pairing QR from Helm on your Mac to connect this iPhone.",
            showsCloseButton: false,
            dismissesAfterSuccessfulScan: false
        ) { payload in
            await store.applyPairingSetupLink(payload)
            if store.bridge.hasPairingToken {
                store.selectedSection = .sessions
            }
            return store.bridge.hasPairingToken
        }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch store.selectedSection {
        case .sessions:
            SessionsHomeShellView(onOpenSettings: { store.selectedSection = .settings })
        case .command:
            NavigationStack {
                VoiceControlView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            backToSessionsButton
                        }
                    }
            }
        case .settings:
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            backToSessionsButton
                        }
                    }
            }
            .simultaneousGesture(settingsBackSwipeGesture)
        }
    }

    private var backToSessionsButton: some View {
        Button {
            store.selectedSection = .sessions
        } label: {
            Label("Sessions", systemImage: "chevron.left")
        }
    }

    private var settingsBackSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onEnded { value in
                guard shouldHandleSettingsBackSwipe(value) else { return }
                withAnimation(AppMotion.drawer(reduceMotion)) {
                    store.selectedSection = .sessions
                }
            }
    }

    private func shouldHandleSettingsBackSwipe(_ value: DragGesture.Value) -> Bool {
        guard value.startLocation.x <= 32 else { return false }

        let horizontalTravel = max(value.translation.width, value.predictedEndTranslation.width)
        let verticalTravel = max(abs(value.translation.height), abs(value.predictedEndTranslation.height))

        guard horizontalTravel >= 90 else { return false }
        guard horizontalTravel > verticalTravel * 1.2 else { return false }
        return true
    }

    // MARK: - Command button

    private var commandButton: some View {
        Button {
            store.selectedSection = .command
        } label: {
            ZStack {
                // Outer glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                AppPalette.accent.opacity(0.4),
                                AppPalette.accent.opacity(0.1),
                                Color.clear,
                            ],
                            center: .center,
                            startRadius: 22,
                            endRadius: 34
                        )
                    )
                    .frame(width: 68, height: 68)

                // Solid core
                Circle()
                    .fill(AppPalette.accent)
                    .frame(width: 44, height: 44)

                Image(systemName: store.realtimeCaptureActive ? "waveform.circle.fill" : "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .drawingGroup()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Live command banner

    private var liveCommandBanner: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.liveCommandBannerTitle)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                Text(store.liveCommandBannerDetail)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if store.realtimeQueuedSpeechCount > 0 {
                    Text("\(store.realtimeQueuedSpeechCount) queued update\(store.realtimeQueuedSpeechCount == 1 ? "" : "s")")
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Open") {
                store.selectedSection = .command
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppPalette.mutedPanel, in: Capsule())

            Button(store.realtimeCaptureActive ? "End" : "Resume") {
                if store.realtimeCaptureActive {
                    store.stopRealtimeCapture()
                } else {
                    Task { await store.startRealtimeCapture() }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppPalette.accent, in: Capsule())
            .foregroundStyle(.white)
        }
        .padding(16)
        .background(AppPalette.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppPalette.border, lineWidth: 1)
        )
        .compositingGroup()
        .shadow(color: AppPalette.shadow, radius: 12, y: 6)
    }
}

private struct SessionsHomeShellView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawerOpen = false
    @State private var drawerOffset: CGFloat = -320
    @State private var isDraggingDrawer = false
    @State private var activeDragKind: DrawerDragKind = .none

    var onOpenSettings: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let drawerWidth = min(342, max(300, geometry.size.width * 0.86))
            let progress = drawerProgress(width: drawerWidth)

            ZStack(alignment: .leading) {
                NavigationStack(path: Binding(
                    get: { store.sessionsNavigationPath },
                    set: { store.sessionsNavigationPath = $0 }
                )) {
                    SessionsHomeView(
                        openDrawer: { setDrawerOpen(true, width: drawerWidth) }
                    )
                    .navigationDestination(for: SessionsRoute.self) { route in
                        switch route {
                        case .thread(let threadID):
                            SessionDetailView(threadID: threadID)
                                .toolbar {
                                    ToolbarItem(placement: .topBarLeading) {
                                        drawerButton(width: drawerWidth)
                                    }
                                }
                        case .newSession:
                            NewSessionView(initialDraft: store.defaultNewSessionDraft())
                        case .archivedSessions:
                            ArchivedSessionsView()
                        }
                    }
                }
                .zIndex(0)

                if progress > 0.001 {
                    Color.black
                        .opacity(0.28 * progress)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            setDrawerOpen(false, width: drawerWidth)
                        }
                        .zIndex(1)
                }

                SessionsDrawerView(
                    openThread: { openThread($0, width: drawerWidth) },
                    openNewSession: { openNewSession(width: drawerWidth) },
                    openSettings: {
                        setDrawerOpen(false, width: drawerWidth)
                        onOpenSettings()
                    }
                )
                .frame(width: drawerWidth)
                .frame(maxHeight: .infinity)
                .offset(x: drawerOffset)
                .shadow(color: AppPalette.shadow.opacity(0.7), radius: 24, x: 10, y: 0)
                .zIndex(2)
                .simultaneousGesture(drawerCloseGesture(width: drawerWidth))
            }
            .overlay(alignment: .leading) {
                Color.clear
                    .frame(width: 22)
                    .contentShape(Rectangle())
                    .ignoresSafeArea(edges: .vertical)
                    .allowsHitTesting(!drawerOpen)
                    .highPriorityGesture(drawerOpenGesture(width: drawerWidth))
            }
            .onAppear {
                syncDrawerOffset(width: drawerWidth)
            }
            .onChange(of: drawerWidth) { _, _ in
                syncDrawerOffset(width: drawerWidth)
            }
        }
    }

    private func drawerButton(width: CGFloat) -> some View {
        Button {
            setDrawerOpen(true, width: width)
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppPalette.secondaryText)
                .frame(width: 34, height: 34)
                .subtleActionCapsule()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open sessions")
    }

    private func drawerProgress(width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return max(0, min(1, 1 + (drawerOffset / width)))
    }

    private func drawerOpenGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard !drawerOpen else { return }
                guard value.startLocation.x <= 26 else { return }
                guard horizontalWins(value) else { return }
                if activeDragKind != .opening {
                    activeDragKind = .opening
                    isDraggingDrawer = true
                }
                drawerOffset = clampOffset(-width + value.translation.width, width: width)
            }
            .onEnded { value in
                guard activeDragKind == .opening else { return }
                finishDrawerDrag(value: value, width: width)
            }
    }

    private func drawerCloseGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onChanged { value in
                guard drawerOpen else { return }
                guard horizontalWins(value) else { return }
                guard value.translation.width < 0 else { return }
                if activeDragKind != .closing {
                    activeDragKind = .closing
                    isDraggingDrawer = true
                }
                drawerOffset = clampOffset(value.translation.width, width: width)
            }
            .onEnded { value in
                guard activeDragKind == .closing else { return }
                finishDrawerDrag(value: value, width: width)
            }
    }

    private func horizontalWins(_ value: DragGesture.Value) -> Bool {
        abs(value.translation.width) > abs(value.translation.height) * 1.1
    }

    private func finishDrawerDrag(value: DragGesture.Value, width: CGFloat) {
        let projectedOffset = clampOffset(
            (activeDragKind == .opening ? -width : 0) + value.predictedEndTranslation.width,
            width: width
        )
        let projectedProgress = 1 + (projectedOffset / width)
        let shouldOpen = projectedProgress > 0.5
        activeDragKind = .none
        isDraggingDrawer = false
        setDrawerOpen(shouldOpen, width: width)
    }

    private func clampOffset(_ value: CGFloat, width: CGFloat) -> CGFloat {
        min(0, max(-width, value))
    }

    private func syncDrawerOffset(width: CGFloat) {
        guard !isDraggingDrawer else {
            drawerOffset = clampOffset(drawerOffset, width: width)
            return
        }
        drawerOffset = drawerOpen ? 0 : -width
    }

    private func setDrawerOpen(_ isOpen: Bool, width: CGFloat, animated: Bool = true) {
        activeDragKind = .none
        isDraggingDrawer = false

        let update = {
            drawerOpen = isOpen
            drawerOffset = isOpen ? 0 : -width
        }

        if animated {
            withAnimation(AppMotion.drawer(reduceMotion)) {
                update()
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                update()
            }
        }
    }

    private func openThread(_ threadID: String, width: CGFloat) {
        setDrawerOpen(false, width: width, animated: false)
        store.openSession(threadID)
        setSingleRoute(.thread(threadID))
    }

    private func openNewSession(width: CGFloat) {
        setDrawerOpen(false, width: width, animated: false)
        setSingleRoute(.newSession)
    }

    private func setSingleRoute(_ route: SessionsRoute) {
        var path = NavigationPath()
        path.append(route)
        store.sessionsNavigationPath = path
    }
}

private enum DrawerDragKind {
    case none
    case opening
    case closing
}

private enum DrawerSessionSection {
    case active
    case recent
}

private enum DrawerSessionSwipeAction {
    case moveToRecent
    case archive
}

private struct SessionsHomeView: View {
    var openDrawer: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [AppPalette.backgroundTop, AppPalette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Text("Helm")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundStyle(AppPalette.primaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, max(geometry.safeAreaInsets.top + 24, geometry.size.height * 0.30))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: openDrawer) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppPalette.secondaryText)
                        .frame(width: 34, height: 34)
                        .subtleActionCapsule()
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SessionsDrawerView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchQuery = ""
    @State private var activeSwipedThreadID: String?
    @State private var drawerThreadSwipeOffsets: [String: CGFloat] = [:]

    private static let threadSwipeCommitDistance: CGFloat = 76
    private static let threadSwipeMaxOffset: CGFloat = 112
    private static let threadSwipeCommitDelay: TimeInterval = 0.10

    var openThread: (String) -> Void
    var openNewSession: () -> Void
    var openSettings: () -> Void

    private var filteredActiveThreads: [RemoteThread] {
        filtered(store.activeSessionThreads)
    }

    private var filteredRecentThreads: [RemoteThread] {
        filtered(store.recentSessionThreads)
    }

    var body: some View {
        VStack(spacing: 0) {
            drawerHeader

            drawerSearch
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if filteredActiveThreads.isEmpty && filteredRecentThreads.isEmpty {
                        drawerEmptyState
                    }

                    if !filteredActiveThreads.isEmpty {
                        drawerSection("Active", threads: filteredActiveThreads, section: .active)
                    }

                    if !filteredRecentThreads.isEmpty {
                        drawerSection("Recent", threads: filteredRecentThreads, section: .recent)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
            .refreshable {
                await refreshDrawer()
            }
        }
        .background(AppPalette.backgroundBottom)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AppPalette.border)
                .frame(width: 1)
        }
        .ignoresSafeArea(edges: .vertical)
    }

    private var drawerHeader: some View {
        HStack(spacing: 10) {
            Text("Sessions")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(AppPalette.primaryText)

            Spacer()

            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppPalette.secondaryText)
                    .frame(width: 32, height: 32)
                    .subtleActionCapsule()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")

            Button(action: openNewSession) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 32, height: 32)
                    .background(AppPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Session")
        }
        .padding(.horizontal, 14)
        .padding(.top, 62)
        .padding(.bottom, 12)
    }

    private var drawerSearch: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppPalette.secondaryText)

            TextField("Search", text: $searchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.subheadline, design: .rounded))

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppPalette.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(11)
        .inputFieldSurface(cornerRadius: 8)
    }

    private func drawerSection(
        _ title: String,
        threads: [RemoteThread],
        section: DrawerSessionSection
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(AppPalette.secondaryText)
                .padding(.horizontal, 4)

            VStack(spacing: 6) {
                ForEach(threads) { thread in
                    drawerThreadRow(thread, section: section)
                }
            }
        }
    }

    private func drawerThreadRow(_ thread: RemoteThread, section: DrawerSessionSection) -> some View {
        let action = drawerThreadSwipeAction(for: section)
        let offset = drawerThreadSwipeOffset(for: thread.id)
        let progress = min(1, offset / Self.threadSwipeCommitDistance)

        return ZStack(alignment: .leading) {
            drawerThreadSwipeBackground(action: action, progress: progress)
                .opacity(Double(progress))

            drawerThreadRowContent(thread)
                .offset(x: offset)
        }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(drawerThreadSwipeGesture(thread, section: section))
        .onTapGesture {
            handleDrawerThreadTap(thread.id)
        }
        .animation(AppMotion.standard(reduceMotion), value: offset)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(drawerThreadSwipeAccessibilityTitle(for: action))) {
            performPlacementSwipe(thread, section: section)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                openThread(thread.id)
            }

            Button("Open", systemImage: "arrow.right") {
                openThread(thread.id)
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

    private func drawerThreadRowContent(_ thread: RemoteThread) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusTint(for: thread))
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(sessionTitle(thread))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(AppPalette.primaryText)
                    .lineLimit(1)

                Text(rowDetail(for: thread))
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(1)

                StableSessionPreviewBlock(
                    threadID: thread.id,
                    preview: thread.preview,
                    isLive: drawerThreadAppearsLive(thread),
                    font: .system(.caption2, design: .monospaced),
                    foregroundColor: AppPalette.tertiaryText,
                    lineLimit: 2
                )
            }

            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            store.selectedThreadID == thread.id ? AppPalette.accent.opacity(0.10) : AppPalette.panel,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(store.selectedThreadID == thread.id ? AppPalette.accent.opacity(0.28) : AppPalette.border, lineWidth: 1)
        )
    }

    private func drawerThreadSwipeBackground(
        action: DrawerSessionSwipeAction,
        progress: CGFloat
    ) -> some View {
        let tint = drawerThreadSwipeTint(for: action)

        return HStack(spacing: 9) {
            Image(systemName: drawerThreadSwipeSystemImage(for: action))
                .font(.system(.subheadline, design: .rounded, weight: .semibold))

            Text(drawerThreadSwipeTitle(for: action))
                .font(.system(.caption, design: .rounded, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.12 + (0.1 * Double(progress))))
        )
    }

    private func drawerThreadSwipeGesture(
        _ thread: RemoteThread,
        section: DrawerSessionSection
    ) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                let horizontalDistance = value.translation.width
                let verticalDistance = abs(value.translation.height)
                guard horizontalDistance > 0, horizontalDistance > verticalDistance else { return }

                if let activeSwipedThreadID, activeSwipedThreadID != thread.id {
                    resetDrawerThreadSwipe(activeSwipedThreadID)
                }

                activeSwipedThreadID = thread.id
                drawerThreadSwipeOffsets[thread.id] = min(Self.threadSwipeMaxOffset, max(0, horizontalDistance))
            }
            .onEnded { value in
                let committedDistance = max(value.translation.width, value.predictedEndTranslation.width)
                if committedDistance >= Self.threadSwipeCommitDistance {
                    completeDrawerThreadSwipe(thread, section: section)
                } else {
                    resetDrawerThreadSwipe(thread.id)
                }
            }
    }

    private func handleDrawerThreadTap(_ threadID: String) {
        if drawerThreadSwipeOffset(for: threadID) > 0 {
            resetDrawerThreadSwipe(threadID)
            return
        }

        openThread(threadID)
    }

    private func completeDrawerThreadSwipe(_ thread: RemoteThread, section: DrawerSessionSection) {
        withAnimation(AppMotion.standard(reduceMotion)) {
            drawerThreadSwipeOffsets[thread.id] = Self.threadSwipeMaxOffset
        }

        let delay = reduceMotion ? 0 : Self.threadSwipeCommitDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            clearDrawerThreadSwipe(thread.id)
            performPlacementSwipe(thread, section: section)
        }
    }

    private func performPlacementSwipe(_ thread: RemoteThread, section: DrawerSessionSection) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch section {
        case .active:
            store.moveSessionToRecent(thread.id)
        case .recent:
            Task { await store.archiveSession(thread.id) }
        }
    }

    private func resetDrawerThreadSwipe(_ threadID: String) {
        withAnimation(AppMotion.standard(reduceMotion)) {
            drawerThreadSwipeOffsets[threadID] = 0
        }

        if activeSwipedThreadID == threadID {
            activeSwipedThreadID = nil
        }
    }

    private func clearDrawerThreadSwipe(_ threadID: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            drawerThreadSwipeOffsets[threadID] = 0

            if activeSwipedThreadID == threadID {
                activeSwipedThreadID = nil
            }
        }
    }

    private func drawerThreadSwipeOffset(for threadID: String) -> CGFloat {
        drawerThreadSwipeOffsets[threadID] ?? 0
    }

    private func drawerThreadSwipeAction(for section: DrawerSessionSection) -> DrawerSessionSwipeAction {
        switch section {
        case .active:
            return .moveToRecent
        case .recent:
            return .archive
        }
    }

    private func drawerThreadSwipeTitle(for action: DrawerSessionSwipeAction) -> String {
        switch action {
        case .moveToRecent:
            return "Recent"
        case .archive:
            return "Archive"
        }
    }

    private func drawerThreadSwipeAccessibilityTitle(for action: DrawerSessionSwipeAction) -> String {
        switch action {
        case .moveToRecent:
            return "Move to Recent"
        case .archive:
            return "Archive"
        }
    }

    private func drawerThreadSwipeSystemImage(for action: DrawerSessionSwipeAction) -> String {
        switch action {
        case .moveToRecent:
            return "clock.arrow.circlepath"
        case .archive:
            return "archivebox.fill"
        }
    }

    private func drawerThreadSwipeTint(for action: DrawerSessionSwipeAction) -> Color {
        switch action {
        case .moveToRecent:
            return AppPalette.accent
        case .archive:
            return AppPalette.warning
        }
    }

    private var drawerEmptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No sessions")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(AppPalette.primaryText)

            Text(searchQuery.isEmpty ? "Start a new session from this Mac." : "Try a different search.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(AppPalette.secondaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionSurface(cornerRadius: 8)
    }

    private func filtered(_ threads: [RemoteThread]) -> [RemoteThread] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return threads }
        let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return threads.filter { thread in
            [
                thread.name ?? "",
                thread.preview,
                thread.cwd,
                thread.workspacePath ?? "",
                thread.backendLabel ?? "",
            ]
            .joined(separator: "\n")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .contains(normalizedQuery)
        }
    }

    private func drawerThreadAppearsLive(_ thread: RemoteThread) -> Bool {
        let phase = store.runtime(for: thread.id)?.phase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? thread.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if phase != "idle", phase != "unknown", phase != "completed" {
            return true
        }

        if thread.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "running" {
            return true
        }

        return thread.controller != nil
    }

    private func rowDetail(for thread: RemoteThread) -> String {
        let backendLabel = thread.backendLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let backendID = thread.backendId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let backend = backendLabel.isEmpty ? (backendID.isEmpty ? "Codex" : backendID) : backendLabel

        let workspacePath = thread.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cwdPath = thread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let stablePath = workspacePath.isEmpty ? cwdPath : workspacePath
        let workspace = stablePath.isEmpty ? "Workspace" : displayWorkspace(stablePath)
        return "\(backend) • \(workspace)"
    }

    private func refreshDrawer() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await store.refreshThreads() }
            group.addTask { await store.refreshRuntime() }
        }
    }
}

private func sessionTitle(_ thread: RemoteThread) -> String {
    let name = thread.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !name.isEmpty {
        return name
    }

    let workspace = thread.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let cwd = thread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    let stablePath = workspace.isEmpty ? cwd : workspace
    if !stablePath.isEmpty {
        return "\(displayWorkspace(stablePath)) · \(shortSessionID(thread.id))"
    }

    return "Session \(shortSessionID(thread.id))"
}

private func shortSessionID(_ id: String) -> String {
    String(id.suffix(5)).uppercased()
}

private func displayWorkspace(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home {
        return "~"
    }
    if path.hasPrefix(home + "/") {
        return "~/" + path.dropFirst(home.count + 1)
    }
    return URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent
}

private func statusLabel(for thread: RemoteThread) -> String {
    if thread.status == "running" {
        return "Running"
    }
    if thread.controller != nil {
        return "Controlled"
    }
    return "Idle"
}

private func statusTint(for thread: RemoteThread) -> Color {
    let phase = thread.status == "running"
        ? "running"
        : thread.controller == nil ? "idle" : "controlled"
    return FeedStyle.phaseColor(phase)
}

private func sessionChip(_ title: String, tint: Color) -> some View {
    Text(title)
        .font(.system(.caption2, design: .rounded, weight: .semibold))
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint.opacity(0.10), in: Capsule())
}
