#!/usr/bin/env python3
"""Find passing native shards for the exact tree merged into main."""
import json
import os
import re
import subprocess
import sys


def tested_run(api, repo, commit, tree):
    for pr in api(f"commits/{commit}/pulls"):
        if not (pr["merged_at"] and pr["merge_commit_sha"] == commit
                and pr["base"]["ref"] == "main" and pr["head"]["repo"]
                and pr["head"]["repo"]["full_name"] == repo):
            continue
        head = pr["head"]["sha"]
        query = f"event=pull_request&status=success&head_sha={head}"
        for run in api(f"actions/workflows/changelog.yml/runs?{query}")["workflow_runs"]:
            if not any(p["number"] == pr["number"] for p in run["pull_requests"]):
                continue
            jobs = api(f"actions/runs/{run['id']}/jobs?filter=latest&per_page=100")["jobs"]
            revisions = []
            for shard in (0, 1):
                name = f"macOS 26 build and tests (shard {shard})"
                shard_revisions = []
                for job in jobs:
                    if job["name"] != name or job["conclusion"] != "success":
                        continue
                    for step in job["steps"]:
                        match = re.fullmatch(r"Run Swift tests at ([0-9a-f]{40})", step["name"])
                        if match and step["conclusion"] == "success":
                            shard_revisions.append(match[1])
                if len(shard_revisions) == 1:
                    revisions.extend(shard_revisions)
            if len(revisions) == 2 and revisions[0] == revisions[1]:
                if api(f"git/commits/{revisions[0]}")["tree"]["sha"] == tree:
                    return run["html_url"]
    return None


if __name__ == "__main__":
    repo = os.environ["GITHUB_REPOSITORY"]

    def api(path):
        return json.loads(subprocess.check_output(
            ["gh", "api", f"repos/{repo}/{path}"], text=True, timeout=20))

    try:
        result = tested_run(api, repo, os.environ["GITHUB_SHA"],
                            subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], text=True).strip())
    except (subprocess.SubprocessError, OSError, KeyError, TypeError, ValueError) as error:
        print(f"Cannot verify PR test result: {error}", file=sys.stderr)
        result = None
    print(f"Reusing native suite: {result}" if result else "Running full native suite")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        print(f"reuse={'true' if result else 'false'}", file=output)
