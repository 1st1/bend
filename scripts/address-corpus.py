#!/usr/bin/env python3
"""Explore local browsing history with Bend's current address matcher."""
import argparse
from contextlib import closing
import curses
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


def load_sources(worker=None, *, include_safari=False):
    """Read consistent, per-profile snapshots. Only the unique URLs stay in Python."""
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
                """)] if bend and worker else []
        except (OSError, sqlite3.Error) as error:
            print(f"{name}: skipped ({error})", file=sys.stderr)
            continue
        distinct = {visit["url"] for visit in visits}
        urls.update(distinct)
        print(f"{name}: {len(distinct):,} distinct URLs", file=sys.stderr)
        if worker:
            worker.stdin.write(json.dumps({"visits": visits, "choices": choices}) + "\n")
    if worker:
        worker.stdin.write("\n")
        worker.stdin.flush()
    return list(urls)


def matcher_binary():
    sources = [ROOT / "Sources/BrowseCore" / name for name in ("History.swift", "FuzzyMatch.swift")]
    sources.append(ROOT / "scripts/address-corpus/Matcher.swift")
    binary = WORK / "matcher"
    if not binary.exists() or any(p.stat().st_mtime_ns >= binary.stat().st_mtime_ns for p in sources):
        with tempfile.TemporaryDirectory(dir=WORK) as build:
            output = Path(build) / "matcher"
            subprocess.run(["swiftc", "-O", "-module-cache-path", str(ROOT / ".build/clang-cache"),
                            *sources, "-o", output], check=True)
            os.replace(output, binary)
    return binary


def random_urls(urls):
    return random.sample(urls, min(10, len(urls)))


def explore(screen, urls, worker):
    curses.set_escdelay(100)
    highlight = curses.A_BOLD
    if curses.has_colors():
        try:
            curses.use_default_colors()
            curses.init_pair(1, curses.COLOR_WHITE, -1)
            highlight |= curses.color_pair(1)
        except curses.error:
            pass
    cases = {}
    query = ""
    inspiration = []
    status = ""
    last_query = None
    while True:
        if query != last_query:
            worker.stdin.write(json.dumps(query) + "\n")
            worker.stdin.flush()
            reply = worker.stdout.readline()
            if not reply:
                raise RuntimeError("Matcher exited before returning results.")
            matches = json.loads(reply)
            last_query = query
            selected = 0
        screen.erase()

        def line(y, text):
            height, width = screen.getmaxyx()
            if y < height and width > 1:
                clean = "".join(c if c.isprintable() else " " for c in text)
                screen.addnstr(y, 0, clean, width - 1)

        line(0, "Type to match   ↑↓: choose best   Ctrl-G: mark case   Ctrl-R: 10 random URLs   Esc: quit")
        line(1, "> " + query)
        def highlighted_line(y, prefix, runs):
            height, width = screen.getmaxyx()
            if y >= height or width <= len(prefix) + 1:
                return
            screen.addstr(y, 0, prefix)
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

        y = 3
        for index, result in enumerate(matches, 1):
            prefix = f"{'>' if index == selected + 1 else ' '} {index}. "
            highlighted_line(y, prefix, result["address"])
            y += 1
            if any(run["matched"] for run in result["title"]):
                highlighted_line(y, "     ", result["title"])
                y += 1
        if not matches:
            line(3, "No history matches")
        y = max(9, y + 1)
        line(y, "Inspiration" if inspiration else "")
        for index, url in enumerate(inspiration):
            line(y + 1 + index, url)
        line(2, status)
        screen.move(1 if screen.getmaxyx()[0] > 1 else 0, min(len(query) + 2, screen.getmaxyx()[1] - 1))
        screen.refresh()
        key = screen.get_wch()
        status = ""
        if key in ("\x1b", "\x03", "\x04"):
            return cases
        if key == "\x12":
            inspiration = random_urls(urls)
        elif key == curses.KEY_DOWN and matches:
            selected = min(selected + 1, len(matches) - 1)
        elif key == curses.KEY_UP:
            selected = max(0, selected - 1)
        elif key == "\x07" and query:
            expected = [result["url"] for result in matches]
            if expected:
                expected.insert(0, expected.pop(selected))
            cases[query] = expected
            status = "Marked for this session; prints on exit"
        elif key in (curses.KEY_BACKSPACE, "\x7f", "\b"):
            query = query[:-1]
        elif key == "\x15":
            query = ""
        elif isinstance(key, str) and key.isprintable():
            query += key


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--random", action="store_true", help="print ten random distinct URLs and exit")
    parser.add_argument("--safari", action="store_true", help="also read available Safari histories")
    args = parser.parse_args()
    os.umask(0o077)
    if args.random:
        print("\n".join(random_urls(load_sources(include_safari=args.safari))))
    else:
        WORK.mkdir(mode=0o700, exist_ok=True)
        with subprocess.Popen([matcher_binary()], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              text=True, encoding="utf-8") as worker:
            try:
                urls = load_sources(worker, include_safari=args.safari)
                cases = curses.wrapper(explore, urls, worker)
            finally:
                worker.stdin.close()
        for query, matches in cases.items():
            print(query)
            for index, url in enumerate(matches, 1):
                print(f"  {index}. {url}")


if __name__ == "__main__":
    main()
