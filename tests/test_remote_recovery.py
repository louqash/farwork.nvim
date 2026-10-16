import importlib.util
import os
import json
import sys
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('recovery', Path(__file__).resolve().parents[1] / 'scripts/remote_recovery.py')
r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)

class Recovery(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name); self.local = self.base / 'local'; self.remote = self.base / 'remote'
        self.local.mkdir(); r.git(self.local, 'init', '-b', 'topic')
        r.git(self.local, 'config', 'user.name', 'Test'); r.git(self.local, 'config', 'user.email', 'test@localhost')
        for name in ('a', 'b'): (self.local/name).write_text('old\n')
        self.commit(); subprocess.run(['git', 'clone', str(self.local), str(self.remote)], check=True, capture_output=True)
        (self.remote/'.venv').mkdir(); (self.remote/'.venv/precious').write_text('keep venv')
        (self.remote/'build').mkdir(); (self.remote/'build/precious').write_text('keep build')
        self.old = r.identity(self.remote)
    def commit(self, amend=False):
        r.git(self.local, 'add', '-A')
        r.git(self.local, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'test', *(['--amend'] if amend else []))
    def pack(self, wanted):
        return r.git(self.local, 'pack-objects', '--revs', '--stdout', data=(wanted['target']['head']+'\n^'+self.old['head']+'\n').encode()).stdout
    def preserved(self):
        self.assertEqual((self.remote/'.venv/precious').read_text(), 'keep venv')
        self.assertEqual((self.remote/'build/precious').read_text(), 'keep build')
        self.assertFalse((self.remote/'.git/index.lock').exists())
    def test_pending_uploads_after_commit(self):
        for name in ('a','b'): (self.local/name).write_text('new\n')
        (self.remote/'a').write_text('new\n'); self.commit()
        wanted = r.request(self.local); plan = r.preview(self.remote,wanted)
        self.assertTrue(plan['allowed']); self.assertEqual([p['state'] for p in plan['paths']], ['already_uploaded','pending_upload'])
        result = r.repair(self.remote,wanted,plan,self.pack(wanted))
        self.assertEqual(r.identity(self.remote),wanted['target'])
        self.assertEqual((self.remote/'b').read_text(),'new\n')
        self.assertEqual(r.git(self.remote,'rev-parse',result['backup']+'/head').stdout.decode().strip(),self.old['head'])
        self.preserved()
    def test_clean_rebase(self):
        (self.local/'a').write_text('rebased\n'); self.commit(amend=True)
        wanted=r.request(self.local); plan=r.preview(self.remote,wanted)
        self.assertTrue(plan['allowed']); r.repair(self.remote,wanted,plan,self.pack(wanted))
        self.assertEqual(r.identity(self.remote),wanted['target']); self.preserved()
    def test_remote_conflict_blocked(self):
        (self.local/'a').write_text('local\n'); self.commit(); (self.remote/'a').write_text('remote\n')
        plan=r.preview(self.remote,r.request(self.local)); self.assertFalse(plan['allowed'])
        self.assertIn('Remote-only', '\n'.join(plan['reasons'])); self.assertEqual(r.identity(self.remote),self.old); self.preserved()
    def test_remote_staging_blocked(self):
        (self.local/'a').write_text('same\n'); self.commit(); (self.remote/'a').write_text('same\n'); r.git(self.remote,'add','a')
        plan=r.preview(self.remote,r.request(self.local)); self.assertFalse(plan['allowed']); self.assertIn('staged',str(plan['reasons'])); self.preserved()
    def test_new_edits_invalidate_review(self):
        (self.local/'a').write_text('new\n'); self.commit(); wanted=r.request(self.local); plan=r.preview(self.remote,wanted)
        (self.remote/'a').write_text('concurrent\n')
        with self.assertRaisesRegex(RuntimeError,'plan changed'): r.repair(self.remote,wanted,plan,self.pack(wanted))
        self.assertEqual((self.remote/'a').read_text(),'concurrent\n'); self.assertEqual(r.identity(self.remote),self.old); self.preserved()
    def test_additions_and_deletions_require_review(self):
        (self.local/'a').unlink(); (self.local/'new').write_text('new'); self.commit()
        self.assertFalse(r.preview(self.remote,r.request(self.local))['allowed']); self.preserved()
    def test_local_uncommitted_work_blocks(self):
        (self.local/'a').write_text('unsaved commit\n')
        self.assertFalse(r.preview(self.remote,r.request(self.local))['allowed'])
    def test_external_symlink_is_not_followed(self):
        (self.local/'a').write_text('new'); self.commit(); (self.remote/'a').unlink(); (self.remote/'a').symlink_to(self.remote/'.venv/precious')
        self.assertFalse(r.preview(self.remote,r.request(self.local))['allowed']); self.preserved()
    def test_command_roundtrip_and_stale_local_plan(self):
        (self.local/'a').write_text('new'); self.commit()
        shim=self.base/'bin'; shim.mkdir(); ssh=shim/'ssh'
        ssh.write_text('#!/bin/bash\nexec bash -c "${!#}"\n'); ssh.chmod(0o700)
        environment={**os.environ,'PATH':str(shim)+os.pathsep+os.environ['PATH']}
        plan=self.base/'plan.json'
        def command(mode):
            return subprocess.run([sys.executable,r.__file__,mode,str(self.local),'test',str(self.remote),str(plan)],
                                  env=environment,capture_output=True,text=True)
        inspected=command('diagnose'); self.assertEqual(inspected.returncode,0,inspected.stderr)
        self.assertTrue(json.loads(inspected.stdout)['allowed']); self.assertEqual(r.identity(self.remote),self.old)
        (self.local/'a').write_text('concurrent edit')
        blocked=command('apply'); self.assertNotEqual(blocked.returncode,0); self.assertEqual(r.identity(self.remote),self.old)
        (self.local/'a').write_text('new')
        repaired=command('apply'); self.assertEqual(repaired.returncode,0,repaired.stderr)
        self.assertEqual(r.identity(self.remote),r.identity(self.local)); self.preserved()

    def test_protected_tracked_build_file(self):
        for root in (self.local,self.remote): (root/'build').mkdir(exist_ok=True); (root/'build/tracked').write_text('old')
        # Seed both histories with the tracked artifact, then change it locally.
        self.commit(); r.git(self.remote,'fetch',str(self.local),'topic'); r.git(self.remote,'reset','--mixed','FETCH_HEAD')
        (self.local/'build/tracked').write_text('new'); self.commit()
        self.assertFalse(r.preview(self.remote,r.request(self.local))['allowed']); self.preserved()

if __name__=='__main__': unittest.main()
