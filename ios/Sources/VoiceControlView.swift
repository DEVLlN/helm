import SwiftUI

struct VoiceControlView: View {
    @Environment(SessionStore.self) private var store
    @FocusState private var localCommandFieldFocused: Bool
    @State private var localCommandDraft = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 18)

                commandSurfaceHeader

                commandCenter

                if store.voiceMode != .openAIRealtime {
                    localCommandComposer
                }

                Spacer(minLength: 40)

                if !store.voiceEntries.isEmpty {
                    transcriptFeed
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Command")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await store.prepareCommandSurface()
        }
    }

    // MARK: - Command center

    private var commandSurfaceHeader: some View {
        HelmSurfaceHeader(
            eyebrow: "Command target",
            title: commandHeaderTitle,
            detail: store.commandTargetSummary,
            systemImage: commandHeaderSymbol,
            tint: commandHeaderTint,
            chips: commandHeaderChips
        )
    }

    private var commandHeaderTitle: String {
        store.commandTargetThread?.name ?? "No session selected"
    }

    private var commandHeaderChips: [HelmSurfaceHeaderChip] {
        var chips = [
            HelmSurfaceHeaderChip(store.voiceMode.title, tint: AppPalette.accent)
        ]

        if let backend = store.commandTargetBackendSummary {
            chips.append(HelmSurfaceHeaderChip(backend.label))
        }

        if let phase = store.commandTargetRuntime?.phase, phase != "idle", phase != "unknown" {
            chips.append(HelmSurfaceHeaderChip(FeedStyle.phaseLabel(phase), tint: FeedStyle.phaseColor(phase)))
        }

        if store.realtimeCaptureActive || store.liveCommandPhase != .idle {
            chips.append(HelmSurfaceHeaderChip(store.liveCommandPhase.title, tint: commandHeaderTint))
        }

        if !store.commandTargetSupportsVoiceCommand {
            chips.append(HelmSurfaceHeaderChip("Visual only", tint: AppPalette.warning))
        }

        return chips
    }

    private var commandHeaderSymbol: String {
        if store.commandTargetThread == nil {
            return "scope"
        }

        switch store.liveCommandPhase {
        case .listening:
            return "ear.and.waveform"
        case .dispatching:
            return "paperplane.circle.fill"
        case .responding:
            return "speaker.wave.2.circle.fill"
        case .retargeting:
            return "arrow.left.arrow.right.circle.fill"
        case .failed:
            return "exclamationmark.octagon.fill"
        case .idle, .preparing:
            return "command.circle.fill"
        }
    }

    private var commandHeaderTint: Color {
        if store.liveCommandPhase == .failed {
            return AppPalette.danger
        }

        if store.commandTargetThread == nil {
            return AppPalette.warning
        }

        return AppPalette.accent
    }

    private var commandCenter: some View {
        VStack(spacing: 20) {
            // Main action button
            Button {
                if store.voiceMode == .openAIRealtime {
                    if store.realtimeCaptureActive {
                        store.stopRealtimeCapture()
                    } else {
                        Task { await store.startRealtimeCapture() }
                    }
                } else {
                    localCommandFieldFocused = true
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    AppPalette.accent.opacity(store.realtimeCaptureActive ? 1.0 : 0.7),
                                    AppPalette.accent.opacity(0.12),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: store.realtimeCaptureActive ? 12 : 6,
                                endRadius: 88
                            )
                        )
                        .frame(width: 160, height: 160)

                    Circle()
                        .stroke(AppPalette.border, lineWidth: 1)
                        .frame(width: 120, height: 120)

                    Image(systemName: micIcon)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(store.realtimeCaptureActive ? .white : AppPalette.primaryText)
                }
                .drawingGroup()
            }
            .buttonStyle(.plain)

            Text(statusDetail)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(AppPalette.secondaryText)
                .multilineTextAlignment(.center)

            // Phase pill when active
            if store.realtimeCaptureActive || store.liveCommandPhase != .idle {
                HStack(spacing: 8) {
                    Image(systemName: store.liveCommandPhase.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(store.liveCommandPhase.title)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                }
                .foregroundStyle(store.liveCommandPhase == .failed ? AppPalette.danger : AppPalette.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    (store.liveCommandPhase == .failed ? AppPalette.danger : AppPalette.accent).opacity(0.12),
                    in: Capsule()
                )
            }

            // Live transcript preview
            if !store.realtimeTranscriptPreview.isEmpty {
                Text(store.realtimeTranscriptPreview)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(AppPalette.primaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .inputFieldSurface(cornerRadius: 18)
            }
        }
    }

    private var localCommandComposer: some View {
        VStack(spacing: 10) {
            TextField("Type a Command for the active session", text: $localCommandDraft, axis: .vertical)
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.asciiCapable)
                .focused($localCommandFieldFocused)
                .submitLabel(.send)
                .onSubmit {
                    sendLocalCommand()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .inputFieldSurface(cornerRadius: 18)

            HStack {
                Text("Local Command sends through the bridge and keeps full output in the live session.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(AppPalette.secondaryText)

                Spacer()

                Button("Send") {
                    sendLocalCommand()
                }
                .settingsButtonPrimary()
                .disabled(localCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.top, 22)
    }

    // MARK: - Transcript feed

    private var transcriptFeed: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(store.voiceEntries.suffix(8)) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Text(entry.role.title)
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .foregroundStyle(
                                entry.role == .user ? AppPalette.secondaryText :
                                entry.role == .assistant ? AppPalette.accent :
                                AppPalette.secondaryText
                            )
                            .frame(width: 36, alignment: .trailing)

                        Text(entry.text)
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(AppPalette.primaryText)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxHeight: 180)
        .padding(.bottom, 8)
    }

    // MARK: - Computed helpers

    private var micIcon: String {
        if store.realtimeCaptureActive {
            return "waveform.circle.fill"
        }
        return store.voiceMode == .openAIRealtime ? "waveform" : "mic.fill"
    }

    private var statusDetail: String {
        if store.realtimeCaptureActive {
            return store.commandTargetSummary
        }
        if store.commandTargetThread == nil {
            return "Select or create a session first."
        }
        return store.commandTargetSummary
    }

    private func sendLocalCommand() {
        let text = localCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        localCommandDraft = ""
        localCommandFieldFocused = false
        Task { await store.submitVoiceCommand(text) }
    }
}
