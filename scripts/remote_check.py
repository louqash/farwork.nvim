"""Run checks on an isolated staged snapshot; return fixes without touching either index."""
import base64
import io
import json
import os
from pathlib import Path, PurePosixPath
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile


def git(root, *args):
    return subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null', '-C', str(root), *args])


def safe_path(root, name):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or '.git' in path.parts or not path.parts:
        raise RuntimeError('Unsafe check path: ' + name)
    target = Path(root).joinpath(*path.parts)
    for parent in [target, *target.parents]:
        if parent == Path(root):
            break
        if parent.is_symlink():
            raise RuntimeError('Refusing symlink: ' + name)
    return target


def encode(value):
    return base64.b64encode(value).decode() if value is not None else None


def decode(value):
    return base64.b64decode(value, validate=True) if value is not None else None


def remote(request):
    root = Path(tempfile.mkdtemp(prefix='nvim-pre-commit-'))
    try:
        with tarfile.open(fileobj=io.BytesIO(decode(request['archive']))) as archive:
            for member in archive:
                name = member.name.rstrip('/')
                target = safe_path(root, name)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(archive.extractfile(member).read())
                    target.chmod(member.mode & 0o777)
                elif member.issym():
                    # Preserve internal links, but never let hooks follow links out of scratch.
                    resolved = (target.parent / member.linkname).resolve()
                    if not resolved.is_relative_to(root):
                        raise RuntimeError('External symlink in snapshot: ' + name)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.symlink_to(member.linkname)
                else:
                    raise RuntimeError('Unsupported snapshot entry: ' + name)
        before = {}
        links = {}
        for path in root.rglob('*'):
            name = str(path.relative_to(root))
            if path.is_symlink(): links[name] = os.readlink(path)
            elif path.is_file(): before[name] = (path.read_bytes(), (0o755 if path.stat().st_mode & 0o111 else 0o644))
        git(root, 'init', '-q')
        git(root, 'add', '--all')
        git(root, '-c', 'user.name=Remote checks', '-c', 'user.email=remote-check@localhost',
            '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Local staged snapshot', '--allow-empty')
        command = request['command']
        if request.get('args', 'pre-commit') == 'pre-commit':
            command = command + (['--all-files'] if request['all'] else ['--files'] + ['./' + p for p in request['files']])
        print('Running remote checks…', file=sys.stderr, flush=True)
        process = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        chunks = []
        for chunk in iter(process.stdout.readline, b''):
            chunks.append(chunk)
            sys.stderr.buffer.write(chunk)
            sys.stderr.buffer.flush()
        process.stdout.close()
        code = process.wait()
        after_names = set(git(root, 'ls-files', '-z').decode().rstrip('\0').split('\0'))
        after_names.update(git(root, 'ls-files', '--others', '--exclude-standard', '-z').decode().rstrip('\0').split('\0'))
        changes = []
        for name in sorted((set(before) | set(links) | after_names) - {''}):
            if name in links:
                path = root / name
                if not path.is_symlink() or os.readlink(path) != links[name]:
                    raise RuntimeError('Hook changed a symlink: ' + name)
                continue
            path = safe_path(root, name)
            old, old_mode = before.get(name, (None, None))
            new = path.read_bytes() if path.is_file() else None
            new_mode = (0o755 if path.stat().st_mode & 0o111 else 0o644) if new is not None else None
            if old != new or old_mode != new_mode:
                changes.append(dict(path=name, before=encode(old), after=encode(new), mode=new_mode, before_mode=old_mode))
        return dict(code=code, output=b''.join(chunks).decode(errors='replace'), changes=changes)
    finally:
        shutil.rmtree(root)


def snapshot(root, tree):
    entries = []
    for record in git(root, 'ls-tree', '-rz', tree).split(b'\0'):
        if not record: continue
        metadata, name = record.split(b'\t', 1)
        mode, kind, oid = metadata.split()
        if kind != b'blob': raise RuntimeError('Snapshots containing submodules are not supported yet')
        entries.append((mode, oid, name.decode()))
    # Read raw blobs: git archive would silently honor export-ignore/export-subst.
    blobs = subprocess.check_output(['git', '-C', str(root), 'cat-file', '--batch'],
                                    input=b''.join(oid + b'\n' for _, oid, _ in entries))
    stream, output = io.BytesIO(blobs), io.BytesIO()
    with tarfile.open(fileobj=output, mode='w') as archive:
        for mode, oid, name in entries:
            header = stream.readline().split()
            assert header[:2] == [oid, b'blob']
            data = stream.read(int(header[2])); assert stream.read(1) == b'\n'
            member = tarfile.TarInfo(name)
            if mode == b'120000':
                member.type = tarfile.SYMTYPE
                member.linkname = data.decode()
                archive.addfile(member)
            else:
                member.mode = 0o755 if mode == b'100755' else 0o644
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
    return output.getvalue()


def run(root, host, environment, output_dir, all_files, command, args="pre-commit"):
    from transport import run_ssh
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    print('Preparing staged snapshot…', file=sys.stderr, flush=True)
    tree = git(root, 'write-tree').decode().strip()
    files = git(root, 'diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z').decode().rstrip('\0').split('\0')
    files = [p for p in files if p]
    if not files and not all_files:
        result = dict(code=0, output='No staged files. Stage changes first, or use :FarworkCheck! to check every file in the index.\n', changes=[])
    else:
        request = dict(archive=encode(snapshot(root, tree)), files=files,
                       all=all_files, command=command, args=args)
        source = Path(__file__).read_text()
        command_line = 'python3 -c ' + shlex.quote(source) + ' remote'
        print('Connecting to remote check environment…', file=sys.stderr, flush=True)
        proc = run_ssh(host, command_line, environment=environment, input=json.dumps(request).encode(), stderr=None)
        if proc.returncode:
            raise RuntimeError('SSH/check runner failed (exit %s); see preceding output' % proc.returncode)
        result = json.loads(proc.stdout)
    result['tree'] = tree
    # Persist before applying anything: fixes survive closing Neovim or conflicts.
    (output_dir / 'result.json').write_text(json.dumps(result))
    (output_dir / 'output.log').write_text(result['output'])
    for change in result['changes']:
        for key in ('before', 'after'):
            if change[key] is not None:
                target = safe_path(output_dir / key, change['path'])
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(decode(change[key]))


def apply(root, output_dir):
    result = json.loads((Path(output_dir) / 'result.json').read_text())
    if git(root, 'write-tree').decode().strip() != result['tree']:
        raise RuntimeError('Staging changed during checks; fixes preserved for review')
    planned = []
    for change in result['changes']:
        if change['after'] is None:
            raise RuntimeError('Hook deleted a file; review the saved result: ' + change['path'])
        target = safe_path(root, change['path'])
        current = target.read_bytes() if target.is_file() else None
        mode = (0o755 if target.stat().st_mode & 0o111 else 0o644) if target.is_file() else None
        if current != decode(change['before']) or mode != change['before_mode'] or (target.exists() and not target.is_file()):
            raise RuntimeError('Local file differs from checked snapshot: ' + change['path'])
        planned.append((target, change))
    # Check every file before making any changes. Never write to the local index.
    for target, change in planned:
        data = decode(change['after'])
        if data is None:
            target.unlink()
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            fd, temp = tempfile.mkstemp(prefix='.remote-check-', dir=target.parent)
            try:
                with os.fdopen(fd, 'wb') as stream: stream.write(data)
                os.chmod(temp, change['mode'])
                os.replace(temp, target)
            finally:
                if os.path.exists(temp): os.unlink(temp)
    print(json.dumps({'applied': len(planned)}))


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'remote':
            # SSH callers may inherit Git variables from a hook environment.
            for key in list(os.environ):
                if key.startswith('GIT_'): os.environ.pop(key)
            print(json.dumps(remote(json.load(sys.stdin))))
        elif sys.argv[1] == 'apply':
            apply(*sys.argv[2:])
        elif sys.argv[1] == 'run':
            root, host, environment, directory, all_files, command = sys.argv[2:8]
            args = sys.argv[8] if len(sys.argv) > 8 else "pre-commit"
            run(root, host, environment, directory, all_files == 'true', json.loads(command), args)
        else:
            raise RuntimeError('Unknown operation')
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
