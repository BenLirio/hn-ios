import SwiftUI

// Comments are navigated by drilling down: each screen shows one level of
// replies at full width, and a comment's "N replies" chip pushes a screen
// with that comment pinned on top and its direct replies below.

struct ThreadRootView: View {
    let story: Story
    @State private var comments: [CommentNode]?
    @State private var error: String?
    @State private var presentedURL: IdentifiableURL?
    @State private var pushed: CommentNode?

    var body: some View {
        List {
            Section {
                Button {
                    presentedURL = IdentifiableURL(url: story.articleURL)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(story.title)
                            .font(.headline)
                        HStack(spacing: 4) {
                            Image(systemName: "safari")
                            Text(story.domain ?? "news.ycombinator.com")
                            Spacer()
                            Text("\(story.score) points · \(story.by)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            if let comments {
                if comments.isEmpty {
                    Text("No comments yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(comments) { node in
                    CommentCell(node: node) { pushed = node }
                }
            } else if let error {
                ContentUnavailableView("Couldn't load comments", systemImage: "wifi.slash", description: Text(error))
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("\(story.descendants ?? 0) Comments")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $pushed) { ThreadView(node: $0) }
        .task {
            do {
                comments = try await HNClient.comments(storyID: story.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
        .openLinksInApp(presenting: $presentedURL)
    }
}

struct ThreadView: View {
    let node: CommentNode
    @State private var presentedURL: IdentifiableURL?
    @State private var pushed: CommentNode?

    var body: some View {
        List {
            Section {
                CommentCell(node: node, showRepliesChip: false)
                    .listRowBackground(Color.orange.opacity(0.08))
            }
            Section {
                ForEach(node.children) { child in
                    CommentCell(node: child) { pushed = child }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(node.descendantCount == 1 ? "1 Reply" : "\(node.descendantCount) Replies")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $pushed) { ThreadView(node: $0) }
        .openLinksInApp(presenting: $presentedURL)
    }
}

struct CommentCell: View {
    let node: CommentNode
    var showRepliesChip = true
    var onOpenReplies: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(node.author)
                    .font(.caption.weight(.semibold))
                Text(Date(timeIntervalSince1970: node.time).formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(node.text)
                .font(.subheadline)
            if showRepliesChip && node.descendantCount > 0 {
                Button(action: onOpenReplies) {
                    Label(
                        node.descendantCount == 1 ? "1 reply" : "\(node.descendantCount) replies",
                        systemImage: "arrow.turn.down.right"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

// Route links tapped inside comment text to the in-app Safari view.
extension View {
    func openLinksInApp(presenting url: Binding<IdentifiableURL?>) -> some View {
        self
            .environment(\.openURL, OpenURLAction { tapped in
                url.wrappedValue = IdentifiableURL(url: tapped)
                return .handled
            })
            .fullScreenCover(item: url) { item in
                SafariView(url: item.url).ignoresSafeArea()
            }
    }
}
