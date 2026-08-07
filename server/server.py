#!/usr/bin/env python3
"""Explainer server for the HN iOS app.

GET /explainer/<story_id>       -> {"status": "working", "stage": ...}
                                   (kicks off generation in the background)
                                   {"status": "ready", "path": "/explainer/<id>/html"}
                                   {"status": "error", "error": ...}
GET /explainer/<story_id>/html  -> the generated single-file interactive page

Pipeline: article rendered with headless Chrome; ALL comments compressed in
parallel chunks by a small model (map), then the article + digests go to the
big model which writes a fun interactive HTML explainer (reduce). Results are
cached on disk per story.

Stdlib only — no dependencies. Run: python3 server.py
"""

import datetime
import json
import re
import socket
import subprocess
import tempfile
import threading
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 8434
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
BASE_DIR = Path(__file__).resolve().parent
CACHE_DIR = BASE_DIR / "cache"
API_KEY = (BASE_DIR / "openai_key").read_text().strip()

BIG_MODEL = "gpt-5.5"        # writes the interactive page
SMALL_MODEL = "gpt-5.4-mini" # compresses comment chunks / long articles
ARTICLE_CHAR_LIMIT = 60000   # raw cap before the small model compresses it
DIGEST_THRESHOLD = 14000     # below this, comments go to the big model raw
CHUNK_CHARS = 18000          # target size of each comment chunk to digest

_lock = threading.Lock()
_jobs = {}    # story_id -> stage string (generation in flight)
_errors = {}  # story_id -> error string from the last attempt


# ---------- text extraction ----------

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
    return re.sub(r"\n{3,}", "\n\n", "\n".join(extractor.parts))


def fetch_article_text(url):
    """Render in headless Chrome (so JS-built pages work), with a plain
    HTTP fetch as fallback when Chrome hangs on a page."""
    try:
        return chrome_dump(url)
    except Exception as e:
        print(f"chrome failed on {url}: {e}; falling back to plain fetch", flush=True)
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            return html_to_text(resp.read().decode("utf-8", "replace"))[:ARTICLE_CHAR_LIMIT]


def chrome_dump(url):
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
            timeout=45,
        )
    text = html_to_text(result.stdout)[:ARTICLE_CHAR_LIMIT]
    if not text.strip():
        raise RuntimeError("empty DOM dump")
    return text


def fetch_story(story_id):
    url = f"https://hn.algolia.com/api/v1/items/{story_id}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.load(resp)


# ---------- OpenAI ----------

def chat(model, prompt, max_tokens, effort=None):
    payload = {
        "model": model,
        "max_completion_tokens": max_tokens,
        "messages": [{"role": "user", "content": prompt}],
    }
    if effort:
        payload["reasoning_effort"] = effort
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=900) as resp:
        data = json.load(resp)
    return data["choices"][0]["message"]["content"].strip()


# ---------- comment digestion (map step) ----------

def comment_threads(children):
    """One flat text block per top-level thread, indentation = reply depth."""
    def walk(node, depth, lines):
        author, text = node.get("author"), node.get("text")
        if author and text:
            body = html_to_text(text).replace("\n", " ")
            lines.append(f"{'  ' * depth}{author}: {body}")
        for child in node.get("children", []):
            walk(child, depth + 1, lines)

    threads = []
    for top in children:
        lines = []
        walk(top, 0, lines)
        if lines:
            threads.append("\n".join(lines))
    return threads


def chunk_threads(threads):
    """Greedily pack whole threads into chunks; split only oversized threads."""
    chunks, current = [], ""
    for thread in threads:
        while len(thread) > CHUNK_CHARS:
            chunks.append(thread[:CHUNK_CHARS])
            thread = thread[CHUNK_CHARS:]
        if len(current) + len(thread) > CHUNK_CHARS and current:
            chunks.append(current)
            current = ""
        current += thread + "\n\n"
    if current.strip():
        chunks.append(current)
    return chunks


def digest_comments(story_id, threads, set_stage):
    text = "\n\n".join(threads)
    if len(text) <= DIGEST_THRESHOLD:
        return text  # small enough to give the big model verbatim

    chunks = chunk_threads(threads)

    def digest(i_chunk):
        i, chunk = i_chunk
        set_stage(f"digesting comments (batch {i + 1}/{len(chunks)})")
        return chat(
            SMALL_MODEL,
            "Compress this portion of a Hacker News comment thread into a dense digest "
            "(under 400 words). Capture: the main arguments and who makes them, the camps "
            "and their disagreements, the sharpest insights, and 2-3 short memorable quotes "
            "with usernames. Indentation shows reply depth.\n\n" + chunk,
            max_tokens=4000,
            effort="low",
        )

    with ThreadPoolExecutor(max_workers=4) as pool:
        digests = list(pool.map(digest, enumerate(chunks)))
    return "\n\n".join(f"[Digest of discussion part {i + 1}/{len(digests)}]\n{d}"
                       for i, d in enumerate(digests))


# ---------- page generation (reduce step) ----------

PAGE_PROMPT = """\
Create a single-file interactive web page that explains a Hacker News article and its \
discussion in a fun, visual way. It will be viewed on an iPhone.

Hard requirements:
- Completely self-contained: inline CSS and JS only. No external requests, fonts, \
libraries, or images (inline SVG/emoji are great).
- Mobile-first and touch-friendly; respect prefers-color-scheme for dark mode.
- Output ONLY the complete HTML document, starting with <!doctype html>. No markdown fences.

Content:
1. Explain the article's core ideas VISUALLY and INTERACTIVELY. Pick whatever form fits \
the content best: an interactive diagram, a step-through walkthrough, sliders or toggles \
that change a visualization, a tiny simulation, before/after comparisons, a playful quiz. \
Prefer showing over telling; keep prose short and punchy.
2. A "The Discussion" section conveying how the HN community reacted: the main camps and \
their arguments, notable disagreements, the sharpest insights, short quotes attributed to \
usernames. Make this visual too (viewpoint cards to flip through, an agree/disagree \
spectrum, a debate map...).
3. Accurate to the source material below. No filler, no placeholders.

Story title: {title}

Article text (extracted from the page; may be messy or missing):
{article}

HN discussion ({comment_count} comments{digested_note}):
{comments}
"""


def generate(story_id):
    def set_stage(stage):
        with _lock:
            _jobs[story_id] = stage
        print(f"[{story_id}] {stage}", flush=True)

    try:
        set_stage("fetching story")
        story = fetch_story(story_id)
        title = story.get("title", "")

        article_text = ""
        if story.get("url"):
            set_stage("rendering article in Chrome")
            try:
                article_text = fetch_article_text(story["url"])
            except Exception as e:
                print(f"[{story_id}] article fetch failed: {e}", flush=True)
        if len(article_text) > 20000:
            set_stage("condensing long article")
            article_text = chat(
                SMALL_MODEL,
                "Condense this article to at most 1200 words, keeping every key idea, "
                "figure, and concrete detail needed to explain it faithfully:\n\n" + article_text,
                max_tokens=6000,
                effort="low",
            )

        threads = comment_threads(story.get("children", []))
        comment_count = sum(t.count("\n") + 1 for t in threads)
        comments = digest_comments(story_id, threads, set_stage)
        digested = comments and comments.startswith("[Digest")

        set_stage("designing the page")
        html = chat(
            BIG_MODEL,
            PAGE_PROMPT.format(
                title=title,
                article=article_text or "(no article text available)",
                comment_count=comment_count,
                digested_note=", pre-digested in parts" if digested else "",
                comments=comments or "(no comments yet)",
            ),
            max_tokens=60000,
        )
        html = re.sub(r"^```(?:html)?\s*|\s*```$", "", html.strip())

        CACHE_DIR.mkdir(exist_ok=True)
        (CACHE_DIR / f"{story_id}.html").write_text(html)
        with _lock:
            _jobs.pop(story_id, None)
            _errors.pop(story_id, None)
        print(f"[{story_id}] ready ({len(html)} bytes)", flush=True)
    except Exception as e:
        with _lock:
            _jobs.pop(story_id, None)
            _errors[story_id] = str(e)
        print(f"[{story_id}] failed: {e}", flush=True)


# ---------- HTTP ----------

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            return self._send_json(200, {"ok": True})

        page = re.fullmatch(r"/explainer/(\d+)/html", self.path)
        if page:
            cached = CACHE_DIR / f"{page.group(1)}.html"
            if cached.exists():
                return self._send(200, cached.read_bytes(), "text/html; charset=utf-8")
            return self._send_json(404, {"error": "not generated yet"})

        status = re.fullmatch(r"/explainer/(\d+)", self.path)
        if status:
            story_id = int(status.group(1))
            if (CACHE_DIR / f"{story_id}.html").exists():
                return self._send_json(200, {"status": "ready", "path": f"/explainer/{story_id}/html"})
            with _lock:
                if story_id in _jobs:
                    return self._send_json(200, {"status": "working", "stage": _jobs[story_id]})
                error = _errors.pop(story_id, None)
                if error:
                    return self._send_json(200, {"status": "error", "error": error})
                _jobs[story_id] = "starting"
            threading.Thread(target=generate, args=(story_id,), daemon=True).start()
            return self._send_json(200, {"status": "working", "stage": "starting"})

        self._send_json(404, {"error": "not found"})

    def _send_json(self, status, payload):
        self._send(status, json.dumps(payload).encode(), "application/json")

    def _send(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        now = datetime.datetime.now().strftime("%H:%M:%S")
        print(f"{now} {self.address_string()} {fmt % args}", flush=True)


class DualStackServer(ThreadingHTTPServer):
    """Listen on both IPv6 and IPv4 — MagicDNS may hand clients either."""
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


if __name__ == "__main__":
    print(f"HN explainer server on :{PORT} (big={BIG_MODEL}, small={SMALL_MODEL})", flush=True)
    DualStackServer(("::", PORT), Handler).serve_forever()
