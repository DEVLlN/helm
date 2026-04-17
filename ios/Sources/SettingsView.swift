import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var store
    @FocusState private var focusedField: SettingsField?
    @State private var bridgeURL = "http://127.0.0.1:8787"
    @State private var pairingToken = ""
    @State private var showDiagnostics = false
    @State private var showPairingScanner = false
    @State private var showAdvancedConnection = false

    private enum SettingsField: Hashable {
        case bridgeURL, pairingToken
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusHeader
                preferencesSection
                connectionSection
                commandSection
                alertsSection
                backendSection
                voiceProviderSection

                if showDiagnostics {
                    diagnosticsSection
                }

                footerRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showPairingScanner) {
            PairingQRScannerView { payload in
                await store.applyPairingSetupLink(payload)
                syncBridgeFields()
                await store.refreshSetupStatus()
                return store.bridge.hasPairingToken
            }
        }
        .onAppear {
            syncBridgeFields()
            Task {
                await store.refreshNotificationAuthorization()
                await store.refreshPairingStatus()
                await store.refreshBackends()
                await store.refreshVoiceProviders()
            }
        }
    }

    // MARK: - Status header

    private var statusHeader: some View {
        HelmSurfaceHeader(
            eyebrow: "Bridge",
            title: store.connectionSummary,
            detail: store.pairingStatusSummary,
            systemImage: connectionHeaderSymbol,
            tint: connectionHeaderTint,
            chips: settingsHeaderChips
        )
    }

    private var settingsHeaderChips: [HelmSurfaceHeaderChip] {
        var chips = [
            HelmSurfaceHeaderChip(store.setupCompletionSummary, tint: connectionHeaderTint)
        ]

        if let backend = store.effectiveCreateBackend {
            chips.append(HelmSurfaceHeaderChip(backend.label, tint: AppPalette.accent))
        }

        if let provider = store.effectiveVoiceProvider {
            chips.append(HelmSurfaceHeaderChip(provider.label))
        }

        return chips
    }

    private var connectionHeaderSymbol: String {
        switch store.connectionSummary {
        case "Connected to bridge", "Local pairing loaded":
            return "checkmark.seal.fill"
        case "Bridge needs pairing":
            return "qrcode.viewfinder"
        case "Bridge unavailable", "Bridge disconnected":
            return "antenna.radiowaves.left.and.right.slash"
        default:
            return store.connectionSummary.contains("unavailable") ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right"
        }
    }

    private var connectionHeaderTint: Color {
        if store.connectionSummary == "Connected to bridge" || store.connectionSummary == "Local pairing loaded" {
            return AppPalette.accent
        }

        if store.connectionSummary.contains("unavailable") || store.connectionSummary.contains("disconnected") {
            return AppPalette.warning
        }

        return store.bridge.hasPairingToken ? AppPalette.accent : AppPalette.warning
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Preferences")

            settingsRow("Appearance") {
                Picker("Appearance", selection: Binding(
                    get: { store.appAppearanceMode },
                    set: { store.setAppAppearanceMode($0) }
                )) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Toggle("Auto-collapse session groups", isOn: Binding(
                get: { store.sessionAutoCollapseEnabled },
                set: { store.setSessionAutoCollapseEnabled($0) }
            ))
            .font(.system(.subheadline, design: .rounded))
            .toggleStyle(.switch)

            Text("Off keeps workspace groups expanded by default. On starts each workspace collapsed until you open it.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(AppPalette.secondaryText)
        }
        .settingsCard()
    }

    // MARK: - Connection

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Pairing")

            Text("Scan the pairing QR from helm on your Mac. If you already copied a setup link, import it directly.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(AppPalette.secondaryText)

            HStack(spacing: 10) {
                Button {
                    showPairingScanner = true
                } label: {
                    Label("Scan Pairing QR", systemImage: "qrcode.viewfinder")
                }
                .settingsButtonPrimary()

                Button {
                    Task {
                        await store.importPairingSetupFromClipboard()
                        syncBridgeFields()
                        await store.refreshSetupStatus()
                    }
                } label: {
                    Label("Import Setup Link", systemImage: "link")
                }
                .settingsButton()
            }

            HStack(spacing: 10) {
                Button("Refresh Status") {
                    Task {
                        await store.refreshSetupStatus()
                        syncBridgeFields()
                    }
                }
                .settingsButton()

                if store.bridge.hasPairingToken {
                    Label("Paired on this iPhone", systemImage: "checkmark.shield")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(AppPalette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            Text(store.pairingStatusSummary)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(AppPalette.secondaryText)

            if store.bridge.hasPairingToken {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current bridge")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(AppPalette.secondaryText)

                    Text(bridgeURL)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AppPalette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(AppPalette.mutedPanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            DisclosureGroup(
                isExpanded: $showAdvancedConnection,
                content: {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Use manual bridge details only if QR scan or setup-link import is unavailable.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(AppPalette.secondaryText)

                        TextField("Bridge URL", text: $bridgeURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.subheadline, design: .monospaced))
                            .focused($focusedField, equals: .bridgeURL)
                            .onSubmit { focusedField = nil }
                            .submitLabel(.done)
                            .padding(12)
                            .inputFieldSurface(cornerRadius: 12)

                        SecureField("Pairing token", text: $pairingToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.subheadline, design: .monospaced))
                            .focused($focusedField, equals: .pairingToken)
                            .onSubmit { focusedField = nil }
                            .submitLabel(.done)
                            .padding(12)
                            .inputFieldSurface(cornerRadius: 12)

                        HStack(spacing: 8) {
                            Button("Read Local Pairing") {
                                Task {
                                    await store.readLocalPairing()
                                    syncBridgeFields()
                                    await store.refreshSetupStatus()
                                }
                            }
                            .settingsButton()

                            Spacer()

                            Button("Copy Setup Link") {
                                UIPasteboard.general.string = store.pairingSetupURLString
                            }
                            .settingsButton()
                            .disabled(store.pairingSetupURLString?.isEmpty ?? true)
                        }

                        if let setupLink = store.pairingSetupURLString, !setupLink.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Setup Link")
                                    .font(.system(.caption, design: .rounded, weight: .semibold))
                                    .foregroundStyle(AppPalette.secondaryText)

                                Text(setupLink)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(AppPalette.primaryText)
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(AppPalette.mutedPanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }

                        if !store.pairingSuggestedBridgeURLs.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Suggested URLs")
                                    .font(.system(.caption, design: .rounded, weight: .semibold))
                                    .foregroundStyle(AppPalette.secondaryText)

                                ForEach(store.pairingSuggestedBridgeURLs, id: \.self) { candidate in
                                    HStack(spacing: 10) {
                                        Text(candidate)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(AppPalette.primaryText)
                                            .lineLimit(1)

                                        Spacer()

                                        Button("Use") {
                                            bridgeURL = candidate
                                        }
                                        .settingsButton()
                                    }
                                    .padding(10)
                                    .background(AppPalette.mutedPanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                        }

                        HStack {
                            Button("Reopen Onboarding") {
                                store.reopenOnboarding()
                            }
                            .settingsButton()

                            Spacer()

                            Button("Apply Manual Setup") {
                                if let url = URL(string: bridgeURL) {
                                    store.bridge.baseURL = url
                                }
                                store.bridge.pairingToken = pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
                                Task {
                                    await store.refreshSetupStatus()
                                    syncBridgeFields()
                                }
                            }
                            .settingsButtonPrimary()
                        }
                    }
                    .padding(.top, 8)
                },
                label: {
                    Text("Advanced pairing")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(AppPalette.secondaryText)
                }
            )
            .tint(AppPalette.secondaryText)
        }
        .settingsCard()
    }

    private func syncBridgeFields() {
        bridgeURL = store.bridge.baseURL.absoluteString
        pairingToken = store.bridge.pairingToken
    }

    // MARK: - Command

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Command")

            settingsRow("Transport") {
                Picker("", selection: Binding(
                    get: { store.voiceMode },
                    set: { store.setVoiceMode($0) }
                )) {
                    ForEach(VoiceRuntimeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            settingsRow("Response Style") {
                Picker("", selection: Binding(
                    get: { store.commandResponseStyle },
                    set: { store.setCommandResponseStyle($0) }
                )) {
                    ForEach(CommandResponseStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }

            Toggle("Auto-resume Command", isOn: Binding(
                get: { store.commandAutoResumeEnabled },
                set: { store.setCommandAutoResumeEnabled($0) }
            ))
            .font(.system(.subheadline, design: .rounded))
            .toggleStyle(.switch)
        }
        .settingsCard()
    }

    // MARK: - Alerts

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Alerts")

            Toggle("Notifications", isOn: Binding(
                get: { store.notificationsEnabled },
                set: { store.setNotificationsEnabled($0) }
            ))
            .font(.system(.subheadline, design: .rounded))
            .toggleStyle(.switch)

            if store.notificationsEnabled {
                Text(store.notificationAuthorizationSummary)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(AppPalette.secondaryText)
            }

            Toggle("Spoken Updates", isOn: Binding(
                get: { store.spokenStatusEnabled },
                set: { store.setSpokenStatusEnabled($0) }
            ))
            .font(.system(.subheadline, design: .rounded))
            .toggleStyle(.switch)

            if store.spokenStatusEnabled {
                Picker("", selection: Binding(
                    get: { store.spokenAlertMode },
                    set: { store.setSpokenAlertMode($0) }
                )) {
                    ForEach(SpokenAlertMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .settingsCard()
    }

    // MARK: - Backend

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Backend")

            if store.availableBackends.isEmpty {
                Text("No backends available")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(AppPalette.secondaryText)
            } else {
                Picker(
                    "Backend",
                    selection: Binding(
                        get: { store.effectiveCreateBackend?.id ?? "" },
                        set: { store.setPreferredBackendID($0) }
                    )
                ) {
                    ForEach(store.availableBackends.filter(\.available)) { backend in
                        Text(backend.label).tag(backend.id)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(.subheadline, design: .rounded))

                ForEach(store.availableBackends) { backend in
                    HStack {
                        Text(backend.label)
                            .font(.system(.subheadline, design: .rounded, weight: .medium))

                        if backend.isDefault {
                            Text("Default")
                                .font(.system(.caption2, design: .rounded, weight: .semibold))
                                .foregroundStyle(AppPalette.secondaryText)
                        }

                        Spacer()

                        Circle()
                            .fill(backend.available ? AppPalette.accent : AppPalette.secondaryText.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .settingsCard()
    }

    // MARK: - Voice provider

    private var voiceProviderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Voice Provider")

            if store.availableVoiceProviders.isEmpty {
                Text("No providers available")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(AppPalette.secondaryText)
            } else {
                Picker(
                    "Provider",
                    selection: Binding(
                        get: { store.effectiveVoiceProvider?.id ?? "" },
                        set: { store.setPreferredVoiceProviderID($0) }
                    )
                ) {
                    ForEach(store.availableVoiceProviders.filter(\.available)) { provider in
                        Text(provider.label).tag(provider.id)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(.subheadline, design: .rounded))

                ForEach(store.availableVoiceProviders) { provider in
                    HStack {
                        Text(provider.label)
                            .font(.system(.subheadline, design: .rounded, weight: .medium))

                        if provider.id == store.bridgeDefaultVoiceProviderID {
                            Text("Default")
                                .font(.system(.caption2, design: .rounded, weight: .semibold))
                                .foregroundStyle(AppPalette.secondaryText)
                        }

                        Spacer()

                        Circle()
                            .fill(provider.available ? AppPalette.accent : AppPalette.secondaryText.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .settingsCard()
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Diagnostics")

            HStack(spacing: 8) {
                Image(systemName: store.diagnosticsHealthStatus.symbolName)
                    .foregroundStyle(diagnosticsTint(for: store.diagnosticsHealthStatus))
                    .font(.system(size: 13, weight: .semibold))
                Text(store.diagnosticsHealthStatus.title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                Spacer()
            }

            ForEach(store.diagnosticsMetrics) { metric in
                HStack(spacing: 8) {
                    Image(systemName: metric.status.symbolName)
                        .foregroundStyle(diagnosticsTint(for: metric.status))
                        .font(.system(size: 11))

                    Text(metric.title)
                        .font(.system(.caption, design: .rounded, weight: .medium))

                    Spacer()

                    Text(metric.sampleSummary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AppPalette.secondaryText)
                }
            }
        }
        .settingsCard()
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack {
            Button(showDiagnostics ? "Hide Diagnostics" : "Diagnostics") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showDiagnostics.toggle()
                }
            }
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(AppPalette.secondaryText)

            Spacer()

            Button("Refresh") {
                Task { await store.refreshSetupStatus() }
            }
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(AppPalette.secondaryText)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption, design: .rounded, weight: .bold))
            .foregroundStyle(AppPalette.secondaryText)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func settingsRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
            content()
        }
    }

    private func diagnosticsTint(for status: ResponsivenessBudgetStatus) -> Color {
        switch status {
        case .unknown: return AppPalette.secondaryText
        case .healthy: return AppPalette.accent
        case .warning: return AppPalette.warning
        case .critical: return AppPalette.danger
        }
    }
}

// MARK: - Settings view modifiers

extension View {
    func settingsCard() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppPalette.elevatedPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppPalette.border, lineWidth: 1)
            )
    }

    func settingsButton() -> some View {
        self
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .subtleActionCapsule()
    }

    func settingsButtonPrimary() -> some View {
        self
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(AppPalette.accent, in: Capsule())
    }
}
