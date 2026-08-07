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
                        StoryRow(
                            story: story,
                            openArticle: {
                                if story.url != nil {
                                    presentedURL = IdentifiableURL(url: story.articleURL)
                                } else {
                                    commentsStory = story
                                }
                            },
                            openComments: { commentsStory = story }
                        )
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Hacker News")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $commentsStory) { story in
                ThreadRootView(story: story)
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
    let openArticle: () -> Void
    let openComments: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: openArticle) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(story.title)
                        .font(.subheadline.weight(.medium))
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: openComments) {
                VStack(spacing: 2) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.footnote)
                    Text("\(story.descendants ?? 0)")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.orange)
                .frame(minWidth: 40)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private var meta: String {
        var parts = ["\(story.score) points", story.by, age]
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
