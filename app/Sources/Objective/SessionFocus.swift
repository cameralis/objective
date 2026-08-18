import AppKit
import Foundation

// Brings the agent that asked to the front.
//
// The MCP server renames the agent's terminal window while it waits, so the
// marker is unique even when two agents work in the same repo. Accessibility
// can then raise that window, or click its tab when it sits in the background.
enum SessionFocus {
    static func isAgentAlive(_ origin: ItemOrigin?) -> Bool {
        guard let pid = origin?.pid, pid > 1 else { return true }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    static func canFocus(_ origin: ItemOrigin?) -> Bool {
        origin?.marker != nil && appName(for: origin?.terminal) != nil
    }

    static func focus(_ origin: ItemOrigin?) {
        guard let origin, let app = appName(for: origin.terminal) else { return }
        activate(app)

        // Ghostty only publishes its windows to accessibility while it is the
        // active app, so the script activates it and waits before it looks.
        let script = """
        tell application "System Events"
            if not (exists process "\(app)") then return "no process"
            tell process "\(app)"
                set frontmost to true
                repeat 20 times
                    if (count of windows) > 0 then exit repeat
                    delay 0.1
                end repeat
                set marker to "\(escaped(origin.marker ?? ""))"
                set project to "\(escaped(origin.project ?? ""))"
                repeat with w in windows
                    if name of w is marker then
                        perform action "AXRaise" of w
                        return "window"
                    end if
                    try
                        repeat with t in (every radio button of tab group 1 of w)
                            if name of t is marker then
                                click t
                                perform action "AXRaise" of w
                                return "tab"
                            end if
                        end repeat
                    end try
                end repeat
                repeat with w in windows
                    if name of w contains project then
                        perform action "AXRaise" of w
                        return "project"
                    end if
                end repeat
            end tell
        end tell
        return "not found"
        """

        // Off the main thread: the first run shows the Automation prompt.
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                NSLog("focus failed: \(error)")
            }
            DispatchQueue.main.async { activate(app) }
        }
    }

    private static func activate(_ app: String) {
        let running = NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(app) == .orderedSame
        }
        running?.activate(options: [])
    }

    // TERM_PROGRAM to the application name accessibility knows.
    private static func appName(for terminal: String?) -> String? {
        switch terminal?.lowercased() {
        case "ghostty": return "ghostty" // its accessibility name is lowercase
        case "iterm.app": return "iTerm2"
        case "apple_terminal": return "Terminal"
        case "warpterminal": return "Warp"
        case "wezterm": return "WezTerm"
        case "kitty": return "kitty"
        case "alacritty": return "Alacritty"
        case "vscode": return "Code"
        default: return nil
        }
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
