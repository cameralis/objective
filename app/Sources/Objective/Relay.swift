import Foundation

// The overlay and Telegram are two front ends on the same board. When you
// answer or check off here, the chat message must catch up, even when no
// agent waits on that item any more.
enum Relay {
    private struct Config: Decodable {
        let url: String
        let accountKey: String
    }

    private static var config: Config? {
        let file = StatePaths.directory.appendingPathComponent("relay.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    static func close(_ id: String, answer: String?) {
        guard let config, let url = URL(string: "\(config.url)/v1/close") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(config.accountKey)", forHTTPHeaderField: "authorization")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["id": id, "answer": answer as Any]
        )
        // Nothing here waits for the chat. A failed edit costs nothing.
        URLSession.shared.dataTask(with: request).resume()
    }
}
