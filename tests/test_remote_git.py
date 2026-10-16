"""Real Git fixtures; no network or user repositories."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import os
import json
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("remote_git", Path(__file__).resolve().parents[1] / "scripts/remote_git.py")
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class GitSyncTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.local, self.remote = self.base / "local", self.base / "remote"
        self.local.mkdir()
        sync.git(self.local, "init", "-b", "topic")
        sync.git(self.local, "config", "user.name", "Fixture")
        sync.git(self.local, "config", "user.email", "fixture@example.invalid")
        (self.local / "source").write_text("baseline")
        (self.local / ".gitignore").write_text("ignored\n")
        self.commit("baseline")
        subprocess.run(["git", "clone", str(self.local), str(self.remote)], check=True, capture_output=True)
        sync.git(self.remote, "config", "user.name", "Fixture")
        sync.git(self.remote, "config", "user.email", "fixture@example.invalid")

    def commit(self, message):
        sync.git(self.local, "add", "-A")
        sync.git(self.local, "-c", "commit.gpgsign=false", "commit", "-m", message)

    def check_upload(self, mode="check"):
        shim = self.base / "bin"
        shim.mkdir(exist_ok=True)
        ssh = shim / "ssh"
        ssh.write_text('#!/bin/bash\nexec bash -c "${!#}"\n')
        ssh.chmod(0o700)
        return subprocess.run([sys.executable, sync.__file__, mode, str(self.local),
                               "fixture-only", str(self.remote)], capture_output=True, text=True,
                              env={**os.environ, "PATH": str(shim) + os.pathsep + os.environ["PATH"]})

    def assert_preserved(self):
        self.assertEqual((self.remote / ".venv/bin/activate").read_text(), "remote venv")
        self.assertEqual((self.remote / "source").read_text(), "remote edits")
        self.assertEqual(sync.git(self.remote, "stash", "list").stdout, b"")

    def create_remote_work(self):
        (self.remote / ".venv/bin").mkdir(parents=True)
        (self.remote / ".venv/bin/activate").write_text("remote venv")
        (self.remote / "source").write_text("remote edits")

    def test_matching_history_allows_upload_without_mutation(self):
        self.create_remote_work()
        result = self.check_upload()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)["changed"])
        self.assert_preserved()

    def test_rewritten_history_pauses_without_mutation(self):
        self.create_remote_work()
        previous = sync.identity(self.remote)
        (self.local / "source").write_text("rebased source")
        sync.git(self.local, "add", "source")
        sync.git(self.local, "-c", "commit.gpgsign=false", "commit", "--amend", "-m", "rebased")
        result = self.check_upload()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Git history differ", result.stderr)
        self.assertEqual(sync.identity(self.remote), previous)
        self.assert_preserved()

    def test_remote_branch_switch_is_detected(self):
        sync.git(self.remote, "checkout", "-b", "remote-only")
        self.assertNotEqual(self.check_upload().returncode, 0)

    def test_rebase_in_progress_pauses_sync(self):
        (self.local / ".git/rebase-merge").mkdir()
        with self.assertRaises(RuntimeError):
            sync.identity(self.local)

    def test_verified_commit_advances_metadata_preserves_venv(self):
        self.create_remote_work()
        (self.local / "source").write_text("remote edits")
        self.commit("uploaded changes")
        previous = sync.identity(self.remote)
        result = self.check_upload("check-commit")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["changed"])
        self.assertEqual(sync.identity(self.local), sync.identity(self.remote))
        self.assert_preserved()
        self.assertEqual(sync.git(self.remote, "diff", "--cached", "--name-only").stdout, b"")
        backups = sync.git(self.remote, "for-each-ref", "--format=%(objectname)", "refs/nvim/backups/").stdout.decode()
        self.assertIn(previous["head"], backups)
        self.assertFalse((self.remote / ".git/index.lock").exists())

    def test_commit_refuses_different_remote_content(self):
        self.create_remote_work()
        previous = sync.identity(self.remote)
        (self.local / "source").write_text("different edit")
        self.commit("different")
        result = self.check_upload("check-commit")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("do not exactly match", result.stderr)
        self.assertEqual(sync.identity(self.remote), previous)
        self.assert_preserved()
        self.assertFalse((self.remote / ".git/index.lock").exists())

    def test_commit_refuses_remote_staging(self):
        self.create_remote_work()
        sync.git(self.remote, "add", "source")
        previous = sync.identity(self.remote)
        index = sync.git(self.remote, "write-tree").stdout
        (self.local / "source").write_text("remote edits")
        self.commit("same staged content")
        result = self.check_upload("check-commit")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("staged changes", result.stderr)
        self.assertEqual(sync.identity(self.remote), previous)
        self.assertEqual(sync.git(self.remote, "write-tree").stdout, index)
        self.assert_preserved()

    def test_commit_refuses_rewritten_history(self):
        self.create_remote_work()
        previous = sync.identity(self.remote)
        (self.local / "source").write_text("remote edits")
        sync.git(self.local, "add", "source")
        sync.git(self.local, "-c", "commit.gpgsign=false", "commit", "--amend", "-m", "rewrite")
        self.assertNotEqual(self.check_upload("check-commit").returncode, 0)
        self.assertEqual(sync.identity(self.remote), previous)
        self.assert_preserved()

    def test_commit_refuses_remote_lock(self):
        (self.local / "source").write_text("uploaded")
        (self.remote / "source").write_text("uploaded")
        self.commit("uploaded")
        lock = self.remote / ".git/index.lock"
        lock.write_text("another Git process")
        result = self.check_upload("check-commit")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(lock.read_text(), "another Git process")

    def test_commit_refuses_deleted_paths(self):
        previous = sync.identity(self.remote)
        (self.local / "source").unlink()
        self.commit("delete source")
        self.assertNotEqual(self.check_upload("check-commit").returncode, 0)
        self.assertEqual(sync.identity(self.remote), previous)
        self.assertEqual((self.remote / "source").read_text(), "baseline")

    def test_old_receive_mode_cannot_mutate(self):
        self.create_remote_work()
        result = subprocess.run([sys.executable, sync.__file__, "receive", str(self.remote), "{}"],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("only checks Git history", result.stderr)
        self.assert_preserved()

    def test_old_send_mode_is_read_only(self):
        self.create_remote_work()
        self.assertEqual(self.check_upload("send").returncode, 0)
        self.assert_preserved()


if __name__ == "__main__":
    unittest.main()
