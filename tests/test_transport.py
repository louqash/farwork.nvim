"""Bounded SSH execution with the project's environment, without network access."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from transport import run_ssh

class Transport(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        ssh = self.root / 'ssh'
        ssh.write_text('#!/bin/bash\nexec bash -c "${!#}"\n')
        ssh.chmod(0o700)
        self.env = patch.dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ['PATH'])
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_environment_and_quoting(self):
        result = run_ssh('fixture', 'python3 -c "import os; print(os.environ[\'FARWORK_TEST\'])"',
                         environment="export FARWORK_TEST='spaces and quotes'", input=b'')
        self.assertEqual(result.stdout, b'spaces and quotes\n')

    def test_timeout(self):
        with patch.dict(os.environ, FARWORK_TIMEOUT='0.2'):
            start = time.monotonic()
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                run_ssh('fixture', 'sleep 30')
            self.assertLess(time.monotonic() - start, 3)

    def test_cancel_terminates_ssh(self):
        marker = self.root / 'started'
        command = 'sleep 30'
        code = ('from transport import run_ssh; run_ssh("fixture", %r, environment=%r)' %
                (command, 'echo ready > ' + str(marker)))
        proc = subprocess.Popen([sys.executable, '-c', code], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={**os.environ, 'PYTHONPATH': str(Path(__file__).resolve().parents[1] / 'scripts')})
        try:
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline: time.sleep(0.02)
            self.assertTrue(marker.exists())
            proc.send_signal(signal.SIGTERM)
            _, errors = proc.communicate(timeout=3)
            self.assertIn(b'cancelled', errors)
            self.assertNotEqual(proc.returncode, 0)
        finally:
            if proc.poll() is None: proc.kill(); proc.communicate()

if __name__ == '__main__': unittest.main()
