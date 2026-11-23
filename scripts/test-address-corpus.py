"""Exercise the actual CPython/Swift bridge without reading a developer's history."""
from contextlib import closing
from pathlib import Path
import runpy
import unittest

Matcher = runpy.run_path(str(Path(__file__).with_name("address-corpus.py")))["Matcher"]


class AddressCorpusTests(unittest.TestCase):
    def test_popup_rows_across_ffi(self):
        visits = [{"url": url, "title": title, "date": 810000000} for url, title in [
            ("https://www.amazon.com/", "Amazon"), ("https://github.com/1st1/jit", "JIT compiler"),
        ]]
        def texts(reply, field):
            return ["".join(run["text"] for run in row[field]) for row in reply["rows"]]

        with closing(Matcher([{"visits": visits, "choices": []}], {"searchEngine": "kagi"})) as matcher:
            ama = matcher.query("ama")
            self.assertEqual(texts(ama, "detail"), ["www.amazon.com/", "Search with Kagi"])
            self.assertEqual(ama["completion"], "amazon.com/")
            self.assertEqual(ama["rows"][0]["historyURL"], "https://www.amazon.com/")
            self.assertEqual(ama["selected"], 0)
            self.assertNotIn("score", ama["rows"][1])
            self.assertEqual(ama["rows"][0]["score"]["tier"], 3)
            self.assertEqual(ama["rows"][0]["score"]["fuzzy"], 0)
            self.assertGreater(ama["rows"][0]["score"]["usage"], 0)
            for exact in ("amazon.com", "www.amazon.com"):
                rows = matcher.query(exact)["rows"]
                self.assertEqual(len(rows), 2)
                self.assertNotIn("score", rows[0])  # Explicit Visit still wins.
                self.assertEqual(rows[1]["score"]["tier"], 4)
            prefix = matcher.query("git")
            self.assertEqual(prefix["completion"], "github.com/1st1/jit")
            self.assertEqual(texts(prefix, "title"), ["JIT compiler", "Search for “git”"])
            self.assertEqual(texts(matcher.query("git", autofill=False), "detail")[0], "Search with Kagi")
            path = matcher.query("github/jit")
            self.assertEqual(texts(path, "title")[0], "JIT compiler")
            self.assertNotIn("completion", path)
            self.assertGreater(path["rows"][0]["score"]["fuzzy"], 0)
            self.assertEqual(matcher.query("")["selected"], -1)
            self.assertEqual(texts(matcher.query("café ☕"), "title"), ["Search for “café ☕”"])


if __name__ == "__main__":
    unittest.main()
