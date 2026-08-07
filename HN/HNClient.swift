import Foundation

struct Story: Identifiable, Hashable, Decodable {
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

    // Personal explainer server (server/ in this repo) running on the Mac mini,
    // reachable over Tailscale. Generation runs in the background there; the
    // app polls status until the interactive page is ready.
    static let serverBase = URL(string: "http://bens-mac-mini.tailab3f3c.ts.net:8434")!

    enum ExplainerStatus {
        case working(String)
        case ready(URL)
        case failed(String)
    }

    static func explainerStatus(storyID: Int) async throws -> ExplainerStatus {
        var request = URLRequest(url: serverBase.appending(path: "explainer/\(storyID)"))
        request.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Response: Decodable { let status: String; let stage: String?; let error: String? }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        switch decoded.status {
        case "ready":
            return .ready(serverBase.appending(path: "explainer/\(storyID)/html"))
        case "working":
            return .working(decoded.stage ?? "working")
        default:
            return .failed(decoded.error ?? "Unknown server error")
        }
    }

    // Fetched via the Algolia HN API: one request returns the whole comment tree,
    // instead of one Firebase request per comment.
    static func comments(storyID: Int) async throws -> [CommentNode] {
        let url = URL(string: "https://hn.algolia.com/api/v1/items/\(storyID)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let root = try JSONDecoder().decode(AlgoliaItem.self, from: data)
        return root.children.compactMap(CommentNode.init)
    }
}

struct CommentNode: Identifiable, Hashable {
    let id: Int
    let author: String
    let text: AttributedString
    let time: TimeInterval
    let children: [CommentNode]
    let descendantCount: Int

    init?(item: AlgoliaItem) {
        guard let author = item.author, let text = item.text else { return nil }
        self.id = item.id
        self.author = author
        self.text = AttributedString(html: text)
        self.time = item.created_at_i
        self.children = item.children.compactMap(CommentNode.init)
        self.descendantCount = children.count + children.reduce(0) { $0 + $1.descendantCount }
    }
}

struct AlgoliaItem: Decodable {
    let id: Int
    let author: String?
    let text: String?
    let created_at_i: TimeInterval
    let children: [AlgoliaItem]
}

extension AttributedString {
    // HN comment bodies are a small subset of HTML; translate to markdown
    // rather than paying for a WebKit-backed NSAttributedString per comment.
    init(html: String) {
        var s = html
        for (tag, replacement) in [
            ("<p>", "\n\n"), ("</p>", ""),
            ("<i>", "*"), ("</i>", "*"),
            ("<em>", "*"), ("</em>", "*"),
            ("<b>", "**"), ("</b>", "**"),
            ("<pre><code>", "\n\n"), ("</code></pre>", "\n\n"),
            ("<code>", "`"), ("</code>", "`"),
            ("<br>", "\n"),
        ] {
            s = s.replacingOccurrences(of: tag, with: replacement)
        }
        s = s.replacingOccurrences(
            of: #"<a href="([^"]*)"[^>]*>([^<]*)</a>"#,
            with: "[$2]($1)",
            options: .regularExpression
        )
        for (entity, char) in [
            ("&gt;", ">"), ("&lt;", "<"), ("&quot;", "\""),
            ("&#x27;", "'"), ("&#39;", "'"), ("&#x2F;", "/"), ("&amp;", "&"),
        ] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        self = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        self = self.trimmed()
    }

    private func trimmed() -> AttributedString {
        var copy = self
        while let last = copy.characters.last, last.isWhitespace || last.isNewline {
            copy.characters.removeLast()
        }
        while let first = copy.characters.first, first.isWhitespace || first.isNewline {
            copy.characters.removeFirst()
        }
        return copy
    }
}
