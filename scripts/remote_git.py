"""Git upload guard with opt-in verified metadata-only fast-forward."""
import os
import tempfile
import time
import json
import shlex
import subprocess
import sys
from pathlib import Path


def git(root, *args, check=True, env=None, input=None):
    return subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-C", str(root), *args], check=check,
                          env={**os.environ, "GIT_OPTIONAL_LOCKS": "0", **(env or {})}, input=input,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def identity(root):
    for marker in ("rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "index.lock"):
        path = git(root, "rev-parse", "--git-path", marker).stdout.decode().strip()
        if (Path(root) / path).exists():
            raise RuntimeError("Finish the Git operation before syncing: " + marker)
    head = git(root, "rev-parse", "HEAD").stdout.decode().strip()
    branch = git(root, "symbolic-ref", "--quiet", "--short", "HEAD", check=False).stdout.decode().strip()
    return {"head": head, "branch": branch}


def advance(root, expected, desired, pack):
    if identity(root) != expected:
        raise RuntimeError("Remote history changed; retry")
    if not expected['branch'] or expected['branch'] != desired['branch']:
        raise RuntimeError("Branch mismatch; automatic commit alignment refused")
    git(root, 'unpack-objects', '-q', input=pack)
    if git(root, 'merge-base', '--is-ancestor', expected['head'], desired['head'], check=False).returncode:
        raise RuntimeError("Rewritten/divergent history; automatic commit alignment refused")
    if git(root, 'diff', '--name-only', '--no-renames', '--diff-filter=D', expected['head'], desired['head']).stdout:
        raise RuntimeError("Commit removes paths; automatic alignment requires manual review")
    index_path = Path(root) / git(root, 'rev-parse', '--git-path', 'index').stdout.decode().strip()
    index_path = index_path.resolve()
    lock_path = Path(str(index_path) + '.lock')
    # Respect Git's index lock throughout validation and the metadata transition.
    lock = lock_path.open('xb')
    lock_owned = True
    temp_index = None
    advanced = False
    branch = 'refs/heads/' + desired['branch']
    try:
        fd, temp_index = tempfile.mkstemp(prefix='nvim-index-', dir=index_path.parent)
        os.close(fd)
        os.unlink(temp_index)
        env = {'GIT_INDEX_FILE': temp_index}
        if git(root, 'diff', '--cached', '--quiet', check=False).returncode:
            raise RuntimeError("Remote staged changes; automatic commit alignment refused")
        git(root, 'read-tree', desired['head'], env=env)  # No -u: never writes working files.
        git(root, 'update-index', '--refresh', env=env, check=False)
        if git(root, 'diff-files', '--quiet', '--no-ext-diff', '--ignore-submodules=none', env=env, check=False).returncode:
            raise RuntimeError("Remote tracked files do not exactly match the local commit. "
                               "Automatic alignment refused; working files and venv are unchanged.")
        actual = {'head': git(root, 'rev-parse', 'HEAD').stdout.decode().strip(),
                  'branch': git(root, 'symbolic-ref', '--short', 'HEAD').stdout.decode().strip()}
        if actual != expected:
            raise RuntimeError("Remote branch changed during alignment; retry")
        lock.write(Path(temp_index).read_bytes())
        lock.flush()
        os.fsync(lock.fileno())
        backup = 'refs/nvim/backups/commit-' + str(time.time_ns())
        transaction = ('create %s %s\nupdate %s %s %s\n' %
                       (backup, expected['head'], branch, desired['head'], expected['head']))
        git(root, 'update-ref', '--stdin', input=transaction.encode())
        advanced = True
        os.replace(lock_path, index_path)
        lock_owned = False
    except Exception:
        if advanced:
            git(root, 'update-ref', branch, expected['head'], desired['head'])
        raise
    finally:
        lock.close()
        if lock_owned and lock_path.exists(): lock_path.unlink()
        if temp_index and Path(temp_index).exists(): Path(temp_index).unlink()


def ssh(host, source, mode, root, *args, input=None, environment=""):
    from transport import run_ssh
    command = 'python3 -c ' + shlex.quote(source) + ' ' + mode + ' ' + shlex.quote(root)
    for arg in args: command += ' ' + shlex.quote(json.dumps(arg))
    return run_ssh(host, command, environment=environment, input=input)


def main():
    mode, root = sys.argv[1:3]
    if mode == 'advance':
        advance(root, json.loads(sys.argv[3]), json.loads(sys.argv[4]), sys.stdin.buffer.read())
        print(json.dumps({'advanced': True}))
        return
    if mode not in ("identity", "check", "send", "check-commit"):
        raise RuntimeError("Unsupported operation; legacy mode only checks Git history.")
    desired = identity(root)
    if mode == "identity":
        print(json.dumps(desired))
        return
    host, remote = sys.argv[3:5]
    environment = sys.argv[5] if len(sys.argv) > 5 else ""
    source = Path(__file__).read_text()
    current = json.loads(ssh(host, source, 'identity', remote, environment=environment).stdout)
    changed = False
    if current != desired:
        if mode != 'check-commit':
            raise RuntimeError("Local and remote Git history differ. Uploads paused; "
                               "enable git.auto_fast_forward for verified fast-forward commits. No working files were changed.")
        if not current['branch'] or current['branch'] != desired['branch']:
            raise RuntimeError("Branch mismatch; automatic commit alignment refused")
        if git(root, 'merge-base', '--is-ancestor', current['head'], desired['head'], check=False).returncode:
            raise RuntimeError("Rewritten/divergent history; automatic commit alignment refused")
        pack = git(root, 'pack-objects', '--revs', '--stdout',
                   input=(desired['head'] + '\n^' + current['head'] + '\n').encode()).stdout
        if identity(root) != desired: raise RuntimeError('Local history changed; retry')
        ssh(host, source, 'advance', remote, current, desired, input=pack, environment=environment)
        changed = True
    if identity(root) != desired:
        raise RuntimeError("Local Git history changed during the check; retry.")
    print(json.dumps({"changed": changed, "identity": desired}))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(error.stderr.decode() if isinstance(error, subprocess.CalledProcessError) else str(error), file=sys.stderr)
        sys.exit(1)
