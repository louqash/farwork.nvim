"""Reviewed Git recovery. Only replaces tracked regular files proven old or desired."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time


def git(root, *args, env=None, check=True, data=None):
    p = subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-C', str(root), *args],
                       env={**os.environ, 'GIT_OPTIONAL_LOCKS': '0', **(env or {})},
                       input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and p.returncode:
        raise RuntimeError(p.stderr.decode(errors='replace') or 'Git refused: ' + ' '.join(args))
    return p


def identity(root, own_lock=False):
    for marker in ('rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'index.lock'):
        if own_lock and marker == 'index.lock': continue
        path = Path(root) / git(root, 'rev-parse', '--git-path', marker).stdout.decode().strip()
        if path.exists():
            raise RuntimeError('Finish the Git operation first (' + marker + '). Run git status in ' + str(root))
    return dict(head=git(root, 'rev-parse', 'HEAD').stdout.decode().strip(),
                branch=git(root, 'symbolic-ref', '--quiet', '--short', 'HEAD', check=False).stdout.decode().strip())


def tree(root, rev):
    entries = {}
    for record in git(root, 'ls-tree', '-rz', rev).stdout.split(b'\0'):
        if not record: continue
        meta, path = record.split(b'\t', 1)
        mode, kind, oid = meta.decode().split()
        entries[path.decode()] = dict(mode=mode, oid=oid, kind=kind)
    return entries


def safe_file(root, name):
    path = Path(name)
    if path.is_absolute() or '..' in path.parts or not path.parts:
        raise RuntimeError('Unsafe path: ' + name)
    if path.parts[0] == 'build' or any(part in ('.git', '.venv', 'venv', 'node_modules', '__pycache__')
                                      or part.startswith('.env') for part in path.parts):
        raise RuntimeError('Protected environment/build path: ' + name)
    target = Path(root).resolve() / path
    if target.resolve() != target:
        raise RuntimeError('Symlinked path requires manual review: ' + name)
    return target


def work_entry(root, name, algorithm):
    path = safe_file(root, name)
    if not path.is_file(): return None
    data = path.read_bytes()
    digest = hashlib.new(algorithm, b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    return dict(mode='100755' if path.stat().st_mode & 0o111 else '100644', oid=digest, kind='blob')


def request(root):
    ident = identity(root)
    return dict(target=ident, tree=tree(root, ident['head']),
                local_clean=git(root, 'diff', '--quiet', 'HEAD', '--', check=False).returncode == 0)


def preview(root, wanted, own_lock=False):
    current = identity(root, own_lock)
    old = tree(root, current['head'])
    desired = wanted['tree']
    reasons, rows = [], []
    if not wanted['local_clean']:
        reasons.append('Local tracked edits are not committed. Finish your local commit, then run :RemoteDoctor again.')
    if not current['branch'] or current['branch'] != wanted['target']['branch']:
        reasons.append('Branches differ or HEAD is detached. Choose the intended branch on each side before recovery.')
    if git(root, 'diff', '--cached', '--quiet', check=False).returncode:
        reasons.append('Remote staged work exists. Review it on the remote with git diff --cached; recovery will not overwrite staging.')
    flags = git(root, 'ls-files', '-v', '-z').stdout.split(b'\0')
    if any(line and line[:1] != b'H' for line in flags):
        reasons.append('Remote index has special flags (sparse/assume-unchanged/unmerged). Resolve these manually first.')
    dirty = set(x.decode() for x in git(root, 'diff', '--name-only', '-z', 'HEAD', '--').stdout.split(b'\0') if x)
    paths = sorted({p for p in set(old) | set(desired) if old.get(p) != desired.get(p)} | dirty)
    algorithm = git(root, 'rev-parse', '--show-object-format').stdout.decode().strip()
    for name in paths:
        before, after = old.get(name), desired.get(name)
        row = dict(path=name, state='blocked')
        try:
            if not before or not after or any(e['mode'] not in ('100644', '100755') for e in (before, after)):
                raise RuntimeError('Added/deleted/renamed paths or non-regular files require manual review: ' + name)
            actual = work_entry(root, name, algorithm)
            row['actual'] = actual
            if actual == after: row['state'] = 'already_uploaded'
            elif actual == before: row['state'] = 'pending_upload'
            else: raise RuntimeError('Remote-only or conflicting edits: ' + name + '. Review with :RemoteDiff; preserve/merge them locally before retrying.')
        except RuntimeError as error:
            reasons.append(str(error))
        rows.append(row)
    report = dict(current=current, target=wanted['target'], paths=rows, reasons=reasons,
                  allowed=not reasons, aligned=current == wanted['target'])
    report['fingerprint'] = hashlib.sha256(json.dumps(report, sort_keys=True).encode()).hexdigest()
    return report


def repair(root, wanted, approved, pack):
    fresh = preview(root, wanted)
    if fresh != approved or not fresh['allowed']:
        raise RuntimeError('The recovery plan changed or is blocked. Run :RemoteDoctor again; nothing was repaired.')
    git(root, 'unpack-objects', '-q', data=pack)
    target = wanted['target']['head']
    if tree(root, target) != wanted['tree']:
        raise RuntimeError('Transferred commit does not match the reviewed plan')
    index = (Path(root) / git(root, 'rev-parse', '--git-path', 'index').stdout.decode().strip()).resolve()
    lock_path = Path(str(index) + '.lock')
    lock = lock_path.open('xb')
    owned, temp_index, backup = True, None, None
    try:
        if preview(root, wanted, own_lock=True) != approved:
            raise RuntimeError('Remote changed before recovery. Run :RemoteDoctor again.')
        fd, temp_index = tempfile.mkstemp(prefix='nvim-recovery-', dir=index.parent)
        os.close(fd); os.unlink(temp_index)
        env = {'GIT_INDEX_FILE': temp_index}
        git(root, 'read-tree', target, env=env)
        backup = 'refs/nvim/backups/recovery-' + str(time.time_ns())
        git(root, 'update-ref', '--stdin', data=(
            'create %s/head %s\ncreate %s/target %s\n' %
            (backup, fresh['current']['head'], backup, target)).encode())
        algorithm = git(root, 'rev-parse', '--show-object-format').stdout.decode().strip()
        for row in fresh['paths']:
            if row['state'] != 'pending_upload': continue
            name = row['path']; path = safe_file(root, name)
            if work_entry(root, name, algorithm) != row['actual']:
                raise RuntimeError('Remote file changed during repair: ' + name)
            data = git(root, 'cat-file', 'blob', wanted['tree'][name]['oid']).stdout
            fd, temporary = tempfile.mkstemp(prefix='.nvim-recovery-', dir=path.parent)
            try:
                with os.fdopen(fd, 'wb') as stream: stream.write(data)
                os.chmod(temporary, 0o755 if wanted['tree'][name]['mode'] == '100755' else 0o644)
                os.replace(temporary, path)
            finally:
                if os.path.exists(temporary): os.unlink(temporary)
        git(root, 'update-index', '--refresh', env=env, check=False)
        if git(root, 'diff-files', '--quiet', '--ignore-submodules=none', env=env, check=False).returncode:
            raise RuntimeError('Remote files changed during repair; history was not advanced')
        if identity(root, own_lock=True) != fresh['current']:
            raise RuntimeError('Remote branch changed during repair')
        lock.write(Path(temp_index).read_bytes()); lock.flush(); os.fsync(lock.fileno())
        branch = 'refs/heads/' + fresh['current']['branch']
        git(root, 'update-ref', branch, target, fresh['current']['head'])
        try:
            os.replace(lock_path, index); owned = False
        except Exception:
            git(root, 'update-ref', branch, fresh['current']['head'], target)
            raise
        return dict(backup=backup, head=target)
    except Exception as error:
        raise RuntimeError(str(error) + ('\nRecovery backup: ' + backup + '. Some verified files may have been updated; run :RemoteDoctor again.' if backup else '')) from error
    finally:
        lock.close()
        if owned and lock_path.exists(): lock_path.unlink()
        if temp_index and Path(temp_index).exists(): Path(temp_index).unlink()


def remote_call(host, mode, root, payload):
    command = 'python3 -c ' + shlex.quote(Path(__file__).read_text()) + ' ' + mode + ' ' + shlex.quote(root)
    result = subprocess.run(['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=30',
                             host, command], input=json.dumps(payload).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors='replace') + '\nIf SSH failed, check the host/workspace connection first; recovery made no further attempts.')
    return json.loads(result.stdout)


def main():
    mode, root = sys.argv[1:3]
    if mode == 'remote-preview':
        print(json.dumps(preview(root, json.load(sys.stdin)))); return
    if mode == 'remote-repair':
        data = json.load(sys.stdin)
        print(json.dumps(repair(root, data['request'], data['report'], base64.b64decode(data['pack'])))); return
    host, remote, plan_file = sys.argv[3:6]
    if mode == 'diagnose':
        wanted = request(root)
        report = remote_call(host, 'remote-preview', remote, wanted)
        if git(root, 'cat-file', '-e', report['current']['head'], check=False).returncode:
            report['allowed'] = False
            report['reasons'].append('Remote commits are missing locally. Fetch and inspect the remote branch first: git fetch '
                                     + shlex.quote(host + ':' + remote) + ' ' + shlex.quote(report['current']['branch'])
                                     + '; then inspect git log FETCH_HEAD and rerun :RemoteDoctor.')
        plan = dict(root=root, host=host, remote=remote, request=wanted, report=report)
        Path(plan_file).write_text(json.dumps(plan))
        print(json.dumps(report))
    elif mode == 'apply':
        plan = json.loads(Path(plan_file).read_text())
        if (root, host, remote) != (plan['root'], plan['host'], plan['remote']) or request(root) != plan['request']:
            raise RuntimeError('Local project changed since review. Run :RemoteDoctor again.')
        old, new = plan['report']['current']['head'], plan['request']['target']['head']
        if git(root, 'cat-file', '-e', old, check=False).returncode:
            raise RuntimeError('Remote history is missing locally. Fetch and review the remote commits before recovery.')
        pack = git(root, 'pack-objects', '--revs', '--stdout', data=(new + '\n^' + old + '\n').encode()).stdout
        result = remote_call(host, 'remote-repair', remote, {**plan, 'pack': base64.b64encode(pack).decode()})
        if request(root) != plan['request']:
            raise RuntimeError('Local project changed during repair. Remote recovery completed, but uploads remain paused; run :RemoteDoctor again.')
        print(json.dumps(result))
    else: raise RuntimeError('Unknown recovery operation')


if __name__ == '__main__':
    try: main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
