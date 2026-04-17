import SwiftUI

struct MenuBarRoot: View {
    @Environment(MacSessionStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var store = store
        let openCommandPanel = {
            openWindow(id: "command-panel")
        }

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("helm")
                        .font(.headline)
                    Text("Same live Codex system as the CLI and iPhone")
                        .font(.caption.weight(.semibold))
                    Text(store.menuBarSubtitle)
                        .font(.caption2)
                    Text(store.connectionSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let recoverySummary = store.recoverySummary {
                        Text(recoverySummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(store.diagnosticsHealthSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(store.pairingStatusSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack {
                    Button {
                        Task {
                            await store.openCommandPanelAndPrepare(startListening: true)
                        }
                    } label: {
                        Image(systemName: store.commandCaptureActive ? "stop.circle.fill" : "mic.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(store.commandCaptureActive ? "Stop spoken Command capture" : "Open helm Command and start listening")

                    Button("Command") {
                        Task { await store.openCommandPanelAndPrepare() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Text("This Mac surface stays attached to the same shared thread state. \(store.globalAttentionSummary)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.shouldShowOnboarding {
                onboardingCard
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Recent Sessions")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Refresh") {
                        Task { await store.refreshThreads() }
                    }
                    .buttonStyle(.borderless)
                }

                if store.threads.isEmpty {
                    Text("No sessions loaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(store.threads.prefix(6))) { thread in
                        Button {
                            store.selectThread(thread.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(thread.name ?? "Untitled Session")
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    if thread.isHelmManaged {
                                        Text("helm")
                                            .font(.caption2.weight(.bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule(style: .continuous)
                                                    .fill(Color.accentColor.opacity(0.14))
                                            )
                                    }
                                    Text(thread.status.capitalized)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Text(thread.preview)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(store.selectedThreadID == thread.id ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let selectedThread = store.selectedThread {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(selectedThread.name ?? "Selected Session")
                        .font(.subheadline.weight(.semibold))
                    Text(store.selectedThreadControllerSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(store.selectedThreadStatusSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        if selectedThread.controller?.clientId == store.bridge.identity.id {
                            Button("Release") {
                                Task { await store.releaseControl() }
                            }
                        } else if selectedThread.controller == nil {
                            Button("Take Control") {
                                Task { await store.takeControl() }
                            }
                        } else {
                            Button("Take Over") {
                                Task { await store.takeControl(force: true) }
                            }
                        }

                        Button("Interrupt") {
                            Task { await store.interrupt() }
                        }
                    }
                    .buttonStyle(.bordered)

                    if !store.selectedApprovals.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Approvals")
                                .font(.caption.weight(.semibold))

                            ForEach(store.selectedApprovals.prefix(2)) { approval in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(approval.title)
                                        .font(.caption.weight(.medium))

                                    if let detail = approval.detail {
                                        Text(detail)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    HStack {
                                        if approval.supportsAcceptForSession {
                                            Button("Allow Once") {
                                                Task { await store.decideApproval(approval, decision: "accept") }
                                            }

                                            Button("Allow Session") {
                                                Task { await store.decideApproval(approval, decision: "acceptForSession") }
                                            }
                                        } else {
                                            Button("Approve") {
                                                Task { await store.decideApproval(approval, decision: "accept") }
                                            }
                                        }

                                        Button(approval.kind == "permissions" ? "Deny" : "Decline") {
                                            Task { await store.decideApproval(approval, decision: "decline") }
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.orange.opacity(0.12))
                                )
                            }
                        }
                    }

                    TextField("Quick Command", text: $store.draft)
                        .textFieldStyle(.roundedBorder)

                    Button("Send Command") {
                        Task { await store.sendDraft() }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    if !store.selectedEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Recent Activity")
                                .font(.caption.weight(.semibold))

                            ForEach(store.selectedEvents.prefix(3)) { event in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title)
                                        .font(.caption.weight(.medium))
                                    if let detail = event.detail {
                                        Text(detail)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }

                    if let detail = store.selectedThreadDetail {
                        let operationalItems = detail.turns
                            .flatMap(\.items)
                            .filter { $0.type == "commandExecution" || $0.type == "fileChange" }
                            .prefix(3)

                        if !operationalItems.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Operational Snapshot")
                                    .font(.caption.weight(.semibold))

                                ForEach(Array(operationalItems)) { item in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.type == "commandExecution" ? "Command: \(item.title)" : "Changes: \(item.title)")
                                            .font(.caption.weight(.medium))
                                        if let detail = item.detail {
                                            Text(detail)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            store.commandPanelOpener = openCommandPanel
        }
    }

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to helm")
                        .font(.subheadline.weight(.semibold))
                    Text("This Mac app stays attached to the same live Codex thread state as the CLI and your other helm clients. Open Command here when you want desktop presence without breaking continuity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    store.dismissOnboarding()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
            }

            ForEach(Array(store.onboardingHighlights.enumerated()), id: \.offset) { index, item in
                Text("\(index + 1). \(item)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Read Pairing") {
                    Task { await store.refreshPairingStatus() }
                }
                .buttonStyle(.bordered)

                Button("Settings") {
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
