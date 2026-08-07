# HN

A super minimal iOS Hacker News reader — a thin SwiftUI wrapper around the
[official Hacker News API](https://github.com/HackerNews/API).

## Features

- Top 50 stories with points, author, age, and domain
- Tap a story to read the article in an in-app Safari view; tap the orange
  bubble to read its comments
- Comments use drill-down navigation: every screen shows one level of replies
  at full width, and a comment's "N replies" chip pushes a screen with that
  comment pinned on top for context — no squeezed indentation, back-swipe to
  go up a level (fetched in one request via the
  [Algolia HN API](https://hn.algolia.com/api))
- Links inside comments open in the in-app Safari view
- Pull to refresh

That's it.

## Building

Open `HN.xcodeproj` in Xcode 16+ and run, or from the command line:

```sh
xcodebuild -project HN.xcodeproj -scheme HN -destination 'generic/platform=iOS' build
```

Requires iOS 17+.
