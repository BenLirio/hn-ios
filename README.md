# HN

A super minimal iOS Hacker News reader — a thin SwiftUI wrapper around the
[official Hacker News API](https://github.com/HackerNews/API).

## Features

- Top 50 stories with points, author, age, comment count, and domain
- Tap a story to read the article in an in-app Safari view
- Swipe left on a story to open its HN comments
- Pull to refresh

That's it.

## Building

Open `HN.xcodeproj` in Xcode 16+ and run, or from the command line:

```sh
xcodebuild -project HN.xcodeproj -scheme HN -destination 'generic/platform=iOS' build
```

Requires iOS 17+.
