#if PP_DIRECT
import Foundation
import PasswordPieAgent
import PasswordPieCore

/// Reads a folder of dotenv files for `passwordpie check-import` with the importer's own reader, so a check sees a
/// folder exactly as an import does: the same files become the same items, fields and key files (docs/AGENTS.md,
/// "Checking a folder against the vault"). The folder is only read, and what it held stays in PasswordPie.
struct DotenvFolderCheck: AgentFolderReader {
    func subjects(folder: String, inside: [String]) throws -> [AgentCheckSubject] {
        let plan: DotenvPlan
        do {
            // Only the dotenv and key files are read: which other files hold a value is the import's question.
            plan = try DotenvFolder.read(URL(fileURLWithPath: folder), findingCopies: false)
        } catch let problem as DotenvFolderError {
            throw AgentFolderProblem(Self.said(problem, folder: folder))
        }
        return DotenvImport.subjects(of: plan, inside: DotenvImport.parentPath(inside.joined(separator: "/"))).map { subject in
            AgentCheckSubject(
                file: subject.file, name: subject.name, folder: subject.folder, title: subject.title,
                field: subject.key.map { .custom($0) } ?? .attachment(subject.name), expected: subject.expected
            )
        }
    }

    /// The reader's words are for someone choosing a folder in Preferences. An agent named a path.
    private static func said(_ problem: DotenvFolderError, folder: String) -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "\(folder) is not a folder."
        }
        return problem.description
    }
}
#endif
