#if PP_DIRECT
import AppKit
import PasswordPieAgent
import PasswordPieCore
import SwiftUI

/// Preferences > Agents: the switch, the command-line tool, what is shared, and Activity. See "Agents" in docs/UX.md.
struct AgentsPane: View {
    @ObservedObject var access: AgentAccess
    @ObservedObject var session: VaultSession
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            group("Agent access") { accessSection }
            group("Command-line tool") { toolSection }
            group("MCP server") { mcpSection }
            group("Shared with agents") { sharingSection }
            group("Activity") { activitySection }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneGroupLabel(title).padding(.bottom, 6)
            PaneRule().padding(.bottom, 12)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var note: Font { .system(size: 11) }

    // MARK: Switch

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Allow agents to ask for secrets", isOn: Binding(get: { access.enabled }, set: { access.setEnabled($0) }))
                .accessibilityIdentifier("agents.enabled")
            Text("AI agents on this Mac (Claude Code, Codex, Cursor) can run a command with a secret you share with them, after you approve it with Touch ID. The value goes to the command, not into the agent's conversation.")
                .font(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem = access.problem {
                Text(problem).font(note).foregroundStyle(.red)
            }
        }
    }

    // MARK: Command-line tool

    private var toolSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tool = access.toolURL {
                Text(tool.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            }
            HStack(spacing: 10) {
                Button(access.linkIsCurrent ? "Link Again" : "Create Link in \(AgentAccess.tilde(access.linkFolder.path))") { access.createLink() }
                    .disabled(access.toolURL == nil)
                if access.linkIsCurrent {
                    Text("passwordpie is linked.").font(note).foregroundStyle(.secondary)
                }
            }
            Text("Runs: \(access.linkCommand)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let status = access.linkStatus {
                Text(status).font(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Agents use it like this: passwordpie run --env TOKEN=pp://Agents/Cloudflare -- npm run deploy")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: MCP server

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("For agents that use MCP tools: passwordpie_run, passwordpie_list, passwordpie_read, passwordpie_status and passwordpie_login. Same approvals as the command-line tool. Paste the line for your agent; PasswordPie does not change other apps' settings.")
                .font(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(access.mcpHosts) { host in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(host.name).font(.system(size: 12, weight: .medium))
                        Text(host.place).font(note).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy") { AgentsPane.copy(host.text) }
                            .controlSize(.small)
                            .accessibilityIdentifier("agents.mcp.copy.\(host.name)")
                    }
                    Text(host.text)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Sharing

    @ViewBuilder
    private var sharingSection: some View {
        if session.agentVaultLocked {
            Text("Unlock PasswordPie to see and change what agents may ask for.").font(note).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Agents see nothing until you share it, and every use still asks you. Tip: keep the keys and tokens agents need in a folder such as Agents or Developer, and share the folder.")
                    .font(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                let folders = session.agentFolders
                if folders.isEmpty {
                    Text("This database has no folders. Share items one by one from their details.").font(note).foregroundStyle(.secondary)
                } else {
                    Text("Folders").font(.system(size: 12, weight: .medium))
                    ForEach(folders, id: \.self) { folder in
                        Toggle(isOn: Binding(
                            get: { session.agentSharing.isShared(folder: folder) },
                            set: { session.setFolderSharedWithAgents(folder, $0) }
                        )) {
                            Text(folder.last ?? "")
                                .padding(.leading, CGFloat(folder.count - 1) * 14)
                        }
                        .toggleStyle(.checkbox)
                        .help(folder.joined(separator: " / "))
                    }
                }
                let items = session.agentSharedEntries
                if !items.isEmpty {
                    Text("Items shared on their own").font(.system(size: 12, weight: .medium)).padding(.top, 4)
                    ForEach(items) { entry in
                        HStack {
                            Text(entry.title)
                            if !entry.groupPath.isEmpty {
                                Text(entry.groupPath.joined(separator: " / ")).font(note).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Stop Sharing") { session.setSharedWithAgents(entry.id, false) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    // MARK: Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Filter by agent, project or item", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            let records = access.activity(matching: filter)
            if records.isEmpty {
                Text(access.activity.isEmpty ? "No agent has asked for anything yet." : "Nothing matches.")
                    .font(note).foregroundStyle(.secondary)
            } else {
                ForEach(Array(records.prefix(100).enumerated()), id: \.offset) { _, record in
                    ActivityRow(record: record)
                    PaneRule()
                }
            }
            Text("Kept for 90 days in ~/Library/Application Support/PasswordPie/agent-activity.jsonl. It never holds a value.")
                .font(note).foregroundStyle(.secondary)
        }
    }
}

private struct ActivityRow: View {
    let record: AgentActivityRecord

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(Self.time.string(from: record.time)).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(record.agent).font(.system(size: 12, weight: .medium))
                Text(record.outcomeText).font(.system(size: 11)).foregroundStyle(record.outcome == .argumentSeen ? .orange : .secondary)
                if let via = record.via {
                    Text("via \(via)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(record.kind).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !record.items.isEmpty {
                Text(record.items.joined(separator: ", ")).font(.system(size: 12)).lineLimit(2)
            }
            if let command = record.command {
                Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Text(AgentAccess.tilde(record.project)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .help(record.chain.map { "\($0.path) (\($0.signature))" }.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
    }
}
#endif
