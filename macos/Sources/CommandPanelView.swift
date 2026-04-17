import SwiftUI

struct CommandPanelView: View {
    @Environment(MacSessionStore.self) private var store
    @FocusState private var draftFocused: Bool

    var body: some View {
        @Bindable var store = store

        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("helm Command")
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                    Text("Open the active Command surface quickly, review the live session, and send the next turn without dropping into the full menu flow.")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Refresh") {
                    Task { await store.prepareForCommandPanel() }
                }
            }

            if !store.threads.isEmpty {
                Picker(
                    "Session",
                    selection: Binding(
                        get: { store.selectedThreadID ?? "" },
                        set: { store.selectThread($0) }
                    )
                ) {
                    ForEach(store.threads) { thread in
                        Text(thread.name ?? "Untitled Session")
                            .tag(thread.id)
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(store.selectedThread?.name ?? "No session selected")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                if let backendLabel = store.selectedThreadDetail?.backendLabel ?? store.selectedThread?.backendLabel {
                    Text("Backend: \(backendLabel)")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(store.selectedThreadControllerSummary)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(store.selectedThreadStatusSummary)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(store.selectedThreadHandoffSummary)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                if let notes = store.selectedThreadDetail?.affordances?.notes ?? store.selectedThreadDetail?.command?.notes {
                    Text(notes)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if !store.selectedApprovals.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pending Approval")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))

                    ForEach(store.selectedApprovals.prefix(1)) { approval in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(approval.title)
                                .font(.system(.footnote, design: .rounded, weight: .semibold))
                            if let detail = approval.detail {
                                Text(detail)
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                if approval.supportsAcceptForSession {
                                    Button("Allow Once") {
                                        Task { await store.decideApproval(approval, decision: "accept") }
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("Allow Session") {
                                        Task { await store.decideApproval(approval, decision: "acceptForSession") }
                                    }
                                    .buttonStyle(.bordered)
                                } else {
                                    Button("Approve") {
                                        Task { await store.decideApproval(approval, decision: "accept") }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }

                                Button(approval.kind == "permissions" ? "Deny" : "Decline") {
                                    Task { await store.decideApproval(approval, decision: "decline") }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(14)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Quick Command")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))

                HStack {
                    Button {
                        Task { await store.toggleVoiceCommandCapture() }
                    } label: {
                        Label(
                            store.commandCaptureActive ? "Stop Listening" : "Speak Command",
                            systemImage: store.commandCaptureActive ? "stop.circle.fill" : "mic.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    Text(store.commandCaptureSummary)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !store.commandTranscriptPreview.isEmpty {
                    Text(store.commandTranscriptPreview)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                TextField("Send the next Command", text: $store.draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($draftFocused)
                    .onSubmit {
                        Task { await store.sendDraft() }
                    }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Git Shortcuts")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(.secondary)

                    HStack {
                        gitShortcutButton(
                            title: "Git Status",
                            prompt: "Run git status and summarize the working tree briefly."
                        )
                        gitShortcutButton(
                            title: "Diff Summary",
                            prompt: "Summarize the current diff at a high level."
                        )
                    }

                    HStack {
                        gitShortcutButton(
                            title: "Review Changes",
                            prompt: "Review the uncommitted changes for risks or regressions and summarize the key findings."
                        )
                        gitShortcutButton(
                            title: "Last Commit",
                            prompt: "Summarize the latest commit and what it changed."
                        )
                    }
                }

                HStack {
                    Button("Take Control") {
                        Task { await store.takeControl() }
                    }
                    .buttonStyle(.bordered)

                    if store.selectedThreadDetail?.affordances?.canInterrupt ?? true {
                        Button("Interrupt") {
                            Task { await store.interrupt() }
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    Button("Send Command") {
                        Task { await store.sendDraft() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let detail = store.selectedThreadDetail {
                if !(detail.affordances?.showsOperationalSnapshot ?? true) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Operational Snapshot")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        Text(detail.affordances?.notes ?? "Operational details are backend-specific for this session.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }

                let operationalItems = detail.turns
                    .flatMap(\.items)
                    .filter { $0.type == "commandExecution" || $0.type == "fileChange" }
                    .prefix(4)

                if (detail.affordances?.showsOperationalSnapshot ?? true) && !operationalItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Operational Snapshot")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))

                        ForEach(Array(operationalItems)) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.type == "commandExecution" ? "Command: \(item.title)" : "Changes: \(item.title)")
                                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                                if let detail = item.detail {
                                    Text(detail)
                                        .font(.system(.caption, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(minWidth: 520, minHeight: 420)
        .task {
            await store.start()
            await store.prepareForCommandPanel()
            draftFocused = true
        }
    }

    private func gitShortcutButton(title: String, prompt: String) -> some View {
        Button(title) {
            Task { await store.sendQuickCommand(prompt) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
