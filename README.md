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
- "Explain this visually" button: generates a fun, interactive single-file
  web page explaining the article + discussion, served by a personal
  explainer server (see below) and opened full screen in the app

## Explainer server

`server/server.py` is a zero-dependency Python 3 server meant to run on a
Mac on the same Tailscale tailnet. When the app requests
`GET /explainer/<story_id>`, generation starts in the background and the app
polls the same endpoint until `{"status": "ready"}`, then loads
`/explainer/<story_id>/html`.

The pipeline:

1. The article is rendered in headless Chrome (`--headless --dump-dom`, so
   JS-built pages work) and reduced to text
2. **All** comments are used, no matter how many: whole threads are packed
   into ~18k-char chunks and compressed in parallel by a small model
   (`gpt-5.4-mini`) into dense digests — map-reduce instead of truncation
3. The article text + digests go to a big model (`gpt-5.5`), which writes a
   self-contained interactive HTML page (inline CSS/JS, mobile-first,
   dark-mode aware): visual explanations of the article's ideas plus a
   "The Discussion" section mapping the camps and arguments
4. Pages are cached in `server/cache/`, so each story costs one generation

Setup on the server machine:

1. Put an OpenAI API key in `server/openai_key` (gitignored, `chmod 600`)
2. Run it as a launchd service (label `com.benlirio.hn-summary`) pointing at
   `python3 server/server.py`; it listens on port 8434
3. The app reaches it at `http://bens-mac-mini.tailab3f3c.ts.net:8434` — the
   Tailscale MagicDNS name is hardcoded in `HNClient.serverBase`, and
   `Info.plist` carries an App Transport Security exception for `ts.net`
   (plain HTTP inside the tailnet)

That's it.

## Building

Open `HN.xcodeproj` in Xcode 16+ and run, or from the command line:

```sh
xcodebuild -project HN.xcodeproj -scheme HN -destination 'generic/platform=iOS' build
```

Requires iOS 17+.
