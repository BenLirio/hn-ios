#!/usr/bin/env python3
"""Summary server for the HN iOS app.

GET /summary/<story_id> renders the article in headless Chrome, pulls the
comment tree from the Algolia HN API, asks OpenAI for a combined summary,
and returns {"summary": "..."}. Results are cached on disk per story.

Stdlib only — no dependencies. Run: python3 server.py
"""

import json
import re
import subprocess
import tempfile
import threading
import urllib.request
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 8434
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
BASE_DIR = Path(__file__).resolve().parent
CACHE_DIR = BASE_DIR / "cache"
API_KEY = (BASE_DIR / "openai_key").read_text().strip()
MODEL = "gpt-5-mini"
ARTICLE_CHAR_LIMIT = 15000
COMMENTS_CHAR_LIMIT = 25000

_locks_guard = threading.Lock()
_story_locks = {}


class TextExtractor(HTMLParser):
    SKIP = {"script", "style", "noscript", "svg", "template", "head"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.skip_depth = 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip_depth += 1

    def handle_endtag(self, tag):
        if tag in self.SKIP and self.skip_depth > 0:
            self.skip_depth -= 1

    def handle_data(self, data):
        if self.skip_depth == 0 and data.strip():
            self.parts.append(data.strip())


def html_to_text(html):
    extractor = TextExtractor()
    try:
        extractor.feed(html)
    except Exception:
        pass
    text = "\n".join(extractor.parts)
    return re.sub(r"\n{3,}", "\n\n", text)


def fetch_article_text(url):
    """Render the page in headless Chrome so JS-built pages work too."""
    with tempfile.TemporaryDirectory() as profile:
        result = subprocess.run(
            [
                CHROME,
                "--headless=new",
                "--disable-gpu",
                "--mute-audio",
                "--no-first-run",
                "--hide-scrollbars",
                f"--user-data-dir={profile}",
                "--virtual-time-budget=8000",
                "--timeout=20000",
                "--dump-dom",
                url,
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
    return html_to_text(result.stdout)[:ARTICLE_CHAR_LIMIT]


def fetch_story(story_id):
    url = f"https://hn.algolia.com/api/v1/items/{story_id}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.load(resp)


def comments_to_text(children, depth=0):
    lines = []
    for child in children:
        author, text = child.get("author"), child.get("text")
        if author and text:
            body = html_to_text(text).replace("\n", " ")
            lines.append(f"{'  ' * depth}{author}: {body}")
        lines.extend(comments_to_text(child.get("children", []), depth + 1))
    return lines


def summarize(title, article_text, comments_text):
    prompt = (
        f"Hacker News story: {title}\n\n"
        f"Article text (may be truncated or missing):\n{article_text or '(no article text available)'}\n\n"
        f"Comment thread (indentation shows reply depth):\n{comments_text or '(no comments yet)'}\n\n"
        "Write a concise summary in plain text with '-' bullets and exactly two sections:\n"
        "ARTICLE: 2-4 bullets summarizing the article's key points.\n"
        "DISCUSSION: 3-6 bullets covering the main themes of the comments, notable "
        "disagreements, and the most interesting insights. No other formatting."
    )
    body = json.dumps(
        {
            "model": MODEL,
            "reasoning_effort": "low",
            "max_completion_tokens": 3000,
            "messages": [{"role": "user", "content": prompt}],
        }
    ).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=body,
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        data = json.load(resp)
    return data["choices"][0]["message"]["content"].strip()


def get_summary(story_id):
    cache_file = CACHE_DIR / f"{story_id}.json"
    with _locks_guard:
        lock = _story_locks.setdefault(story_id, threading.Lock())
    with lock:
        if cache_file.exists():
            return json.loads(cache_file.read_text())["summary"]

        story = fetch_story(story_id)
        title = story.get("title", "")
        article_text = ""
        if story.get("url"):
            try:
                article_text = fetch_article_text(story["url"])
            except Exception as e:
                print(f"[{story_id}] article fetch failed: {e}", flush=True)
        comments_text = "\n".join(comments_to_text(story.get("children", [])))[:COMMENTS_CHAR_LIMIT]

        summary = summarize(title, article_text, comments_text)
        CACHE_DIR.mkdir(exist_ok=True)
        cache_file.write_text(json.dumps({"summary": summary}))
        return summary


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"ok": True})
        match = re.fullmatch(r"/summary/(\d+)", self.path)
        if not match:
            return self._send(404, {"error": "not found"})
        story_id = int(match.group(1))
        try:
            summary = get_summary(story_id)
            self._send(200, {"summary": summary})
        except Exception as e:
            print(f"[{story_id}] failed: {e}", flush=True)
            self._send(500, {"error": str(e)})

    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)


if __name__ == "__main__":
    print(f"HN summary server on :{PORT} (model={MODEL})", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
