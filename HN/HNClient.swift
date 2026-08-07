import Foundation

struct Story: Identifiable, Decodable {
    let id: Int
    let title: String
    let url: URL?
    let score: Int
    let by: String
    let descendants: Int?
    let time: TimeInterval

    var articleURL: URL { url ?? commentsURL }
    var commentsURL: URL { URL(string: "https://news.ycombinator.com/item?id=\(id)")! }
    var domain: String? { url?.host()?.replacingOccurrences(of: "www.", with: "") }
}

enum HNClient {
    static let base = URL(string: "https://hacker-news.firebaseio.com/v0")!

    static func topStories(limit: Int = 50) async throws -> [Story] {
        let (data, _) = try await URLSession.shared.data(from: base.appending(path: "topstories.json"))
        let ids = Array(try JSONDecoder().decode([Int].self, from: data).prefix(limit))

        return try await withThrowingTaskGroup(of: (Int, Story?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { (index, try? await item(id: id)) }
            }
            var stories = [Story?](repeating: nil, count: ids.count)
            for try await (index, story) in group {
                stories[index] = story
            }
            return stories.compactMap { $0 }
        }
    }

    static func item(id: Int) async throws -> Story {
        let (data, _) = try await URLSession.shared.data(from: base.appending(path: "item/\(id).json"))
        return try JSONDecoder().decode(Story.self, from: data)
    }
}
