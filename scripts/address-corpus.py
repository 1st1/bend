#!/usr/bin/env python3
"""Explore local browsing history with Bend's current address matcher."""
import argparse
from contextlib import closing
import ctypes
import curses
import hashlib
import json
import os
import random
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unicodedata

ROOT = Path(__file__).resolve().parent.parent
WORK = Path(tempfile.gettempdir()) / f"bend-address-corpus-{os.getuid()}"


def sources(include_safari):
    library = Path.home() / "Library"
    support = library / "Application Support"
    yield "Bend", support / "BrowsePrototype/History.db", True
    yield "Bend Debug", support / "Bend Debug/History.db", True
    if not include_safari:
        return
    safari = library / "Safari"
    yield "Safari", safari / "History.db", False
    for profile in sorted((safari / "Profiles").glob("*/History.db")):
        yield f"Safari/{profile.parent.name}", profile, False


def load_sources(snapshots=None, *, include_safari=False):
    """Read consistent, per-profile snapshots, optionally including ranking inputs."""
    urls = set()
    for name, path, bend in sources(include_safari):
        try:
            with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as source:
                source.execute("PRAGMA temp_store = MEMORY")
                source.execute("BEGIN")
                source.row_factory = sqlite3.Row
                visits = [dict(row) for row in source.execute("""
                    SELECT i.url, coalesce(v.title, '') AS title, coalesce(v.visit_time, 0) AS date
                    FROM history_items i LEFT JOIN history_visits v ON v.history_item = i.id
                    WHERE i.url IS NOT NULL AND i.url != ''
                """)]
                choices = [dict(row) for row in source.execute("""
                    SELECT c.query, i.url, c.weight, c.choice_time AS date
                    FROM history_choices c JOIN history_items i ON c.history_item = i.id
                """)] if bend and snapshots is not None else []
        except (OSError, sqlite3.Error) as error:
            print(f"{name}: skipped ({error})", file=sys.stderr)
            continue
        distinct = {visit["url"] for visit in visits}
        urls.update(distinct)
        print(f"{name}: {len(distinct):,} distinct URLs", file=sys.stderr)
        if snapshots is not None:
            snapshots.append({"visits": visits, "choices": choices})
    return list(urls)


def matcher_library():
    sources = sorted((ROOT / "Sources/BrowseCore").glob("*.swift"))
    sources.append(ROOT / "scripts/address-corpus/Matcher.swift")
    WORK.mkdir(mode=0o700, exist_ok=True)
    key = hashlib.sha256(subprocess.check_output(["swiftc", "--version"], stderr=subprocess.STDOUT))
    for path in sources:
        key.update(path.name.encode())
        key.update(hashlib.sha256(path.read_bytes()).digest())
    binary = WORK / f"matcher-{key.hexdigest()[:20]}.dylib"
    if not binary.exists():
        with tempfile.TemporaryDirectory(dir=WORK) as build:
            output = Path(build) / binary.name
            subprocess.run(["swiftc", "-O", "-emit-library", "-module-cache-path", str(ROOT / ".build/clang-cache"),
                            *sources, "-o", output], check=True)
            os.replace(output, binary)
    return binary


class Matcher:
    def __init__(self, snapshots, preferences):
        self.lib = ctypes.CDLL(str(matcher_library()))
        ptr, text = ctypes.c_void_p, ctypes.c_char_p
        for name, result, args in [
            ("bend_corpus_create", ptr, [text]), ("bend_corpus_query", ptr, [ptr, text, ctypes.c_int32]),
            ("bend_corpus_free_reply", None, [ptr]), ("bend_corpus_destroy", None, [ptr]),
        ]:
            func = getattr(self.lib, name)
            func.argtypes, func.restype = args, result
        self.handle = self.lib.bend_corpus_create(json.dumps(dict(preferences, snapshots=snapshots)).encode())
        if not self.handle:
            raise ValueError("Swift could not decode the history or search engine preferences.")

    def query(self, text, autofill=True):
        reply = self.lib.bend_corpus_query(self.handle, text.encode(), autofill)
        if not reply:
            raise RuntimeError("Swift could not encode address results.")
        try:
            return json.loads(ctypes.string_at(reply))
        finally:
            self.lib.bend_corpus_free_reply(reply)

    def close(self):
        self.lib.bend_corpus_destroy(self.handle)


def search_preferences():
    for _, db, _ in sources(False):  # Prefer the production profile's search provider.
        try:
            session = json.loads(db.with_name("session.json").read_text())
            return {k: session.get(k) for k in ("searchEngine", "customSearchEngine")}
        except (ValueError, OSError):
            continue
    return {}


def random_urls(urls):
    return random.sample(urls, min(10, len(urls)))


SCORE_GUIDE = (
    "• Tier: match type. Higher wins; 0 fuzzy/empty, 1–4 literal, 5–7 path.",
    "• Fuzzy: breaks tier ties. Tighter letter or path matches score higher.",
    "• Usage: breaks fuzzy ties. Recent visits and past choices score higher.",
    "• [action]: Search or Visit; not scored.",
)


def score_badge(row):
    score = row.get("score")
    if score is None:
        return "[action]"
    return f"[tier {score['tier']} · fuzzy {score['fuzzy']} · usage {score['usage']:.2f}]"


def explore(screen, urls, matcher):
    curses.set_escdelay(100)
    highlight = curses.A_BOLD
    score_style = curses.A_BOLD
    if curses.has_colors():
        try:
            curses.use_default_colors()
            curses.init_pair(1, curses.COLOR_WHITE, -1)
            highlight |= curses.color_pair(1)
            curses.init_pair(2, curses.COLOR_CYAN, -1)
            score_style |= curses.color_pair(2)
        except curses.error:
            pass
    cases = {}
    query = ""
    inspiration = []
    status = ""
    last_query = None
    autofill = False
    while True:
        if query != last_query:
            reply = matcher.query(query, autofill)
            matches = reply["rows"]
            last_query = query
            selected = reply["selected"]
            editor_text = query
            completion = reply.get("completion")
        screen.erase()

        def line(y, text):
            height, width = screen.getmaxyx()
            if y < height and width > 1:
                clean = "".join(c if c.isprintable() else " " for c in text)
                screen.addnstr(y, 0, clean, width - 1)

        for y, bullet in enumerate(SCORE_GUIDE):
            line(y, bullet)
        line(len(SCORE_GUIDE), "Type to match   ↑↓: choose best   Ctrl-G: mark case   Ctrl-R: random URLs   Esc: quit")
        input_y = min(len(SCORE_GUIDE) + 1, screen.getmaxyx()[0] - 1)
        line(input_y, "> " + editor_text)
        cursor = screen.getyx()[1]
        if completion:
            width = screen.getmaxyx()[1]
            x = screen.getyx()[1]
            if x < width - 1:
                screen.addnstr(input_y, x, completion[len(query):], width - x - 1, curses.A_REVERSE)
        def highlighted_line(y, prefix, runs, badge=""):
            height, width = screen.getmaxyx()
            if y >= height or width <= len(prefix) + 1:
                return
            screen.addstr(y, 0, prefix)
            if badge:
                screen.addnstr(badge + " ", width - len(prefix) - 1, score_style)
            for run in runs:
                room = width - 1 - screen.getyx()[1]
                if room <= 0:
                    break
                text = "".join(c if c.isprintable() else " " for c in run["text"])
                # Curses measures terminal cells, including double-width glyphs.
                for char in text:
                    cells = 0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in "WF" else 1
                    if cells > room:
                        return
                    screen.addstr(char, highlight if run["matched"] else curses.A_DIM)
                    room -= cells

        y = input_y + 2
        for index, result in enumerate(matches, 1):
            prefix = f"{'>' if index == selected + 1 else ' '} {index}. "
            highlighted_line(y, prefix, result["title"], score_badge(result))
            y += 1
            highlighted_line(y, "     ", result["detail"])
            y += 1
        if not matches:
            line(y, "No history matches")
        y = max(9, y + 1)
        line(y, "Inspiration" if inspiration else "")
        for index, url in enumerate(inspiration):
            line(y + 1 + index, url)
        line(input_y + 1, status)
        screen.move(input_y, cursor)
        screen.refresh()
        key = screen.get_wch()
        status = ""
        if key in ("\x1b", "\x03", "\x04"):
            return cases
        if key == "\x12":
            inspiration = random_urls(urls)
        elif key in (curses.KEY_DOWN, curses.KEY_UP):
            selected = min(len(matches) - 1, max(-1, selected + (1 if key == curses.KEY_DOWN else -1)))
            editor_text = (matches[selected].get("historyURL") or query) if selected >= 0 else query
            completion = None
        elif key == "\x07" and query:
            expected = [result["historyURL"] for result in matches if result.get("historyURL")]
            if expected and selected >= 0 and not matches[selected].get("historyURL"):
                status = "Select a history URL to mark a corpus case"
                continue
            if expected and selected >= 0:
                url = matches[selected]["historyURL"]
                expected.remove(url)
                expected.insert(0, url)
            cases[query] = expected
            status = "Marked for this session; prints on exit"
        elif key in (curses.KEY_BACKSPACE, "\x7f", "\b"):
            query = editor_text if completion else editor_text[:-1]
            autofill = False
            last_query = None
        elif key == "\x15":
            query = ""
        elif isinstance(key, str) and key.isprintable():
            query = editor_text + key
            autofill = True


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog="\n".join(SCORE_GUIDE),
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--random", action="store_true", help="print ten random distinct URLs and exit")
    mode.add_argument("--query", help="print the address-bar rows for a typed query and exit")
    parser.add_argument("--safari", action="store_true", help="also read available Safari histories")
    args = parser.parse_args()
    os.umask(0o077)
    if args.random:
        print("\n".join(random_urls(load_sources(include_safari=args.safari))))
    else:
        snapshots = []
        urls = load_sources(snapshots, include_safari=args.safari)
        with closing(Matcher(snapshots, search_preferences())) as matcher:
            del snapshots
            if args.query is not None:
                reply = matcher.query(args.query)
                for index, row in enumerate(reply["rows"]):
                    title, detail = ("".join(run["text"] for run in row[key]) for key in ("title", "detail"))
                    badge = score_badge(row)
                    if sys.stdout.isatty() and "NO_COLOR" not in os.environ and os.environ.get("TERM") != "dumb":
                        badge = f"\033[36m{badge}\033[0m"
                    print(f"{'>' if index == reply['selected'] else ' '} {badge} {title}\n    {detail}")
                return
            cases = curses.wrapper(explore, urls, matcher)
        for query, matches in cases.items():
            print(query)
            for index, url in enumerate(matches, 1):
                print(f"  {index}. {url}")


if __name__ == "__main__":
    main()
