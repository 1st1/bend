"""Exercise first-run provisioning and reuse without a host restore or sudo."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("runner", Path(__file__).with_name("test-vm.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.guests = {}
        self.calls = []
        self.primary, self.secondary = runner.WORKERS
        tmp = self.enter_temp()
        self.mock("STATE", Path(tmp))
        self.mock("vm_info", lambda _, name: self.guests.get(name))
        self.mock("provision", lambda *args: True)
        self.mock("boot", self.boot)
        self.mock("tool", lambda *args: "tart")
        self.mock("snapshot", lambda *args: None)
        self.mock("sparkle_archive", lambda *args: None)
        self.mock("sync", lambda *args: None)
        self.mock("remote", lambda ip, *args: ["ssh", ip, *args])
        self.mock("build_archive", lambda *_: Path(tmp) / "archive")
        self.mock("prepare_build", lambda addresses, archive: self.calls.append(("prepare", *addresses)))
        self.mock("run_shards", lambda addresses, args=(), **kw: self.calls.append(("shards", *addresses, *args)))
        p = patch.object(subprocess, "run", self.command)
        p.start()
        self.addCleanup(p.stop)

    def enter_temp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return tmp.name

    def mock(self, name, value):
        p = patch.object(runner, name, value)
        p.start()
        self.addCleanup(p.stop)

    def boot(self, _, name, boots, managed):
        self.assertIn(name, self.guests)
        self.guests[name]["Running"] = True
        self.calls.append(("ready", name))
        return name

    def command(self, args, **kwargs):
        self.calls.append(tuple(args))
        if args[:2] == ["tart", "create"]:
            self.guests[args[-1]] = {"Running": False}
        elif args[:2] == ["tart", "stop"]:
            self.guests[args[-1]]["Running"] = False
        elif args[:2] == ["tart", "clone"]:
            self.assertEqual(args[-2], runner.BASE)
            self.assertFalse(self.guests[args[-2]]["Running"])
            self.assertNotIn(args[-1], self.guests)
            self.guests[args[-1]] = {"Running": False}
        elif args[:2] == ["tart", "rename"]:
            self.assertIn(("ready", runner.VM), self.calls)
            self.guests[args[-1]] = self.guests.pop(args[-2])
        elif args[:2] == ["tart", "delete"]:
            self.assertFalse(self.guests.pop(args[-1])["Running"])
        return subprocess.CompletedProcess(args, 0)

    def test_plain_and_filtered_then_add_shard(self):
        runner.main([])
        self.assertEqual(self.guests, {runner.BASE: {"Running": False}})
        self.assertIn(("shards", self.primary), self.calls)
        runner.main(["--filter", "window"])
        self.assertIn(("shards", self.primary, "--filter", "window"), self.calls)
        runner.main(["--jobs", "2"])
        self.assertIn(("shards", self.primary, self.secondary), self.calls)
        runner.main(["--jobs", "2"])
        self.assertEqual(sum(c[:2] == ("tart", "create") for c in self.calls), 1)
        self.assertEqual(sum(c[:2] == ("tart", "clone") for c in self.calls), 6)

    def test_cold_parallel_and_prepare_only(self):
        runner.main(["--jobs", "2"])
        self.assertIn(("shards", self.primary, self.secondary), self.calls)
        self.calls.clear()
        runner.main(["setup", "--jobs", "2"])
        self.assertFalse(any(c[0] in ("shards", "ssh") for c in self.calls))

    def test_interrupt_and_failures_discard_both_workers(self):
        for error in (KeyboardInterrupt(), subprocess.CalledProcessError(1, "ssh")):
            with patch.object(runner, "run_shards", side_effect=error):
                with self.assertRaises((SystemExit, subprocess.CalledProcessError)):
                    runner.main(["--jobs", "2"])
            self.assertEqual(self.guests, {runner.BASE: {"Running": False}})

    def test_wipe_only_targets_bend_guests(self):
        inventory = [{"Name": name, "Source": source, "Running": running} for name, source, running in (
            (self.primary, "local", True), (self.secondary, "local", False),
            ("personal", "local", True), ("cached-image", "OCI", False))]
        self.guests[self.primary] = {"Running": True}
        self.guests[self.secondary] = {"Running": False}
        (runner.STATE / "seeded").touch()
        log = runner.STATE / "shard-1.log"
        log.touch()
        with patch.object(subprocess, "check_output", return_value=json.dumps(inventory)), \
                patch.object(runner.sys, "stdin") as terminal:
            terminal.isatty.return_value = True
            terminal.readline.side_effect = ["1 3\n", "\n", "1\n", "yes\n"]
            runner.main(["wipe"])
            self.assertFalse(self.calls)
            self.assertTrue((runner.STATE / "seeded").exists())
            runner.main(["wipe"])
        self.assertEqual(self.calls, [("tart", "stop", self.primary), ("tart", "delete", self.primary),
                                      ("tart", "delete", self.secondary)])
        self.assertFalse((runner.STATE / "seeded").exists())
        self.assertTrue(log.exists())

    def test_wipe_image_only_preserves_other_downloads_and_state(self):
        cache = runner.STATE / "cache/IPSWs"
        cache.mkdir(parents=True)
        target = cache / runner.IPSW_CACHE_NAME
        other = cache / "other.ipsw"
        for path in (target, other, runner.STATE / "seeded"):
            path.touch()
        with patch.dict(runner.os.environ, TART_HOME=str(runner.STATE)), \
                patch.object(subprocess, "check_output", return_value="[]"), \
                patch.object(runner.sys, "stdin") as terminal:
            terminal.isatty.return_value = True
            terminal.readline.side_effect = ["2\n", "y\n"]
            runner.main(["wipe"])
        self.assertFalse(target.exists())
        self.assertTrue(other.exists())
        self.assertTrue((runner.STATE / "seeded").exists())
        self.assertFalse(self.calls)


class BuildCacheTests(unittest.TestCase):
    def test_archive_transfer_preserves_last_good_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp) / "worker-1"
            build = project / ".build"
            build.mkdir(parents=True)
            (build / "test-binary").write_bytes(b"finished build")
            (build / "debug").symlink_to("test-binary")
            archive = Path(tmp) / "cache" / "saved.tar.gz"
            with patch.object(runner, "GUEST_DIR", str(project)), \
                    patch.object(runner, "remote", lambda ip, *cmd: list(cmd)):
                runner.save_build("first", archive)
            with patch.object(runner, "remote", lambda *args: ["/usr/bin/false"]):
                with self.assertRaises(subprocess.CalledProcessError):
                    runner.save_build("first", archive)
            for vm in ("worker-2", "worker-3"):
                destination = Path(tmp) / vm
                destination.mkdir()
                with patch.object(runner, "GUEST_DIR", str(destination)), \
                        patch.object(runner, "remote", lambda ip, *cmd: list(cmd)):
                    runner.restore_build(vm, archive)
                self.assertTrue((destination / ".build/debug").is_symlink())
                self.assertEqual((destination / ".build/debug").read_bytes(), b"finished build")
                (destination / ".build/test-binary").write_bytes(b"worker modifications")

    def test_build_once_restore_then_rebuild_changed_sources(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp) / "project"
            (project / "scripts").mkdir(parents=True)
            for name in ("Package.swift", "Package.resolved", "scripts/test.sh", "source.swift"):
                (project / name).touch()
            workers = dict(zip(runner.WORKERS, ("ip1", "ip2")))
            with patch.object(runner, "STATE", Path(tmp)), patch.object(runner, "run_shards") as build, \
                    patch.object(runner, "restore_build") as restore, patch.object(runner, "save_build") as save:
                def archive():
                    return runner.build_archive({"MACAddress": "baseline"}, project)
                first = archive()
                runner.prepare_build(workers, first)
                build.assert_called_once_with({runner.WORKERS[0]: "ip1"}, ["list"], build=True)
                save.assert_called_once_with("ip1", first)
                restore.assert_called_once_with("ip2", first)
                first.parent.mkdir()
                first.touch()
                restore.reset_mock()
                runner.prepare_build(workers, archive())
                self.assertEqual([c.args for c in restore.call_args_list], [("ip1", first), ("ip2", first)])
                self.assertEqual(build.call_count, 1)
                (project / "source.swift").write_text("changed")
                second = archive()
                self.assertNotEqual(first, second)
                restore.reset_mock()
                runner.prepare_build(workers, second)
                self.assertEqual([c.args for c in restore.call_args_list], [("ip1", first), ("ip2", second)])
                self.assertEqual(build.call_count, 2)


class WatchdogTests(unittest.TestCase):
    def run_workers(self, programs, idle=2, wall=5):
        def local_command(ip, *args):
            if "probe" in args:
                return list(args)
            return [sys.executable, "-u", "-c", programs[ip]]

        with tempfile.TemporaryDirectory() as tmp, patch.object(runner, "STATE", Path(tmp)), \
                patch.object(runner, "remote", local_command), patch.object(runner, "curses", None), \
                patch.object(runner, "QUIET_PROBE", 0.1), patch.object(runner, "IDLE_LIMIT", idle), \
                patch.object(runner, "WALL_LIMIT", wall), self.assertRaises(SystemExit) as result:
            try:
                runner.run_shards({name: name for name in programs})
            finally:
                logs = [p.read_text() for p in sorted(Path(tmp).glob("shard-*.log"))]
        self.assertEqual(result.exception.code, 124)
        return logs

    def test_stale_transport_and_quiet_healthy_peer(self):
        logs = self.run_workers({
            "stale": "import time; print('BEND_VM_TEST_PID=2147483647'); time.sleep(60)",
            "healthy": "import os,time; print(f'BEND_VM_TEST_PID={os.getpid()}'); time.sleep(.7); print('finished')",
        })
        self.assertIn("process disappeared", logs[0])
        self.assertIn("process still present", logs[1])
        self.assertIn("finished", logs[1])

    def test_eof_without_exit_and_chatty_hang(self):
        logs = self.run_workers({
            "silent": "import os,time; os.close(1); os.close(2); time.sleep(60)",
            "chatty": "import time\nwhile True: print('busy'); time.sleep(.03)",
        }, idle=.4, wall=1)
        self.assertIn("no output", logs[0])
        self.assertIn("wall time", logs[1])


if __name__ == "__main__":
    unittest.main()
