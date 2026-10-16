import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('remote_check', Path(__file__).resolve().parents[1] / 'scripts/remote_check.py')
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

class Checks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.root = self.base / 'repo'
        self.root.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@localhost')
        (self.root / 'code.cpp').write_text('before\n')
        (self.root / '.gitattributes').write_text('code.cpp export-ignore\n')
        self.git('add', '.')
        self.git('-c', 'commit.gpgsign=false', 'commit', '-qm', 'base')
        (self.root / 'code.cpp').write_text('staged   \n')
        self.git('add', 'code.cpp')
        self.output = self.base / 'results'
        self.output.mkdir()
        self.tree = self.git('write-tree').strip()
    def tearDown(self): self.temp.cleanup()
    def git(self, *args): return check.git(self.root, *args).decode()
    def result(self):
        command = ['python3', '-c', "from pathlib import Path; p=Path('code.cpp'); assert p.read_text()=='staged   \\n'; p.write_text('staged\\n'); print('formatted'); raise SystemExit(1)"]
        data = check.remote(dict(archive=check.encode(check.snapshot(self.root, self.tree)),
                                 files=['code.cpp'], all=False, command=command))
        data['tree'] = self.tree
        (self.output / 'result.json').write_text(json.dumps(data))
        return data
    def test_format_return_preserves_index_and_venv(self):
        (self.root / '.venv').mkdir()
        (self.root / '.venv/token').write_text('preserve')
        data = self.result()
        self.assertEqual(data['code'], 1)
        self.assertEqual(len(data['changes']), 1)
        check.apply(str(self.root), str(self.output))
        self.assertEqual((self.root / 'code.cpp').read_text(), 'staged\n')
        self.assertEqual(self.git('write-tree').strip(), self.tree)
        self.assertEqual((self.root / '.venv/token').read_text(), 'preserve')
    def test_concurrent_local_edit_preserved(self):
        self.result()
        (self.root / 'code.cpp').write_text('new edit\n')
        with self.assertRaisesRegex(RuntimeError, 'differs'): check.apply(str(self.root), str(self.output))
        self.assertEqual((self.root / 'code.cpp').read_text(), 'new edit\n')
    def test_partial_staging_preserved(self):
        (self.root / 'code.cpp').write_text('unstaged hunk\n')
        self.result()
        with self.assertRaisesRegex(RuntimeError, 'differs'): check.apply(str(self.root), str(self.output))
    def test_changed_index_blocks_apply(self):
        self.result()
        (self.root / 'other').write_text('new')
        self.git('add', 'other')
        with self.assertRaisesRegex(RuntimeError, 'Staging changed'): check.apply(str(self.root), str(self.output))
    def test_ssh_roundtrip_and_saved_fixes(self):
        binary = self.base / 'bin'; binary.mkdir()
        ssh = binary / 'ssh'
        ssh.write_text('#!/usr/bin/env python3\nimport subprocess,sys\nsys.exit(subprocess.call(sys.argv[-1], shell=True))\n')
        ssh.chmod(0o755)
        previous = os.environ['PATH']; os.environ['PATH'] = str(binary) + os.pathsep + previous
        try:
            check.run(str(self.root), 'test', 'export CHECK_VENV=active', str(self.output), False,
                      ['python3', '-c', "import os; from pathlib import Path; assert os.environ['CHECK_VENV']=='active'; Path('code.cpp').write_text('fixed\\n')"])
        finally: os.environ['PATH'] = previous
        self.assertEqual((self.output / 'after/code.cpp').read_text(), 'fixed\n')
        self.assertEqual((self.root / 'code.cpp').read_text(), 'staged   \n')
    def test_symlink_and_traversal_rejected(self):
        for name in ('../oops', '/tmp/oops', '.git/config'):
            with self.assertRaises(RuntimeError): check.safe_path(self.root, name)
        (self.root / 'link').symlink_to(self.base)
        with self.assertRaises(RuntimeError): check.safe_path(self.root, 'link/oops')

if __name__ == '__main__': unittest.main()
