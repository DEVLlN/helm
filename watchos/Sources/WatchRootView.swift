import SwiftUI

struct WatchRootView: View {
    @Environment(WatchSessionStore.self) private var store
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("helm")
                            .font(.headline)
                        Text(store.connectionSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let recoverySummary = store.recoverySummary {
                            Text(recoverySummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Label(store.diagnosticsHealthStatus.title, systemImage: store.diagnosticsHealthStatus.symbolName)
                            .font(.caption2)
                            .foregroundStyle(diagnosticsTint(for: store.diagnosticsHealthStatus))
                        Text(store.diagnosticsHealthSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(store.pairingSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Alerts: \(store.notificationAuthorizationSummary)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if !store.attentionEvents.isEmpty {
                    Section("Attention") {
                        ForEach(store.attentionEvents.prefix(3)) { event in
                            Button {
                                store.selectThread(event.threadId)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.title)
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
                }

                Section("Health") {
                    ForEach(store.diagnosticsMetrics.prefix(3)) { metric in
                        HStack {
                            Label(metric.title, systemImage: metric.status.symbolName)
                            Spacer()
                            Text(metric.sampleSummary)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let attentionThread = store.highestPriorityThread {
                    Section("Now") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(attentionThread.name ?? "Selected Session")
                            if let backendLabel = attentionThread.backendLabel {
                                Text(backendLabel)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text(store.highestPrioritySummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Button("Continue on iPhone") {
                            if let url = URL(string: "helm://thread/\(attentionThread.id)") {
                                openURL(url)
                            }
                        }
                    }
                }

                Section("Sessions") {
                    ForEach(store.threads) { thread in
                        Button {
                            store.selectThread(thread.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(thread.name ?? "Untitled Session")
                                if let backendLabel = thread.backendLabel {
                                    Text(backendLabel)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                Text(store.runtimeByThreadID[thread.id]?.title ?? thread.preview)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }

                if let selectedThread = store.selectedThread {
                    Section(selectedThread.name ?? "Selected Session") {
                        if let backendLabel = selectedThread.backendLabel {
                            Text("Backend: \(backendLabel)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        TextField("Send the next Command", text: $store.commandDraft)

                        Button("Send Task") {
                            Task { await store.sendCommand() }
                        }
                        .disabled(!store.selectedThreadSupportsCommand)

                        if let summary = store.selectedThreadCommandSummary {
                            Text(summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let runtime = store.selectedRuntime {
                            LabeledContent("Phase", value: phaseLabel(runtime.phase))
                            if let detail = runtime.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(store.selectedThreadHandoffSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Button("Continue on iPhone") {
                                if let url = URL(string: "helm://thread/\(selectedThread.id)") {
                                    openURL(url)
                                }
                            }

                            if !runtime.pendingApprovals.isEmpty {
                                ForEach(runtime.pendingApprovals) { approval in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(approval.title)
                                            .font(.caption.weight(.semibold))
                                        if let detail = approval.detail {
                                            Text(detail)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }

                                        if approval.canRespond && store.selectedThreadCanRespondToApprovals {
                                            HStack {
                                                Button("Approve") {
                                                    Task { await store.decideApproval(approval, decision: "accept") }
                                                }
                                                Button("Decline") {
                                                    Task { await store.decideApproval(approval, decision: "decline") }
                                                }
                                            }
                                        } else {
                                            Text(store.selectedThreadCommandSummary ?? "Review this approval from iPhone or Mac.")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        } else {
                            Text("No runtime activity yet.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("helm")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "waitingApproval":
            return "Needs Approval"
        default:
            return phase.capitalized
        }
    }

    private func diagnosticsTint(for status: WatchResponsivenessBudgetStatus) -> Color {
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
