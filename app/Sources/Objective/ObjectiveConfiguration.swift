import Foundation

struct ObjectiveConfigurationPaths {
    let claudeConfiguration: URL
    let claudeInstructions: URL
    let claudeSettings: URL
    let codexConfiguration: URL
    let codexInstructions: URL
    let backup: URL

    static func live(fileManager: FileManager = .default) -> Self {
        let home = fileManager.homeDirectoryForCurrentUser
        return Self(
            claudeConfiguration: home.appendingPathComponent(".claude.json"),
            claudeInstructions: home.appendingPathComponent(".claude/CLAUDE.md"),
            claudeSettings: home.appendingPathComponent(".claude/settings.json"),
            codexConfiguration: home.appendingPathComponent(".codex/config.toml"),
            codexInstructions: home.appendingPathComponent(".codex/AGENTS.md"),
            backup: StatePaths.directory.appendingPathComponent("configuration-backup.json")
        )
    }
}

private struct ObjectiveConfigurationBackup: Codable {
    var server: Data?
    var instructions: String?
    var promptHookGroups: [Data] = []
    var codexServer: String?
}

enum ObjectiveConfigurationError: LocalizedError {
    case noServerConfiguration
    case invalidJSON(URL)

    var errorDescription: String? {
        switch self {
        case .noServerConfiguration:
            return "Objective cannot find a saved MCP server configuration to restore."
        case .invalidJSON(let url):
            return "Objective could not read \(url.path) because it does not contain valid JSON."
        }
    }
}

/// Owns the files that make Objective available to Claude Code and Codex. The
/// app keeps an exact copy of every removed value, so turning Objective back on
/// does not guess at command paths or overwrite unrelated settings.
final class ObjectiveConfiguration {
    private static let instructionHeading = "# Objective overlay board"
    private static let codexTable = "mcp_servers.objective"
    // Older saved instructions predate the presence rules. They get the rules
    // added, and keep everything else as the user left it.
    private static let presenceMarker = "at_mac"
    private static let presenceInstructions = """
    - **When a step needs me at the Mac** (Touch ID, a sudo or password prompt, a system dialog, a cable), call `objective_add` with `at_mac: true` and a short `text` such as "Touch ID for brew upgrade" BEFORE you start that step. Never start a prompt that I may not be there to see.
    - It returns `present` when I am at the Mac: start the step at once. While I am away it waits, and I get the ask on Telegram. Do all your other work first, so only that step waits.
    - `skipped` or `timeout` means do not start the step. Report it as not done.
    - `objective_presence` says whether I am at the Mac now (`present`, `unsure`, `away`). Use it to plan the order of your work. Never ask me in chat whether I am here.
    """
    private static let defaultInstructions = """
    # Objective overlay board

    - An app named "Objective" runs on this Mac. It is a small always-on-top overlay list.
    - When you need my input, my decision, or an action only I can do, add an item with the `objective` MCP tools (`objective_add` with a short `text` and optional `detail`).
    - For a decision, pass `choices` (2-4 short options); I click one and you get it as the answer. For a free-text answer, pass `allow_reply: true`; I type into the item. Prefer these over plain items whenever you need an actual answer, not just an action.
    - `objective_add` BLOCKS by default and returns my answer as its result, so you get my click at once. Do not continue with a guess, and never ask me to tell you when I have answered. Pass `wait: false` only for a note that does not block you; then use `objective_wait` later if you do need the answer.
    - Pass `source` with the project/repo name so I can see who is asking. Set `urgent: true` only when I'm truly blocking you.
    - Read the board with `objective_list`. Resolve items you added with `objective_complete`, or remove stale ones with `objective_remove`.
    - If I answer in chat instead of on the board, close the item yourself at once: `objective_complete` with the item id and my answer. Never ask me to click something I already answered. A hook lists the open items on every message, so you always know what is open.
    - Keep item texts short and actionable, like game objectives (e.g. "Approve the DB migration", "Plug in the test phone").
    - **The board is only for a BLOCKED agent.** Add an item when you cannot continue without me. Do not post status, progress, or "review my output" notices: the terminal already shows me those.
    - **Only two kinds of ask belong on the board.** A permission ("push this public?", "send this?", "delete this?"), or a fact only I hold ("which name?", "is it paid?"). Both fit in one line.
    - **A judgement call never goes on the board.** Architecture, tradeoffs, and taste need your reasoning and the code. Ask those in the session, in chat.
    - Never end a turn with an open question that lives only in the chat. If you are blocked, it belongs on the board, and it waits with no deadline.
    \(presenceInstructions)
    """

    private let paths: ObjectiveConfigurationPaths
    private let fileManager: FileManager

    init(paths: ObjectiveConfigurationPaths = .live(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    var isEnabled: Bool {
        hasServer() && instructionSection(in: readText(paths.claudeInstructions) ?? "") != nil
    }

    /// Save the working setup before the user ever turns it off. This also
    /// upgrades backups if another tool changes the MCP command or hook later.
    func captureCurrentConfiguration() throws {
        var backup = readBackup()

        if let server = try objectiveServer() {
            backup.server = try JSONSerialization.data(withJSONObject: server, options: [.sortedKeys])
        }
        if let section = instructionSection(in: readText(paths.claudeInstructions) ?? "") {
            backup.instructions = section.text
        }
        let hookGroups = try objectivePromptHookGroups()
        if !hookGroups.isEmpty {
            backup.promptHookGroups = try hookGroups.map {
                try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
            }
        }
        if let codexServer = splitCodexServer(from: readText(paths.codexConfiguration) ?? "").server {
            backup.codexServer = codexServer
        }

        if backup.server != nil || backup.instructions != nil || !backup.promptHookGroups.isEmpty || backup.codexServer != nil {
            try writeBackup(backup)
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try captureCurrentConfiguration()
            try disable()
        }
    }

    private func enable() throws {
        let backup = readBackup()
        guard let serverData = backup.server,
              let server = try JSONSerialization.jsonObject(with: serverData) as? [String: Any]
        else { throw ObjectiveConfigurationError.noServerConfiguration }

        var claude = try readJSONObject(paths.claudeConfiguration, missing: [:])
        var servers = claude["mcpServers"] as? [String: Any] ?? [:]
        servers["objective"] = server
        claude["mcpServers"] = servers

        let section = withPresenceRules(backup.instructions ?? Self.defaultInstructions)
        var instructions = readText(paths.claudeInstructions) ?? ""
        if instructionSection(in: instructions) == nil {
            instructions = appendingSection(section, to: instructions)
        }

        var changes: [(URL, Data)] = [
            (paths.claudeConfiguration, try jsonData(claude)),
            (paths.claudeInstructions, Data(instructions.utf8)),
        ]

        var settings = try readJSONObject(paths.claudeSettings, missing: [:])
        if !containsPromptHook(in: settings), !backup.promptHookGroups.isEmpty {
            let restoredGroups = try backup.promptHookGroups.compactMap {
                try JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            if !restoredGroups.isEmpty {
                var hooks = settings["hooks"] as? [String: Any] ?? [:]
                var submit = hooks["UserPromptSubmit"] as? [[String: Any]] ?? []
                submit.append(contentsOf: restoredGroups)
                hooks["UserPromptSubmit"] = submit
                settings["hooks"] = hooks
            }
            changes.append((paths.claudeSettings, try jsonData(settings)))
        }

        if hasCodex {
            let codexText = readText(paths.codexConfiguration) ?? ""
            if splitCodexServer(from: codexText).server == nil {
                let block = backup.codexServer ?? codexServerBlock(for: server)
                changes.append((paths.codexConfiguration, Data(appendingSection(block, to: codexText).utf8)))
            }
            let codexInstructions = readText(paths.codexInstructions) ?? ""
            if instructionSection(in: codexInstructions) == nil {
                changes.append((paths.codexInstructions, Data(appendingSection(section, to: codexInstructions).utf8)))
            }
        }

        try writeChanges(changes)
    }

    private func disable() throws {
        var claude = try readJSONObject(paths.claudeConfiguration, missing: [:])
        var servers = claude["mcpServers"] as? [String: Any] ?? [:]
        servers.removeValue(forKey: "objective")
        claude["mcpServers"] = servers

        let originalInstructions = readText(paths.claudeInstructions) ?? ""
        let instructions = removingInstructionSection(from: originalInstructions)

        var changes: [(URL, Data)] = [
            (paths.claudeConfiguration, try jsonData(claude)),
            (paths.claudeInstructions, Data(instructions.utf8)),
        ]
        if fileManager.fileExists(atPath: paths.claudeSettings.path) {
            var settings = try readJSONObject(paths.claudeSettings, missing: [:])
            if containsPromptHook(in: settings) {
                settings = removingPromptHooks(from: settings)
                changes.append((paths.claudeSettings, try jsonData(settings)))
            }
        }

        if let codexText = readText(paths.codexConfiguration) {
            let split = splitCodexServer(from: codexText)
            if split.server != nil {
                let rest = split.rest.trimmingCharacters(in: .newlines)
                changes.append((paths.codexConfiguration, Data((rest.isEmpty ? "" : rest + "\n").utf8)))
            }
        }
        if let codexInstructions = readText(paths.codexInstructions), instructionSection(in: codexInstructions) != nil {
            changes.append((paths.codexInstructions, Data(removingInstructionSection(from: codexInstructions).utf8)))
        }

        try writeChanges(changes)
    }

    // MARK: - Claude configuration

    private func hasServer() -> Bool {
        (try? objectiveServer()) != nil
    }

    private func objectiveServer() throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: paths.claudeConfiguration.path) else { return nil }
        let claude = try readJSONObject(paths.claudeConfiguration, missing: [:])
        let servers = claude["mcpServers"] as? [String: Any]
        return servers?["objective"] as? [String: Any]
    }

    // MARK: - Codex configuration

    // Codex is optional. Without its folder there is nothing to set up.
    private var hasCodex: Bool {
        fileManager.fileExists(atPath: paths.codexConfiguration.deletingLastPathComponent().path)
    }

    // The same server Claude Code runs. objective_add waits for the user with
    // no deadline, so Codex must not stop the call, and must not ask before
    // each board call.
    private func codexServerBlock(for server: [String: Any]) -> String {
        let command = server["command"] as? String ?? "node"
        let args = (server["args"] as? [String] ?? []).map(Self.tomlString).joined(separator: ", ")
        var lines = [
            "[\(Self.codexTable)]",
            "command = \(Self.tomlString(command))",
            "args = [\(args)]",
            "tool_timeout_sec = 604800",
            "default_tools_approval_mode = \"approve\"",
        ]
        let env = server["env"] as? [String: String] ?? [:]
        if !env.isEmpty {
            lines.append("")
            lines.append("[\(Self.codexTable).env]")
            for key in env.keys.sorted() {
                lines.append("\(Self.tomlString(key)) = \(Self.tomlString(env[key] ?? ""))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // Separates the Objective server tables from the rest of config.toml, line
    // by line, so every other setting stays exactly as it was.
    private func splitCodexServer(from text: String) -> (rest: String, server: String?) {
        var rest: [Substring] = []
        var server: [Substring] = []
        var inServer = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let name = tableName(of: line) {
                inServer = name == Self.codexTable || name.hasPrefix(Self.codexTable + ".")
            }
            if inServer {
                server.append(line)
            } else {
                rest.append(line)
            }
        }
        let block = server.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (rest.joined(separator: "\n"), block.isEmpty ? nil : block)
    }

    // The name of a table header such as [mcp_servers.objective], or nil for
    // any other line. A comma means an array value, not a header.
    private func tableName(of line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.lastIndex(of: "]") else { return nil }
        let after = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard after.isEmpty || after.hasPrefix("#") else { return nil }
        let name = trimmed[..<close].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return name.contains(",") ? nil : name
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Instructions

    private func withPresenceRules(_ section: String) -> String {
        guard !section.contains(Self.presenceMarker) else { return section }
        return section.trimmingCharacters(in: .newlines) + "\n" + Self.presenceInstructions
    }

    private func instructionSection(in text: String) -> (range: Range<String.Index>, text: String)? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == Self.instructionHeading }) else {
            return nil
        }

        var end = start + 1
        while end < lines.count {
            let line = lines[end]
            if line.hasPrefix("# ") { break }
            end += 1
        }

        var offsets: [String.Index] = [text.startIndex]
        for index in text.indices where text[index] == "\n" {
            offsets.append(text.index(after: index))
        }
        let lower = offsets[start]
        let upper = end < offsets.count ? offsets[end] : text.endIndex

        let range = lower..<upper
        return (range, String(text[range]).trimmingCharacters(in: .newlines))
    }

    private func removingInstructionSection(from text: String) -> String {
        guard let section = instructionSection(in: text) else { return text }
        var result = text
        result.removeSubrange(section.range)
        return result
    }

    private func appendingSection(_ section: String, to text: String) -> String {
        let base = text.trimmingCharacters(in: .newlines)
        let addition = section.trimmingCharacters(in: .newlines)
        return base.isEmpty ? addition + "\n" : base + "\n\n" + addition + "\n"
    }

    // MARK: - Prompt hook

    private func containsPromptHook(in settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any]
        let groups = hooks?["UserPromptSubmit"] as? [[String: Any]] ?? []
        return groups.contains { group in
            let entries = group["hooks"] as? [[String: Any]] ?? []
            return entries.contains(where: isObjectiveHook)
        }
    }

    private func objectivePromptHookGroups() throws -> [[String: Any]] {
        guard fileManager.fileExists(atPath: paths.claudeSettings.path) else { return [] }
        let settings = try readJSONObject(paths.claudeSettings, missing: [:])
        let hooks = settings["hooks"] as? [String: Any]
        let groups = hooks?["UserPromptSubmit"] as? [[String: Any]] ?? []
        return groups.compactMap { group in
            let entries = group["hooks"] as? [[String: Any]] ?? []
            let objectiveEntries = entries.filter(isObjectiveHook)
            guard !objectiveEntries.isEmpty else { return nil }
            var copy = group
            copy["hooks"] = objectiveEntries
            return copy
        }
    }

    private func removingPromptHooks(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any],
              let groups = hooks["UserPromptSubmit"] as? [[String: Any]]
        else { return settings }

        let keptGroups: [[String: Any]] = groups.compactMap { group -> [String: Any]? in
            var group = group
            let entries = group["hooks"] as? [[String: Any]] ?? []
            let kept = entries.filter { !isObjectiveHook($0) }
            guard !kept.isEmpty else { return nil }
            group["hooks"] = kept
            return group
        }
        hooks["UserPromptSubmit"] = keptGroups
        settings["hooks"] = hooks
        return settings
    }

    private func isObjectiveHook(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.contains("objective") && command.contains("open-objectives-hook.mjs")
    }

    // MARK: - Files

    private func readBackup() -> ObjectiveConfigurationBackup {
        guard let data = try? Data(contentsOf: paths.backup),
              let backup = try? JSONDecoder().decode(ObjectiveConfigurationBackup.self, from: data)
        else { return ObjectiveConfigurationBackup() }
        return backup
    }

    private func writeBackup(_ backup: ObjectiveConfigurationBackup) throws {
        try fileManager.createDirectory(at: paths.backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(backup)
        try data.write(to: paths.backup, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.backup.path)
    }

    private func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func readJSONObject(_ url: URL, missing: [String: Any]) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return missing }
        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ObjectiveConfigurationError.invalidJSON(url)
        }
        return object
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    /// Write the related files as one operation from the user's point of view.
    /// If any write fails, put every earlier file back before reporting it.
    private func writeChanges(_ changes: [(URL, Data)]) throws {
        let originals = changes.map { url, _ in
            let permissions = (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
            return (url, try? Data(contentsOf: url), permissions)
        }

        do {
            for (index, change) in changes.enumerated() {
                let (url, data) = change
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                let permissions = originals[index].2 ?? 0o600
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
        } catch {
            for (url, original, permissions) in originals {
                if let original {
                    try? original.write(to: url, options: .atomic)
                    if let permissions {
                        try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
                    }
                } else {
                    try? fileManager.removeItem(at: url)
                }
            }
            throw error
        }
    }
}
