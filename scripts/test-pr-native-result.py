import copy
from pathlib import Path
import runpy
import unittest

tested_run = runpy.run_path(str(Path(__file__).with_name("pr-native-result.py")))["tested_run"]


class PRResultTests(unittest.TestCase):
    def setUp(self):
        revision = "a" * 40
        self.pr = {"number": 1, "merged_at": "today", "merge_commit_sha": "merged",
                   "base": {"ref": "main"}, "head": {"sha": "head", "repo": {"full_name": "org/repo"}}}
        self.jobs = [{"name": f"macOS 26 build and tests (shard {i})", "conclusion": "success",
                      "steps": [{"name": f"Run Swift tests at {revision}", "conclusion": "success"}]}
                     for i in (0, 1)]
        self.responses = {
            "commits/merged/pulls": [self.pr],
            "actions/workflows/changelog.yml/runs?event=pull_request&status=success&head_sha=head":
                {"workflow_runs": [{"id": 2, "html_url": "run-url", "pull_requests": [{"number": 1}]}]},
            "actions/runs/2/jobs?filter=latest&per_page=100": {"jobs": self.jobs},
            f"git/commits/{revision}": {"tree": {"sha": "matching-tree"}},
        }

    def lookup(self, tree="matching-tree"):
        return tested_run(self.responses.__getitem__, "org/repo", "merged", tree)

    def test_tree_not_commit_controls_reuse(self):
        self.assertEqual(self.lookup(), "run-url")
        self.assertIsNone(self.lookup("different-tree"))

    def test_requires_both_successful_shards_on_same_revision(self):
        for change in ("missing", "skipped", "older workflow", "other revision"):
            with self.subTest(change=change):
                jobs = copy.deepcopy(self.jobs)
                if change == "missing":
                    jobs.pop()
                elif change == "skipped":
                    jobs[0]["steps"][0]["conclusion"] = "skipped"
                else:
                    jobs[0]["steps"][0]["name"] = ("Run Swift tests" if change == "older workflow"
                                                   else "Run Swift tests at " + "b" * 40)
                self.responses["actions/runs/2/jobs?filter=latest&per_page=100"]["jobs"] = jobs
                self.assertIsNone(self.lookup())

    def test_requires_same_repository_and_exact_merge(self):
        self.pr["merge_commit_sha"] = "previous"
        self.assertIsNone(self.lookup())
        self.pr["merge_commit_sha"] = "merged"
        self.pr["head"]["repo"]["full_name"] = "fork/repo"
        self.assertIsNone(self.lookup())


if __name__ == "__main__":
    unittest.main()
