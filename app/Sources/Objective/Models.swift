import Foundation

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

    var isOpen: Bool { status == "open" }
    var isUrgent: Bool { urgent ?? false }
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
