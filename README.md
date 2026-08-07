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
- "Summarize article & comments" button: an AI summary served by a personal
  summary server (see below)

## Summary server

`server/server.py` is a zero-dependency Python 3 server meant to run on a
Mac on the same Tailscale tailnet. `GET /summary/<story_id>` renders the
article in headless Chrome (`--headless --dump-dom`, so JS-heavy pages work),
pulls the comment tree from Algolia, summarizes both with OpenAI
(`gpt-5-mini`), and caches the result in `server/cache/`.

Setup on the server machine:

1. Put an OpenAI API key in `server/openai_key` (gitignored, `chmod 600`)
2. Run it as a launchd service (label `com.benlirio.hn-summary`) pointing at
   `python3 server/server.py`; it listens on port 8434
3. The app reaches it at `http://bens-mac-mini.tailab3f3c.ts.net:8434` — the
   Tailscale MagicDNS name is hardcoded in `HNClient.summaryBase`, and
   `Info.plist` carries an App Transport Security exception for `ts.net`
   (plain HTTP inside the tailnet)

That's it.

## Building

Open `HN.xcodeproj` in Xcode 16+ and run, or from the command line:

```sh
xcodebuild -project HN.xcodeproj -scheme HN -destination 'generic/platform=iOS' build
```

Requires iOS 17+.
