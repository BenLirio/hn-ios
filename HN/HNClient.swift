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

    // Fetched via the Algolia HN API: one request returns the whole comment tree,
    // instead of one Firebase request per comment.
    static func comments(storyID: Int) async throws -> [Comment] {
        let url = URL(string: "https://hn.algolia.com/api/v1/items/\(storyID)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let root = try JSONDecoder().decode(AlgoliaItem.self, from: data)
        return flatten(root.children, depth: 0)
    }

    private static func flatten(_ items: [AlgoliaItem], depth: Int) -> [Comment] {
        items.flatMap { item -> [Comment] in
            guard let author = item.author, let text = item.text else { return [] }
            let comment = Comment(
                id: item.id,
                author: author,
                text: AttributedString(html: text),
                time: item.created_at_i,
                depth: depth
            )
            return [comment] + flatten(item.children, depth: depth + 1)
        }
    }
}

struct Comment: Identifiable {
    let id: Int
    let author: String
    let text: AttributedString
    let time: TimeInterval
    let depth: Int
}

private struct AlgoliaItem: Decodable {
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
