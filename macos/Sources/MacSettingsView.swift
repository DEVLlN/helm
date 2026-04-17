import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct MacSettingsView: View {
    @Environment(MacSessionStore.self) private var store
    @State private var bridgeURL = ""
    @State private var pairingToken = ""

    var body: some View {
        @Bindable var store = store

        Form {
            Section("Setup") {
                Text(store.setupCompletionSummary)
                    .foregroundStyle(.secondary)

                ForEach(Array(store.setupChecklistItems.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(item.isComplete ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                            Text(item.detail)
                                .foregroundStyle(.secondary)
                                .font(.system(.caption))
                        }
                    }
                }

                Button("Refresh Setup Status") {
                    Task { await store.refreshSetupStatus() }
                }

                if !store.shouldShowOnboarding {
                    Button("Show Welcome Guide") {
                        store.reopenOnboarding()
                    }
                }
            }

            Section("CLI Setup") {
                Text("Use helm to install local helpers, enable runtime wrapping for Codex and Claude across new terminals and relaunched PATH-aware Mac apps, then start the bridge and pair your phone from the QR below.")
                    .foregroundStyle(.secondary)

                HStack {
                    Button(store.localSetupBusy ? "Preparing…" : "Run Full Setup") {
                        Task { await store.runFullCLISetup() }
                    }
                    .disabled(store.localSetupBusy)

                    Button(store.localSetupBusy ? "Installing…" : "Install CLI Helpers") {
                        Task { await store.installCLIHelpers() }
                    }
                    .disabled(store.localSetupBusy)
                }

                HStack {
                    Button(store.localSetupBusy ? "Enabling…" : "Enable Runtime Wrapping") {
                        Task { await store.enableShellAutoinjection() }
                    }
                    .disabled(store.localSetupBusy)

                    Button(store.localSetupBusy ? "Starting…" : "Start Bridge for Pairing") {
                        Task { await store.startBridgeForPairing() }
                    }
                    .disabled(store.localSetupBusy)
                }

                Text(store.localSetupSummary)
                    .foregroundStyle(.secondary)

                if !store.localSetupOutput.isEmpty {
                    ScrollView {
                        Text(store.localSetupOutput)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            }

            Section("Bridge") {
                Text("helm pairs the Mac app to the local bridge so the menu bar client, iPhone, watchOS, CarPlay, CLI, and desktop Command panel all stay attached to the same Codex thread state. The QR below is the primary phone pairing path.")
                    .foregroundStyle(.secondary)

                TextField("Bridge URL", text: $bridgeURL)
                SecureField("Pairing token", text: $pairingToken)

                HStack {
                    Button("Read Local Pairing") {
                        if let url = URL(string: bridgeURL) {
                            store.bridge.baseURL = url
                        }

                        Task {
                            await store.refreshPairingStatus()
                            pairingToken = store.bridge.pairingToken
                        }
                    }

                    Button("Apply") {
                        if let url = URL(string: bridgeURL) {
                            store.bridge.baseURL = url
                        }
                        store.bridge.pairingToken = pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await store.refreshPairingStatus() }
                    }
                }

                Text(store.pairingStatusSummary)
                    .foregroundStyle(.secondary)

                if let pairingFilePath = store.pairingFilePath {
                    Text(pairingFilePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if let setupURL = store.pairingSetupURLString {
                    Text("helm setup link")
                        .foregroundStyle(.secondary)
                    Text(setupURL)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    PairingQRCodeView(setupURL: setupURL)
                }

                if !store.pairingSuggestedBridgeURLs.isEmpty {
                    Text("Suggested bridge URLs")
                        .foregroundStyle(.secondary)
                    ForEach(store.pairingSuggestedBridgeURLs, id: \.self) { suggestedURL in
                        Text(suggestedURL)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    if let setupURL = store.pairingSetupURLString {
                        Button("Copy Setup Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(setupURL, forType: .string)
                        }
                    }

                    if let firstSuggestedURL = store.pairingSuggestedBridgeURLs.first {
                        Button("Use Suggested URL") {
                            bridgeURL = firstSuggestedURL
                            if let url = URL(string: firstSuggestedURL) {
                                store.bridge.baseURL = url
                            }
                        }
                    }
                }

                Text(store.diagnosticsSummary)
                    .font(.system(.caption))
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Label(store.diagnosticsHealthStatus.title, systemImage: store.diagnosticsHealthStatus.symbolName)
                    .foregroundStyle(diagnosticsTint(for: store.diagnosticsHealthStatus))

                Text(store.diagnosticsHealthSummary)
                    .foregroundStyle(.secondary)

                ForEach(store.diagnosticsMetrics) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(metric.title)
                            Spacer()
                            Text(metric.sampleSummary)
                                .foregroundStyle(.secondary)
                        }

                        Text(metric.budgetSummary)
                            .font(.system(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Backends") {
                Text("helm is still Codex-first, but backend metadata is now exposed so the product can expand into local models and other providers without changing the control model.")
                    .foregroundStyle(.secondary)

                if store.availableBackends.isEmpty {
                    Text("No backend metadata available yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker(
                        "New Session Backend",
                        selection: Binding(
                            get: { store.effectiveCreateBackend?.id ?? "" },
                            set: { store.setPreferredBackendID($0) }
                        )
                    ) {
                        ForEach(store.availableBackends.filter(\.available)) { backend in
                            Text(backend.label).tag(backend.id)
                        }
                    }

                    ForEach(store.availableBackends) { backend in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backend.label + (backend.isDefault ? " • Default" : ""))
                            Text(backend.description)
                                .foregroundStyle(.secondary)
                            if let availabilityDetail = backend.availabilityDetail {
                                Text(availabilityDetail)
                                    .font(.system(.caption))
                                    .foregroundStyle(.secondary)
                            }
                            Text(capabilitySummary(for: backend))
                                .font(.system(.caption))
                                .foregroundStyle(.secondary)
                            Text(commandSemanticsSummary(for: backend))
                                .font(.system(.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Voice Providers") {
                Text("Live Command speech and Realtime now route through a bridge-side voice provider layer. OpenAI Realtime is the current prototype path, and PersonaPlex is the first self-hosted target behind the same interface.")
                    .foregroundStyle(.secondary)

                if store.availableVoiceProviders.isEmpty {
                    Text("No voice provider metadata available yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker(
                        "Preferred Voice Provider",
                        selection: Binding(
                            get: { store.effectiveVoiceProvider?.id ?? "" },
                            set: { store.setPreferredVoiceProviderID($0) }
                        )
                    ) {
                        ForEach(store.availableVoiceProviders.filter(\.available)) { provider in
                            Text(provider.label).tag(provider.id)
                        }
                    }

                    Text(store.preferredVoiceProviderSummary)
                        .foregroundStyle(.secondary)

                    ForEach(store.availableVoiceProviders) { provider in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.label + (provider.id == store.bridgeDefaultVoiceProviderID ? " • Default" : ""))
                            Text(voiceProviderSummary(for: provider))
                                .foregroundStyle(.secondary)
                            if let availabilityDetail = provider.availabilityDetail {
                                Text(availabilityDetail)
                                    .font(.system(.caption))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button("Refresh Provider Bootstrap") {
                        Task { await store.refreshVoiceProviderBootstrap() }
                    }

                    Text(store.voiceProviderBootstrapSummary)
                        .foregroundStyle(.secondary)

                    if !store.voiceProviderBootstrapJSON.isEmpty {
                        ScrollView(.horizontal) {
                            Text(store.voiceProviderBootstrapJSON)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                    }
                }
            }

            Section("Alerts") {
                Toggle(
                    "Enable Command alerts",
                    isOn: Binding(
                        get: { store.notificationsEnabled },
                        set: { store.setNotificationsEnabled($0) }
                    )
                )
                Toggle(
                    "Speak Command updates",
                    isOn: Binding(
                        get: { store.spokenStatusEnabled },
                        set: { store.setSpokenStatusEnabled($0) }
                    )
                )
                Toggle(
                    "Wake helm Command for blockers and approvals",
                    isOn: Binding(
                        get: { store.attentionWakeEnabled },
                        set: { store.setAttentionWakeEnabled($0) }
                    )
                )
                Toggle(
                    "Start listening when helm wakes for attention",
                    isOn: Binding(
                        get: { store.attentionAutoListenEnabled },
                        set: { store.setAttentionAutoListenEnabled($0) }
                    )
                )

                Text("Notification authorization: \(store.notificationAuthorizationSummary)")
                    .foregroundStyle(.secondary)
                Text("Alerts are what let helm surface blockers, approvals, and completions even when the Command panel is closed.")
                    .foregroundStyle(.secondary)
            }

            Section("Voice Command") {
                Text("Speech recognition: \(store.speechAuthorizationSummary)")
                    .foregroundStyle(.secondary)
                Text("Microphone: \(store.microphoneAuthorizationSummary)")
                    .foregroundStyle(.secondary)
                Text("Speech permissions are only used for spoken Command capture on this Mac. Codex execution still runs through the shared bridge-backed thread.")
                    .foregroundStyle(.secondary)
                Toggle(
                    "Keep helm listening in the background",
                    isOn: Binding(
                        get: { store.standbyListeningEnabled },
                        set: { store.setStandbyListeningEnabled($0) }
                    )
                )
                Toggle(
                    "Keep listening after spoken commands",
                    isOn: Binding(
                        get: { store.continuousListeningEnabled },
                        set: { store.setContinuousListeningEnabled($0) }
                    )
                )
                Toggle(
                    "Start listening when opening helm Command",
                    isOn: Binding(
                        get: { store.commandPanelAutoListenEnabled },
                        set: { store.setCommandPanelAutoListenEnabled($0) }
                    )
                )

                Button(store.commandCaptureActive ? "Stop Listening" : "Start Listening") {
                    Task { await store.toggleVoiceCommandCapture() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 420)
        .padding()
        .onAppear {
            bridgeURL = store.bridge.baseURL.absoluteString
            pairingToken = store.bridge.pairingToken
            Task {
                await store.refreshSpeechAuthorization()
                await store.refreshBackends()
                await store.refreshVoiceProviders()
            }
        }
    }

    private func capabilitySummary(for backend: MacBackendSummary) -> String {
        var parts: [String] = []
        if backend.capabilities.voiceCommand { parts.append("Command") }
        if backend.capabilities.realtimeVoice { parts.append("Realtime") }
        if backend.capabilities.hooksAndSkillsParity { parts.append("Hooks and skills") }
        if backend.capabilities.sharedThreadHandoff { parts.append("Shared handoff") }
        return parts.isEmpty ? "No capability metadata." : parts.joined(separator: " • ")
    }

    private func commandSemanticsSummary(for backend: MacBackendSummary) -> String {
        [
            "Routing: \(label(forRouting: backend.command.routing))",
            "Approvals: \(label(forApproval: backend.command.approvals))",
            "Handoff: \(label(forHandoff: backend.command.handoff))",
            "Voice: \(label(forVoiceInput: backend.command.voiceInput)) / \(label(forVoiceOutput: backend.command.voiceOutput))",
            backend.command.notes
        ]
        .joined(separator: "\n")
    }

    private func voiceProviderSummary(for provider: MacVoiceProviderSummary) -> String {
        var parts: [String] = []
        parts.append(provider.kind.capitalized)
        if provider.supportsSpeechSynthesis { parts.append("Speech") }
        if provider.supportsRealtimeSessions { parts.append("Realtime") }
        if provider.supportsClientSecrets { parts.append("Client secrets") }
        if provider.supportsNativeBootstrap == true { parts.append("Native bootstrap") }
        return parts.joined(separator: " • ")
    }

    private func label(forRouting value: String) -> String {
        switch value {
        case "threadTurns":
            return "Shared thread turns"
        case "providerChat":
            return "Provider chat"
        case "hybrid":
            return "Hybrid"
        default:
            return value
        }
    }

    private func label(forApproval value: String) -> String {
        switch value {
        case "bridgeDecisions":
            return "Bridge decisions"
        case "providerManaged":
            return "Provider managed"
        case "none":
            return "No approval loop"
        default:
            return value
        }
    }

    private func label(forHandoff value: String) -> String {
        switch value {
        case "sharedThread":
            return "Shared thread"
        case "sessionResume":
            return "Session resume"
        case "isolated":
            return "Isolated"
        default:
            return value
        }
    }

    private func label(forVoiceInput value: String) -> String {
        switch value {
        case "bridgeRealtime":
            return "Bridge Realtime input"
        case "localSpeech":
            return "Local speech input"
        case "providerNative":
            return "Provider-native input"
        case "unsupported":
            return "Unsupported"
        default:
            return value
        }
    }

    private func label(forVoiceOutput value: String) -> String {
        switch value {
        case "bridgeSpeech":
            return "Bridge speech output"
        case "bridgeRealtime":
            return "Bridge Realtime output"
        case "providerNative":
            return "Provider-native output"
        case "none":
            return "No voice output"
        default:
            return value
        }
    }

    private func diagnosticsTint(for status: MacResponsivenessBudgetStatus) -> Color {
        switch status {
        case .unknown:
            return .secondary
        case .healthy:
            return .green
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }
}

private struct PairingQRCodeView: View {
    let setupURL: String

    var body: some View {
        if let image = PairingQRCodeRenderer.image(for: setupURL) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Scan to pair on iPhone")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)

                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 184, height: 184)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text("The preferred bridge address is baked into this QR code. When Tailscale is available, helm prioritizes that route ahead of local LAN addresses.")
                    .font(.system(.caption2))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }
}

private enum PairingQRCodeRenderer {
    private static let context = CIContext()

    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: 184, height: 184))
    }
}
