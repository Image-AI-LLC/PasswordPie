import Foundation
import PasswordPieAgent

/// The `.env.pp` files for a project: one line per variable the project reads that an item shared with agents holds,
/// as a reference, never a value. One file per identity when the project works with two accounts. See docs/AGENTS.md,
/// "Writing a project's .env.pp".
struct EnvFilePlan: Equatable {
    struct Line: Equatable {
        var name: String
        /// `pp://…`, or `file:pp://…` for a key file handed over as a file.
        var value: String
    }

    struct File: Equatable {
        /// `.env.pp`, or `.env.work.pp`.
        var name: String
        /// The items it draws on are named this (`work`). Nil when every name has only one item to come from.
        var identity: String?
        var lines: [Line]

        var text: String {
            let use = "passwordpie run --env-file \(name) -- <command>"
            var text = "# References to secrets in PasswordPie, not the values: safe to commit.\n# Use: \(use)\n"
            for line in lines { text += "\(line.name)=\(line.value)\n" }
            return text
        }
    }

    var files: [File] = []
    /// Set in the project's dotenv file and read by its code, but no item shared with agents has a field of that name.
    var notShared: [String] = []
    /// Set in the project's dotenv file and held by a shared item, but not found in the code. A library may read it.
    var notRead: [String] = []
    /// A name that more than one shared item holds, with nothing to choose by: left out, with the items' references.
    var ambiguous: [String: [String]] = [:]

    /// The field of `item` that holds the variable `name`: its own name, or "NAME (variable)" where the import kept it
    /// apart from the item's own field (docs/UX.md, "A folder of .env files becomes items").
    static func field(for name: String, in item: AgentListedItem) -> String? {
        if item.fields.contains(name) { return name }
        let apart = name + " (variable)"
        return item.fields.contains(apart) ? apart : nil
    }

    /// - identities: the item names to write for (`--identity`). Empty: worked out from the project's dotenv files, or
    ///   from the shared items when more than one could give a name.
    /// - also: names to take although the code does not spell them out (`--also`): a library reads them.
    static func make(scan: RepositoryScan, items: [AgentListedItem], identities: [String] = [], also: [String] = []) -> EnvFilePlan {
        var plan = EnvFilePlan()
        let read = Set(scan.names.keys).union(also)
        let inDotenv = scan.dotenvs.flatMap(\.names)
        func holders(_ name: String) -> [AgentListedItem] { items.filter { field(for: name, in: $0) != nil } }
        /// The item a path in a dotenv file stands for: the one with an attachment of that file's name, in the folder
        /// named like the file's own folder when several have it.
        func keyFile(_ name: String, identity: String?) -> (item: AgentListedItem, attachment: String)? {
            for dotenv in scan.dotenvs {
                guard let path = dotenv.paths[name] else { continue }
                let file = (path as NSString).lastPathComponent
                let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                var found = items.filter { $0.attachments.contains(file) }
                if found.count > 1 { found = found.filter { ($0.folder as NSString).lastPathComponent == folder } }
                if found.count > 1, let identity { found = found.filter { $0.title == identity } }
                if found.count == 1 { return (found[0], file) }
            }
            return nil
        }

        // The names to write: what the code reads and something shared can give. In the dotenv file's order, then by name.
        let gettable = read.filter { name in
            !holders(name).isEmpty || keyFile(name, identity: nil) != nil || identities.contains { keyFile(name, identity: $0) != nil }
        }
        var wanted: [String] = []
        for name in inDotenv where gettable.contains(name) && !wanted.contains(name) { wanted.append(name) }
        wanted += gettable.subtracting(wanted).sorted()

        plan.notShared = Array(Set(inDotenv).intersection(read).subtracting(gettable)).sorted()
        plan.notRead = Array(Set(inDotenv).subtracting(read).filter { !holders($0).isEmpty }).sorted()

        // Whose files: asked for, else the project's dotenv files say, else the items do.
        let titles = Set(wanted.flatMap { holders($0).map(\.title) })
        var targets: [(file: String, identity: String?)] = []
        if !identities.isEmpty {
            targets = identities.map { (identities.count == 1 ? ".env.pp" : ".env.\($0).pp", $0) }
        } else {
            for dotenv in scan.dotenvs {
                guard let identity = dotenv.identity, titles.contains(identity), !targets.contains(where: { $0.identity == identity }) else { continue }
                targets.append((dotenv.name + ".pp", identity))
            }
            if targets.isEmpty {
                // Only a name that two differently named items hold needs a choice. One file each for those names.
                let contested = Set(wanted.flatMap { name -> [String] in
                    let found = Set(holders(name).map(\.title))
                    return found.count > 1 ? Array(found) : []
                })
                targets = contested.isEmpty ? [(".env.pp", nil)] : contested.sorted().map { (".env.\($0).pp", $0) }
            }
        }

        let resolvable = items.compactMap(agentItem)
        for target in targets {
            var lines: [Line] = []
            for name in wanted {
                let all = holders(name)
                let own = target.identity.map { identity in all.filter { $0.title == identity } } ?? []
                let chosen = own.isEmpty ? all : own
                if chosen.count == 1, let key = field(for: name, in: chosen[0]) {
                    lines.append(Line(name: name, value: reference(to: chosen[0], suffix: [key], field: .custom(key), among: resolvable)))
                } else if chosen.count > 1 {
                    plan.ambiguous[name] = chosen.map(\.ref)
                } else if let key = keyFile(name, identity: target.identity) {
                    lines.append(Line(name: name, value: "file:" + reference(to: key.item, suffix: ["attachment", key.attachment], field: .attachment(key.attachment), among: resolvable)))
                }
            }
            if !lines.isEmpty { plan.files.append(File(name: target.file, identity: target.identity, lines: lines)) }
        }
        return plan
    }

    /// The reference that reads best and still means one thing: by path, or by the item's id when the path could be read
    /// another way among the shared items.
    private static func reference(to item: AgentListedItem, suffix: [String], field: AgentField, among items: [AgentItem]) -> String {
        let byPath = item.ref + "/" + suffix.map(AgentReference.encode).joined(separator: "/")
        if let parsed = try? AgentReference(byPath), let own = agentItem(item),
           case .found(let found, let foundField) = AgentResolver.resolve(parsed, in: items), found.id == own.id, foundField == field {
            return byPath
        }
        return item.idRef + "/" + suffix.map(AgentReference.encode).joined(separator: "/")
    }

    /// A listed item as the resolver takes it: its folder and title read back from its own reference.
    private static func agentItem(_ item: AgentListedItem) -> AgentItem? {
        guard let reference = try? AgentReference(item.ref), case .path(let readings) = reference.target, let whole = readings.first,
              let idReference = try? AgentReference(item.idRef), case .id(let id, _) = idReference.target else { return nil }
        return AgentItem(id: id, database: "", folder: whole.folder, title: whole.title, fields: item.fields, attachments: item.attachments)
    }
}
