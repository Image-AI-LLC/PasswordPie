import Foundation
import XCTest
@testable import PasswordPieAgent
@testable import PasswordPieCLI

/// `passwordpie write-env`: which variables a project reads, and the `.env.pp` that names only those (docs/AGENTS.md,
/// "Writing a project's .env.pp").
final class WriteEnvTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("write-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func write(_ path: String, _ text: String, in root: URL? = nil) throws {
        let url = (root ?? folder).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func item(_ folder: String, _ title: String, fields: [String], attachments: [String] = []) -> AgentListedItem {
        AgentItem(id: UUID(), database: "", folder: folder.split(separator: "/").map(String.init), title: title, fields: fields, attachments: attachments)
            .listed(covered: false)
    }

    // MARK: Names in code

    func testNamesInJavaScriptPythonAndOtherLanguages() {
        func names(_ text: String, _ file: String = "a.ts") -> [String] { RepositoryScan.names(in: text, fileName: file).sorted() }
        XCTAssertEqual(names(#"const a = process.env.STRIPE_KEY; b(process.env["HOOK"], process.env['X_1'], import.meta.env.VITE_URL)"#), ["HOOK", "STRIPE_KEY", "VITE_URL", "X_1"])
        XCTAssertEqual(names("const { A, B: renamed, C = 'x' } = process.env\nlet {D}=process.env;"), ["A", "B", "C", "D"])
        XCTAssertEqual(names(#"os.environ["A"]; os.environ.get('B', "d"); os.getenv("C"); environ["D"]; getenv('E')"#, "a.py"), ["A", "B", "C", "D", "E"])
        XCTAssertEqual(names(#"os.Getenv("A"); os.LookupEnv("B")"#, "main.go"), ["A", "B"])
        XCTAssertEqual(names(#"ENV["A"]; ENV.fetch('B'); $_ENV["C"]"#, "a.rb"), ["A", "B", "C"])
        XCTAssertEqual(names(#"env::var("A"); std::env::var_os("B"); env!("C")"#, "main.rs"), ["A", "B", "C"])
        XCTAssertEqual(names(#"ProcessInfo.processInfo.environment["A"]; Deno.env.get("B"); Bun.env.C"#, "a.swift"), ["A", "B", "C"])
        XCTAssertEqual(names("const s = `${notAVariable} and $ALSO_NOT`"), [], "a string template in code is not the environment")
        XCTAssertEqual(names("processEnv.X; environment.Y"), [])
    }

    func testDollarNamesCountWhereAShellExpandsThem() {
        func names(_ text: String, _ file: String) -> [String] { RepositoryScan.names(in: text, fileName: file).sorted() }
        XCTAssertEqual(names("curl -H \"Authorization: Bearer $TOKEN\" \"${BASE_URL:-x}/v1\"\n", "deploy.sh"), ["BASE_URL", "TOKEN"])
        XCTAssertEqual(names("#!/usr/bin/env bash\necho $A\n", "deploy"), ["A"])
        XCTAssertEqual(names("#!/bin/sh\necho $A\n", "run"), ["A"])
        XCTAssertEqual(names("#!/usr/bin/env python3\nprint('$A')\n", "tool"), [])
        XCTAssertEqual(names("deploy:\n\twrangler deploy --token $(CF_TOKEN) $$OTHER\n", "Makefile"), ["OTHER"])
        XCTAssertEqual(names("environment:\n  - KEY=${API_KEY}\n", "docker-compose.yml"), ["API_KEY"])
        XCTAssertEqual(names(#"{"scripts": {"deploy": "wrangler deploy --token $CF_TOKEN"}}"#, "package.json"), ["CF_TOKEN"])
        XCTAssertEqual(names("echo $A", "notes.md"), [])
    }

    func testLoadersOfAWholeDotenvFile() {
        XCTAssertEqual(RepositoryScan.loader(in: "from dotenv import load_dotenv\nload_dotenv()\n"), "load_dotenv()")
        XCTAssertEqual(RepositoryScan.loader(in: "require('dotenv').config()\nimport dotenv from 'dotenv'; dotenv.config()"), "dotenv.config()")
        XCTAssertEqual(RepositoryScan.loader(in: "import 'dotenv/config'"), "dotenv/config")
        XCTAssertEqual(RepositoryScan.loader(in: "set -a\nsource .env\n"), "source .env")
        XCTAssertEqual(RepositoryScan.loader(in: "  . ./config/.env\n"), "source .env")
        XCTAssertEqual(RepositoryScan.loader(in: "node --env-file=.env app.js"), "--env-file .env")
        XCTAssertNil(RepositoryScan.loader(in: "passwordpie run --env-file .env.pp -- x"))
        XCTAssertNil(RepositoryScan.loader(in: "print('hello')"))
    }

    // MARK: A project

    /// A project that reads three variables in code and one in a script, with a `.env` that links to a flat file of
    /// twenty names kept elsewhere, as a folder of dotenv files joined into one.
    private func makeProject() throws -> (project: URL, store: URL) {
        let project = folder.appendingPathComponent("shop", isDirectory: true)
        let store = folder.appendingPathComponent("configs", isDirectory: true)
        try write("src/pay.ts", "export const key = process.env.STRIPE_SECRET_KEY\nconst hook = process.env['STRIPE_WEBHOOK_SECRET']\n", in: project)
        try write("tools/report.py", "import os\nfrom dotenv import load_dotenv\nload_dotenv()\nproject = os.environ['GOOGLE_PROJECT']\ncreds = os.getenv('GOOGLE_APPLICATION_CREDENTIALS')\nhome = os.environ['HOME']\n", in: project)
        try write("Scripts/deploy.sh", "#!/bin/sh\nwrangler deploy --token \"$CLOUDFLARE_API_TOKEN\" --dir \"$CONFIGS_DIR\"\n", in: project)
        try write("node_modules/lib/index.js", "process.env.NOT_OURS; process.env.RESEND_API_KEY", in: project)
        try write(".git/config", "process.env.IN_GIT", in: project)
        try write("README.md", "Set `STRIPE_SECRET_KEY` and run.\n", in: project)
        try write(".env.example", "STRIPE_SECRET_KEY=\nEXAMPLE_ONLY=\n", in: project)
        var flat = "# generated\n"
        for name in ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET", "GOOGLE_PROJECT", "CLOUDFLARE_API_TOKEN", "RESEND_API_KEY", "OPENAI_API_KEY"] {
            flat += "\(name)=PLANTED-\(name.lowercased())\n"
        }
        for index in 0..<14 { flat += "export UNUSED_\(index)=\"PLANTED-unused-\(index)\"\n" }
        flat += "CONFIGS_DIR=\(store.path)\nGOOGLE_APPLICATION_CREDENTIALS=\(store.path)/google/work-service-account.json\n"
        try write("generated/work.env", flat, in: store)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent(".env"), withDestinationURL: store.appendingPathComponent("generated/work.env"))
        return (project, store)
    }

    /// What an import of that folder of dotenv files left shared with agents: two services, two identities.
    private func sharedItems() -> [AgentListedItem] {
        [
            item("stripe", "work", fields: ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET", "STRIPE_ACCOUNT"]),
            item("stripe", "personal", fields: ["STRIPE_SECRET_KEY"]),
            item("google", "work", fields: ["GOOGLE_PROJECT", "GOOGLE_API_KEY"], attachments: ["work-service-account.json"]),
            item("google", "personal", fields: ["GOOGLE_PROJECT"], attachments: ["personal.pem"]),
            item("cloudflare", "work", fields: ["CLOUDFLARE_API_TOKEN"]),
            item("resend", "work", fields: ["RESEND_API_KEY"]),
            item("openai", "work", fields: ["OPENAI_API_KEY", "UNUSED_3"]),
        ]
    }

    func testTheScanFindsWhatTheProjectReadsAndItsDotenvFile() throws {
        let (project, store) = try makeProject()
        let scan = try RepositoryScan.scan(project)
        XCTAssertEqual(scan.names.keys.sorted(), ["CLOUDFLARE_API_TOKEN", "CONFIGS_DIR", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_PROJECT", "HOME", "STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"])
        XCTAssertEqual(scan.names["STRIPE_SECRET_KEY"], "src/pay.ts")
        XCTAssertEqual(scan.loaders, ["load_dotenv() in tools/report.py"])
        XCTAssertEqual(scan.dotenvs.count, 1, "the template is not the project's dotenv file")
        let dotenv = try XCTUnwrap(scan.dotenvs.first)
        XCTAssertEqual(dotenv.name, ".env")
        XCTAssertEqual(dotenv.identity, "work", "from the file the link points at")
        XCTAssertEqual(dotenv.names.count, 22)
        XCTAssertEqual(dotenv.paths, ["CONFIGS_DIR": store.path, "GOOGLE_APPLICATION_CREDENTIALS": store.path + "/google/work-service-account.json"])
        XCTAssertFalse(String(describing: scan).contains("PLANTED"), "names and paths, never a value")
    }

    /// The acceptance: the `.env.pp` for the project names only what it reads, not all twenty-two.
    func testTheEnvFileNamesOnlyWhatTheProjectReads() throws {
        let (project, _) = try makeProject()
        let scan = try RepositoryScan.scan(project)
        let plan = EnvFilePlan.make(scan: scan, items: sharedItems())
        XCTAssertEqual(plan.files.map(\.name), [".env.pp"])
        XCTAssertEqual(plan.files[0].identity, "work")
        XCTAssertEqual(plan.files[0].lines, [
            EnvFilePlan.Line(name: "STRIPE_SECRET_KEY", value: "pp://stripe/work/STRIPE_SECRET_KEY"),
            EnvFilePlan.Line(name: "STRIPE_WEBHOOK_SECRET", value: "pp://stripe/work/STRIPE_WEBHOOK_SECRET"),
            EnvFilePlan.Line(name: "GOOGLE_PROJECT", value: "pp://google/work/GOOGLE_PROJECT"),
            EnvFilePlan.Line(name: "CLOUDFLARE_API_TOKEN", value: "pp://cloudflare/work/CLOUDFLARE_API_TOKEN"),
            EnvFilePlan.Line(name: "GOOGLE_APPLICATION_CREDENTIALS", value: "file:pp://google/work/attachment/work-service-account.json"),
        ])
        XCTAssertEqual(plan.notShared, ["CONFIGS_DIR"], "a path of this Mac: for the second, local file")
        XCTAssertEqual(plan.notRead, ["OPENAI_API_KEY", "RESEND_API_KEY", "UNUSED_3"])
        XCTAssertEqual(plan.ambiguous, [:])
        let text = plan.files[0].text
        XCTAssertTrue(text.hasPrefix("# References to secrets in PasswordPie, not the values: safe to commit.\n# Use: passwordpie run --env-file .env.pp -- <command>\nSTRIPE_SECRET_KEY=pp://stripe/work/STRIPE_SECRET_KEY\n"))
        XCTAssertFalse(text.contains("PLANTED"))
        // What it wrote is a file `run --env-file` takes.
        let lines = try AgentEnvFile.parse(text)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.last, .secret(name: "GOOGLE_APPLICATION_CREDENTIALS", ref: "pp://google/work/attachment/work-service-account.json", delivery: .file))

        // A name a library reads is added by hand.
        let also = EnvFilePlan.make(scan: scan, items: sharedItems(), also: ["OPENAI_API_KEY"])
        XCTAssertEqual(also.files[0].lines.map(\.name), ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET", "GOOGLE_PROJECT", "CLOUDFLARE_API_TOKEN", "OPENAI_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS"])
        XCTAssertEqual(also.notRead, ["RESEND_API_KEY", "UNUSED_3"])
    }

    func testOneFilePerIdentityWhenAProjectUsesTwo() throws {
        let (project, _) = try makeProject()
        let scan = try RepositoryScan.scan(project)
        let plan = EnvFilePlan.make(scan: scan, items: sharedItems(), identities: ["work", "personal"])
        XCTAssertEqual(plan.files.map(\.name), [".env.work.pp", ".env.personal.pp"])
        let personal = plan.files[1]
        XCTAssertEqual(personal.lines.first, EnvFilePlan.Line(name: "STRIPE_SECRET_KEY", value: "pp://stripe/personal/STRIPE_SECRET_KEY"))
        XCTAssertEqual(personal.lines.first { $0.name == "GOOGLE_PROJECT" }?.value, "pp://google/personal/GOOGLE_PROJECT")
        XCTAssertEqual(personal.lines.first { $0.name == "CLOUDFLARE_API_TOKEN" }?.value, "pp://cloudflare/work/CLOUDFLARE_API_TOKEN", "a service with one account serves both")
        XCTAssertEqual(personal.lines.first { $0.name == "STRIPE_WEBHOOK_SECRET" }?.value, "pp://stripe/work/STRIPE_WEBHOOK_SECRET")
        XCTAssertTrue(personal.text.contains("--env-file .env.personal.pp"))

        // With no dotenv file to say whose the project is, the items decide: a name two identities hold makes two files.
        try FileManager.default.removeItem(at: project.appendingPathComponent(".env"))
        let bare = EnvFilePlan.make(scan: try RepositoryScan.scan(project), items: sharedItems())
        XCTAssertEqual(bare.files.map(\.name), [".env.personal.pp", ".env.work.pp"])
        // And when no name is held twice, there is one file and nothing to choose.
        let single = EnvFilePlan.make(scan: try RepositoryScan.scan(project), items: sharedItems().filter { $0.title == "work" })
        XCTAssertEqual(single.files.map(\.name), [".env.pp"])
        XCTAssertNil(single.files[0].identity)
        XCTAssertEqual(single.files[0].lines.map(\.name), ["CLOUDFLARE_API_TOKEN", "GOOGLE_PROJECT", "STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"])
    }

    func testANameTwoItemsOfOneIdentityHoldIsLeftOutAndSaid() {
        var scan = RepositoryScan()
        scan.names = ["TOKEN": "a.sh", "KEY": "a.sh"]
        let items = [item("a", "work", fields: ["TOKEN", "KEY"]), item("b", "work", fields: ["TOKEN"])]
        let plan = EnvFilePlan.make(scan: scan, items: items)
        XCTAssertEqual(plan.files.map { $0.lines.map(\.name) }, [["KEY"]])
        XCTAssertEqual(plan.ambiguous, ["TOKEN": ["pp://a/work", "pp://b/work"]])
        XCTAssertEqual(WriteEnv.notes(plan, scan: scan), [
            "PasswordPie: TOKEN is in more than one shared item (pp://a/work, pp://b/work), so it was left out. Say whose with --identity NAME."
        ])
    }

    func testAVariableKeptApartAndAPathThatCouldBeReadTwoWays() {
        var scan = RepositoryScan()
        scan.names = ["PASSWORD": "a.py", "API_KEY": "a.py"]
        // The folder a/b with the item API_KEY makes pp://a/b/API_KEY mean two things: the id says which.
        let field = item("a", "b", fields: ["API_KEY", "PASSWORD (variable)"])
        let twin = item("a/b", "API_KEY", fields: [])
        let plan = EnvFilePlan.make(scan: scan, items: [field, twin])
        XCTAssertEqual(plan.files[0].lines, [
            EnvFilePlan.Line(name: "API_KEY", value: field.idRef + "/API_KEY"),
            EnvFilePlan.Line(name: "PASSWORD", value: "pp://a/b/PASSWORD (variable)"),
        ])
        for line in plan.files[0].lines { XCTAssertNoThrow(try AgentReference(line.value)) }
    }

    func testNotesNameWhatWasLeftOutAndWhy() throws {
        let (project, _) = try makeProject()
        let scan = try RepositoryScan.scan(project)
        let notes = WriteEnv.notes(EnvFilePlan.make(scan: scan, items: sharedItems()), scan: scan)
        XCTAssertEqual(notes, [
            "PasswordPie: read by the code and set in .env, but in no item shared with agents: CONFIGS_DIR. If one is not a secret (a path, a region), set it in a second file kept on this Mac: --env-file .env.pp --env-file .env.local.",
            "PasswordPie: set in .env but not found in the code, so left out: OPENAI_API_KEY, RESEND_API_KEY, UNUSED_3. The project loads the file as a whole (load_dotenv() in tools/report.py), so a library may read one without the code naming it. Add one with --also NAME.",
        ])
    }

    func testArguments() throws {
        XCTAssertEqual(try Arguments.parse(["write-env"]), .writeEnv(WriteEnvOptions()))
        XCTAssertEqual(
            try Arguments.parse(["write-env", "proj", "--identity", "work", "--identity=personal", "--also", "OPENAI_API_KEY", "--write", "--force", "--wait", "5"]),
            .writeEnv(WriteEnvOptions(folder: "proj", identities: ["work", "personal"], also: ["OPENAI_API_KEY"], write: true, force: true, wait: 5))
        )
        XCTAssertThrowsError(try Arguments.parse(["write-env", "--force"]), "--force without --write")
        XCTAssertThrowsError(try Arguments.parse(["write-env", "--also", "not a name"]))
        XCTAssertThrowsError(try Arguments.parse(["write-env", "a", "b"]))
        XCTAssertThrowsError(try Arguments.parse(["write-env", "--frob"]))
        XCTAssertTrue(Arguments.usageText.contains("passwordpie write-env [FOLDER] [--identity NAME]... [--also NAME]... [--write [--force]] [--wait SECONDS]"))
    }
}
