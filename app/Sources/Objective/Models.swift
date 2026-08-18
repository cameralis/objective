import Foundation

// Where the question came from, so the board can jump to that exact agent.
struct ItemOrigin: Codable, Equatable {
    var sessionId: String?
    var project: String?
    var projectDir: String?
    var pid: Int?
    var tty: String?
    var terminal: String?
    var marker: String?
    var code: String?
}

struct ObjectiveItem: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var detail: String?
    var status: String // "open" | "done"
    var createdAt: Double
    var doneAt: Double?
    var choices: [String]?
    var allowReply: Bool?
    var urgent: Bool?
    var source: String?
    var answer: String?
    var answeredAt: Double?
    var origin: ItemOrigin?
    var waiting: Bool?
    var waitingSince: Double?

    var isOpen: Bool { status == "open" }
    var isUrgent: Bool { urgent ?? false }
    // An agent that sits inside the tool call is stalled until this is answered.
    var isBlocking: Bool { isOpen && (waiting ?? false) }

    var blockedFor: TimeInterval? {
        guard isBlocking, let since = waitingSince else { return nil }
        return Date().timeIntervalSince1970 - since
    }
}

struct BoardState: Codable {
    var rev: Int
    var items: [ObjectiveItem]

    static let empty = BoardState(rev: 0, items: [])
}

enum StatePaths {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Objective", isDirectory: true)
    }
    static var stateFile: URL {
        directory.appendingPathComponent("state.json")
    }
}
