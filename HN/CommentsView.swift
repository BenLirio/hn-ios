import SwiftUI

struct CommentsView: View {
    let story: Story
    @State private var comments: [Comment]?
    @State private var error: String?
    @State private var presentedURL: IdentifiableURL?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(story.title)
                        .font(.headline)
                    Text("\(story.score) points · \(story.by)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { presentedURL = IdentifiableURL(url: story.articleURL) }
            }

            if let comments {
                ForEach(comments) { comment in
                    CommentRow(comment: comment)
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
        .task {
            do {
                comments = try await HNClient.comments(storyID: story.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
        .fullScreenCover(item: $presentedURL) { item in
            SafariView(url: item.url).ignoresSafeArea()
        }
    }
}

struct CommentRow: View {
    let comment: Comment

    private static let indentColors: [Color] = [.orange, .blue, .green, .purple, .pink, .teal]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if comment.depth > 0 {
                Rectangle()
                    .fill(Self.indentColors[(comment.depth - 1) % Self.indentColors.count].opacity(0.5))
                    .frame(width: 2)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(comment.author) · \(age)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(comment.text)
                    .font(.subheadline)
            }
        }
        .padding(.leading, CGFloat(min(comment.depth, 8)) * 12)
        .padding(.vertical, 2)
    }

    private var age: String {
        Date(timeIntervalSince1970: comment.time).formatted(.relative(presentation: .named))
    }
}
