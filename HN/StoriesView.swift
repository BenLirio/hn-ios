import SwiftUI
import SafariServices

struct StoriesView: View {
    @State private var stories: [Story] = []
    @State private var error: String?
    @State private var presentedURL: IdentifiableURL?
    @State private var commentsStory: Story?

    var body: some View {
        NavigationStack {
            Group {
                if let error, stories.isEmpty {
                    ContentUnavailableView("Couldn't load stories", systemImage: "wifi.slash", description: Text(error))
                } else if stories.isEmpty {
                    ProgressView()
                } else {
                    List(stories) { story in
                        StoryRow(story: story)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if story.url != nil {
                                    presentedURL = IdentifiableURL(url: story.articleURL)
                                } else {
                                    commentsStory = story
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Comments", systemImage: "bubble.right") {
                                    commentsStory = story
                                }
                                .tint(.orange)
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Hacker News")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $commentsStory) { story in
                CommentsView(story: story)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .fullScreenCover(item: $presentedURL) { item in
            SafariView(url: item.url).ignoresSafeArea()
        }
    }

    private func load() async {
        do {
            stories = try await HNClient.topStories()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct StoryRow: View {
    let story: Story

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(story.title)
                .font(.subheadline.weight(.medium))
            Text(meta)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var meta: String {
        var parts = ["\(story.score) points", story.by, age]
        if let comments = story.descendants { parts.append("\(comments) comments") }
        if let domain = story.domain { parts.append(domain) }
        return parts.joined(separator: " · ")
    }

    private var age: String {
        let date = Date(timeIntervalSince1970: story.time)
        return date.formatted(.relative(presentation: .named))
    }
}

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
