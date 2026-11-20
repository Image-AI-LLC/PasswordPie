#if PP_DIRECT
import AppKit
import PasswordPieAgent
import PasswordPieCore
import SwiftUI

/// Preferences > Agents: the switch, the command-line tool, what is shared, standing permissions, and Activity. See
/// "Agents use a secret without seeing it" in docs/UX.md.
struct AgentsPane: View {
    @ObservedObject var access: AgentAccess
    @ObservedObject var session: VaultSession
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            group("Agent access") { accessSection }
            group("Agents database") { databaseSection }
            group("Saves waiting for you") { savesSection }
            group("Command-line tool") { toolSection }
            group("MCP server") { mcpSection }
            group("Shared with agents") { sharingSection }
            group("Standing permissions") { standingSection }
            group("Activity") { activitySection }
        }
        .onAppear { access.refreshStanding() }
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

    // MARK: Agents database

    /// Which database serves agents, whether it is open, and "Keep unlocked while this Mac is awake". See "Two databases
    /// at once, and a Mac nobody sits at" in docs/UX.md.
    private var databaseSection: some View {
        let path = session.agentDatabasePath
        let name = URL(fileURLWithPath: path).lastPathComponent
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if session.databasePaths.count > 1 {
                    PaneMenu(title: "Agents database", value: name) {
                        Picker("Agents database", selection: Binding(get: { session.agentDatabasePath }, set: { session.chooseAgentDatabase($0) })) {
                            ForEach(Array(session.databasePaths.enumerated()), id: \.element) { index, option in
                                Text(session.databaseMenuTitles[index] + (option == session.databaseURL.path ? " (current)" : "")).tag(option)
                            }
                        }
                        .labelsHidden().pickerStyle(.inline)
                    }
                    .accessibilityIdentifier("agents.database")
                } else {
                    Text(name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                }
                Text(databaseState).font(note).foregroundStyle(.secondary)
            }
            if session.agentDatabaseNeedsUnlock {
                if let waiting = session.agentWaitingLine {
                    Text(waiting).font(note).fixedSize(horizontal: false, vertical: true)
                }
                // A new field per database: a password typed for one never goes to another.
                DatabaseUnlockField(session: session, path: path, startOpen: true).id(path)
            }
            Text("Agents ask for secrets from this database only: what is shared in it, its standing permissions, and the items references name. Other open databases are never searched.")
                .font(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Keep “\(name)” unlocked while this Mac is awake", isOn: Binding(
                get: { session.agentKeepUnlocked },
                set: { session.setKeepAgentDatabaseUnlocked($0) }
            ))
            .padding(.top, 4)
            .accessibilityIdentifier("agents.keepUnlocked")
            Text(Self.keepUnlockedNote)
                .font(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if session.agentKeepUnlocked, !session.locked, !session.keepsAgentDatabaseUnlocked {
                Text("Not in force now: it applies only while agent access is on and this database is the only one open, with no Chrome passwords shown.")
                    .font(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static let keepUnlockedNote = "On this Mac the lock no longer protects this database: what you share and the standing permissions you give are the whole protection. Being idle does not lock it; the Mac sleeping, logging out or restarting, the screen locking, switching users and Lock still do. A setting of this Mac, not of the file."

    private var databaseState: String {
        if session.locked { return "Locked" }
        if session.agentDatabaseNeedsUnlock { return "Not open" }
        return session.agentVaultLocked ? "Opening…" : "Open"
    }

    // MARK: Saves waiting

    /// The saves agents proposed that nobody answered in the window. See "Agents save a new secret" in docs/UX.md.
    @ViewBuilder
    private var savesSection: some View {
        if session.agentVaultLocked {
            Text("Unlock the agents database to see the saves that wait for you. They are kept in it.").font(note).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("An agent that makes a key can hand it to PasswordPie with passwordpie save. Each one you did not answer in its window waits here, with where it would go; you never see the value. Save asks for Touch ID.")
                    .font(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if access.waitingSaves.isEmpty {
                    Text("None.").font(note).foregroundStyle(.secondary)
                }
                ForEach(access.waitingSaves) { proposal in
                    WaitingSaveRow(
                        proposal: session.agentSavePlaced(proposal),
                        preview: session.agentSavePreview(proposal),
                        mac: access.macText(proposal),
                        problem: access.saveProblems[proposal.id],
                        save: { Task { await access.saveProposal(proposal) } },
                        reject: { Task { await access.rejectProposal(proposal) } }
                    )
                    PaneRule()
                }
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
            Text("For agents that use MCP tools: passwordpie_run, passwordpie_list, passwordpie_read, passwordpie_status, passwordpie_login and passwordpie_save. Same approvals as the command-line tool. Paste the line for your agent; PasswordPie does not change other apps' settings.")
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
            Text("Unlock the agents database to see and change what agents may ask for.").font(note).foregroundStyle(.secondary)
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

    // MARK: Standing permissions

    @ViewBuilder
    private var standingSection: some View {
        if session.agentVaultLocked {
            Text("Unlock the agents database to see standing permissions. They are kept in it.").font(note).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose Allow for 7 days ▾ in an agent's approval window to stop it asking every time, for the same items, agent, project and program (a login: the same item, site and agent, in any project). Premium.")
                    .font(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !access.enabled, !access.standing.isEmpty {
                    Text("Agent access is off: these do nothing until it is on again.").font(note).foregroundStyle(.secondary)
                }
                if !access.standing.isEmpty, !access.premiumForStanding {
                    Text("Premium has ended on this Mac: these do nothing until it is back.").font(note).foregroundStyle(.secondary)
                }
                if access.standing.isEmpty {
                    Text(access.anyGrants ? "None in force on this Mac. The database still holds some (ended, or made on another Mac)." : "None. Every use asks.")
                        .font(note).foregroundStyle(.secondary)
                }
                ForEach(access.standing) { grant in
                    StandingRow(grant: grant) { access.revoke(grant) }
                    PaneRule()
                }
                if access.anyGrants {
                    Button("Revoke All") { access.revokeAll() }
                        .accessibilityIdentifier("agents.revokeAll")
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

private struct WaitingSaveRow: View {
    let proposal: AgentProposal
    let preview: Result<AgentSaveChange, AgentSaveApply.Problem>?
    let mac: String
    let problem: String?
    let save: () -> Void
    let reject: () -> Void

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM, HH:mm")
        return formatter
    }()

    /// "a new item", "changes it: …", or why it cannot be saved now.
    private var what: (text: String, savable: Bool) {
        switch preview {
        case .success(let change)?: return (VaultBroker.changeText(change), true)
        case .failure(let problem)?: return (problem.message, false)
        case nil: return ("", false)
        }
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(proposal.agentName).font(.system(size: 12, weight: .medium))
                    Text("\(Self.time.string(from: proposal.created)), \(mac)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(proposal.title).font(.system(size: 12))
                    if !proposal.folder.isEmpty {
                        Text("(\(proposal.folder.joined(separator: "/")))").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text(proposal.fieldValue.label).font(.system(size: 12))
                }
                Text(what.text).font(.system(size: 11)).foregroundStyle(what.savable ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = proposal.reason {
                    Text("“\(reason)”").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(AgentAccess.tilde(proposal.project)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Reject", action: reject).controlSize(.small)
            Button(action: save) { Label("Save", systemImage: "touchid") }
                .controlSize(.small)
                .disabled(!what.savable)
                .help("Confirm with Touch ID or your login password")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agents.save.\(proposal.id)")
    }
}

private struct StandingRow: View {
    let grant: AgentGrant
    let revoke: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(grant.agentName).font(.system(size: 12, weight: .medium))
                    Text(AgentAccess.endText(grant)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(grant.labels.joined(separator: ", ")).font(.system(size: 12)).lineLimit(2)
                if let program = grant.program {
                    Text(program.display).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if grant.kind == .login {
                    // A login grant counts in every project: its site is what it is bound to.
                    Text("Log in on \(grant.site ?? "its site"), any project").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(AgentAccess.tilde(grant.project)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Button("Revoke", action: revoke).controlSize(.small)
        }
        .accessibilityElement(children: .contain)
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
