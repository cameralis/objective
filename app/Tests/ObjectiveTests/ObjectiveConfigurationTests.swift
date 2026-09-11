import Foundation
import Testing
@testable import Objective

struct ObjectiveConfigurationTests {
    @Test func disableAndEnableRoundTripPreservesOtherSettings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try fixture.write(
            """
            {
              "mcpServers": {
                "other": { "command": "other-server" },
                "objective": {
                  "type": "stdio",
                  "command": "node",
                  "args": ["/somewhere/objective/mcp/index.js"],
                  "env": {}
                }
              },
              "untouched": true
            }
            """,
            to: fixture.paths.claudeConfiguration
        )
        try fixture.write(
            """
            # Global rules

            - Keep this.

            # Objective overlay board

            - Use `objective_add` when blocked.

            # Git commits

            - Keep this too.
            """,
            to: fixture.paths.claudeInstructions
        )
        try fixture.write(
            """
            {
              "hooks": {
                "UserPromptSubmit": [
                  {
                    "matcher": "all",
                    "hooks": [
                      { "type": "command", "command": "node /somewhere/objective/scripts/open-objectives-hook.mjs" },
                      { "type": "command", "command": "node /somewhere/other-hook.mjs" }
                    ]
                  }
                ],
                "Stop": [{ "hooks": [{ "type": "command", "command": "keep-me" }] }]
              }
            }
            """,
            to: fixture.paths.claudeSettings
        )
        try fixture.write(
            """
            model = "gpt"

            [mcp_servers.other]
            command = "other-server"

            [mcp_servers.objective]
            command = "node"
            args = ["/somewhere/objective/mcp/index.js"]
            tool_timeout_sec = 604800

            [mcp_servers.objective.env]
            KEEP = "me"

            [projects."/Users/somebody/repo"]
            trust_level = "trusted"
            """,
            to: fixture.paths.codexConfiguration
        )
        try fixture.write(
            """
            # Codex rules

            - Keep this.

            # Objective overlay board

            - Use `objective_add` when blocked.
            """,
            to: fixture.paths.codexInstructions
        )

        let configuration = ObjectiveConfiguration(paths: fixture.paths)
        #expect(configuration.isEnabled)

        try configuration.setEnabled(false)
        #expect(!configuration.isEnabled)
        let backupPermissions = try FileManager.default.attributesOfItem(atPath: fixture.paths.backup.path)[.posixPermissions] as? NSNumber
        #expect(backupPermissions?.intValue == 0o600)

        let disabledClaude = try fixture.json(fixture.paths.claudeConfiguration)
        let disabledServers = try #require(disabledClaude["mcpServers"] as? [String: Any])
        #expect(disabledServers["objective"] == nil)
        #expect(disabledServers["other"] != nil)
        #expect(disabledClaude["untouched"] as? Bool == true)

        let disabledInstructions = try String(contentsOf: fixture.paths.claudeInstructions, encoding: .utf8)
        #expect(!disabledInstructions.contains("# Objective overlay board"))
        #expect(disabledInstructions.contains("# Global rules"))
        #expect(disabledInstructions.contains("# Git commits"))
        #expect(disabledInstructions.contains("- Keep this.\n\n# Git commits"))

        let disabledSettingsText = try String(contentsOf: fixture.paths.claudeSettings, encoding: .utf8)
        #expect(!disabledSettingsText.contains("open-objectives-hook.mjs"))
        #expect(disabledSettingsText.contains("other-hook.mjs"))
        #expect(disabledSettingsText.contains("keep-me"))

        let disabledCodex = try String(contentsOf: fixture.paths.codexConfiguration, encoding: .utf8)
        #expect(!disabledCodex.contains("mcp_servers.objective"))
        #expect(disabledCodex.contains("[mcp_servers.other]"))
        #expect(disabledCodex.contains("[projects.\"/Users/somebody/repo\"]\ntrust_level = \"trusted\""))
        let disabledCodexInstructions = try String(contentsOf: fixture.paths.codexInstructions, encoding: .utf8)
        #expect(!disabledCodexInstructions.contains("# Objective overlay board"))
        #expect(disabledCodexInstructions.contains("# Codex rules"))

        let relaunchedConfiguration = ObjectiveConfiguration(paths: fixture.paths)
        try relaunchedConfiguration.setEnabled(true)
        #expect(relaunchedConfiguration.isEnabled)

        let enabledClaude = try fixture.json(fixture.paths.claudeConfiguration)
        let enabledServers = try #require(enabledClaude["mcpServers"] as? [String: Any])
        let objective = try #require(enabledServers["objective"] as? [String: Any])
        #expect(objective["command"] as? String == "node")
        #expect(enabledServers["other"] != nil)

        let enabledInstructions = try String(contentsOf: fixture.paths.claudeInstructions, encoding: .utf8)
        #expect(enabledInstructions.contains("- Use `objective_add` when blocked."))
        #expect(enabledInstructions.components(separatedBy: "# Objective overlay board").count == 2)
        #expect(enabledInstructions.contains("`at_mac: true`"))
        #expect(enabledInstructions.contains("- Keep this.\n\n# Git commits"))

        let enabledSettingsText = try String(contentsOf: fixture.paths.claudeSettings, encoding: .utf8)
        #expect(enabledSettingsText.components(separatedBy: "open-objectives-hook.mjs").count == 2)
        #expect(enabledSettingsText.contains("other-hook.mjs"))

        // The exact block the user had comes back, not a generated one.
        let enabledCodex = try String(contentsOf: fixture.paths.codexConfiguration, encoding: .utf8)
        #expect(enabledCodex.components(separatedBy: "[mcp_servers.objective]").count == 2)
        #expect(enabledCodex.contains("[mcp_servers.objective.env]\nKEEP = \"me\""))
        #expect(enabledCodex.contains("[mcp_servers.other]"))
        let enabledCodexInstructions = try String(contentsOf: fixture.paths.codexInstructions, encoding: .utf8)
        #expect(enabledCodexInstructions.components(separatedBy: "# Objective overlay board").count == 2)
        #expect(enabledCodexInstructions.contains("# Codex rules"))
    }

    @Test func enableSetsUpCodexFromTheClaudeServer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try fixture.write(
            """
            { "mcpServers": { "objective": { "command": "node", "args": ["/somewhere/objective/mcp/index.js"] } } }
            """,
            to: fixture.paths.claudeConfiguration
        )
        try fixture.write("# Objective overlay board\n\n- Use `objective_add` when blocked.\n", to: fixture.paths.claudeInstructions)
        try fixture.write("model = \"gpt\"\n", to: fixture.paths.codexConfiguration)

        let configuration = ObjectiveConfiguration(paths: fixture.paths)
        try configuration.setEnabled(false)
        try configuration.setEnabled(true)

        let codex = try String(contentsOf: fixture.paths.codexConfiguration, encoding: .utf8)
        #expect(codex.hasPrefix("model = \"gpt\"\n\n[mcp_servers.objective]\n"))
        #expect(codex.contains("command = \"node\"\nargs = [\"/somewhere/objective/mcp/index.js\"]"))
        #expect(codex.contains("tool_timeout_sec = 604800"))
        #expect(codex.contains("default_tools_approval_mode = \"approve\""))

        let codexInstructions = try String(contentsOf: fixture.paths.codexInstructions, encoding: .utf8)
        #expect(codexInstructions.hasPrefix("# Objective overlay board"))
        #expect(codexInstructions.contains("`objective_presence`"))
    }

    @Test func enableLeavesAMacWithoutCodexAlone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try fixture.write(
            """
            { "mcpServers": { "objective": { "command": "node", "args": ["/somewhere/objective/mcp/index.js"] } } }
            """,
            to: fixture.paths.claudeConfiguration
        )
        try fixture.write("# Objective overlay board\n\n- Use `objective_add` when blocked.\n", to: fixture.paths.claudeInstructions)

        let configuration = ObjectiveConfiguration(paths: fixture.paths)
        try configuration.setEnabled(false)
        try configuration.setEnabled(true)

        #expect(configuration.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.codexConfiguration.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.codexInstructions.path))
    }

    @Test func enableNeedsASavedServer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let configuration = ObjectiveConfiguration(paths: fixture.paths)
        #expect(throws: ObjectiveConfigurationError.self) {
            try configuration.setEnabled(true)
        }
    }
}

private final class Fixture {
    let root: URL
    let paths: ObjectiveConfigurationPaths

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("objective-configuration-tests-\(UUID().uuidString)", isDirectory: true)
        paths = ObjectiveConfigurationPaths(
            claudeConfiguration: root.appendingPathComponent(".claude.json"),
            claudeInstructions: root.appendingPathComponent(".claude/CLAUDE.md"),
            claudeSettings: root.appendingPathComponent(".claude/settings.json"),
            codexConfiguration: root.appendingPathComponent(".codex/config.toml"),
            codexInstructions: root.appendingPathComponent(".codex/AGENTS.md"),
            backup: root.appendingPathComponent("Objective/configuration-backup.json")
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func json(_ url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require(object as? [String: Any])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
