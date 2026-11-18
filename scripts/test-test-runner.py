#!/usr/bin/env python3
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("test_runner", Path(__file__).with_name("test-all.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


# @lat: [[lat.md/tests/build-tests#Native test runner coverage]]
class TestRunnerTests(unittest.TestCase):
    inventory = "BrowseCoreTests.model()\nBrowseTests.window()\nBrowseTests.optional()\n"

    def execute(self, results, inventory=None, shard_index=0, shard_count=1):
        listing = subprocess.CompletedProcess([], 0, self.inventory if inventory is None else inventory, "")
        with patch.object(runner.subprocess, "run", return_value=listing), \
                patch.object(runner, "run", side_effect=results) as executions, \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = runner.main(["swift", "test", "--no-parallel"], shard_index, shard_count)
        return code, executions

    def test_all_discovered_tests_include_declared_skips(self):
        passed = (0, "Test run with 1 test in 0 suites passed.\n")
        skipped = (0, "Test optional() skipped.\nTest run with 1 test in 0 suites passed.\n")
        code, executions = self.execute([passed, passed, skipped])
        self.assertEqual(code, 0)
        self.assertEqual(executions.call_count, 3)
        for call in executions.call_args_list:
            self.assertIn("--skip-build", call.args[0])

    def test_shards_partition_groups_without_losing_coverage(self):
        inventory = self.inventory + "BrowseCoreTests.anotherModel()\nAITests.sdk()\nBrowseTests.extra()\n"
        passed = (0, "Test run with 1 test passed.\n")
        core = (0, "Test run with 2 tests passed.\n")
        first, shard_zero = self.execute([core, passed, passed], inventory, 0, 2)
        second, shard_one = self.execute([passed, passed], inventory, 1, 2)
        self.assertEqual((first, second), (0, 0))
        zero_patterns = [call.args[0][-1] for call in shard_zero.call_args_list]
        one_patterns = [call.args[0][-1] for call in shard_one.call_args_list]
        self.assertEqual(len(zero_patterns), 3)
        self.assertEqual(len(one_patterns), 2)
        for name in ("model", "anotherModel", "window", "extra"):
            self.assertEqual(sum(name in pattern for pattern in zero_patterns), 1)
        for name in ("sdk", "optional"):
            self.assertEqual(sum(name in pattern for pattern in one_patterns), 1)
        self.assertFalse(set(zero_patterns) & set(one_patterns))

    def test_invalid_shards_do_not_run_tests(self):
        for index, count in ((-1, 2), (2, 2), (0, 0), (0, 4)):
            with self.subTest(index=index, count=count):
                code, executions = self.execute([], shard_index=index, shard_count=count)
                self.assertEqual(code, 1)
                executions.assert_not_called()

    def test_failed_groups_do_not_hide_later_results(self):
        passed = (0, "Test run with 1 test in 0 suites passed.\n")
        for failure in [
            (0, "warning: No matching test cases were run\n"),
            (1, "Process exited with unexpected signal code 11\n"),
            (1, "Test process exceeded 180 seconds.\n"),
            (1, "Test run with 1 test failed.\n"),
        ]:
            with self.subTest(failure=failure):
                code, executions = self.execute([passed, failure, passed])
                self.assertEqual(code, 1)
                self.assertEqual(executions.call_count, 3)
                self.assertIn("window", executions.call_args_list[-1].args[0][-1])

    def test_failed_test_process_fails_run(self):
        code, _ = self.execute([(1, "Test run with 1 test failed.\n")], "BrowseTests.window()\n")
        self.assertEqual(code, 1)

    def test_duplicate_function_names_rejected(self):
        code, executions = self.execute([], "BrowseCoreTests.window()\nBrowseTests.window()\n")
        self.assertEqual(code, 1)
        executions.assert_not_called()

    def test_timeout_terminates_process(self):
        code, output = runner.run([sys.executable, "-c", "import time; time.sleep(10)"], timeout=0.05)
        self.assertEqual(code, 1)
        self.assertIn("exceeded", output)


if __name__ == "__main__":
    unittest.main()
