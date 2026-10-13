"""Read-only Git guard for uploads. Never changes remote history or files."""
import json
import shlex
import subprocess
import sys
from pathlib import Path


def git(root, *args, check=True):
    return subprocess.run(["git", "-C", str(root), *args], check=check,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def identity(root):
    for marker in ("rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "index.lock"):
        path = git(root, "rev-parse", "--git-path", marker).stdout.decode().strip()
        if (Path(root) / path).exists():
            raise RuntimeError("Finish the Git operation before syncing: " + marker)
    head = git(root, "rev-parse", "HEAD").stdout.decode().strip()
    branch = git(root, "symbolic-ref", "--quiet", "--short", "HEAD", check=False).stdout.decode().strip()
    return {"head": head, "branch": branch}


def main():
    mode, root = sys.argv[1:3]
    if mode not in ("identity", "check", "send"):
        raise RuntimeError("Unsupported operation; this helper only checks Git history.")
    desired = identity(root)
    if mode == "identity":
        print(json.dumps(desired))
        return
    # 'send' is a read-only alias for Neovim sessions opened before the rename.
    host, remote = sys.argv[3:5]
    source = Path(__file__).read_text()
    command = "python3 -c " + shlex.quote(source) + " identity " + shlex.quote(remote)
    result = subprocess.run(
        ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=60", host, command],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    if json.loads(result.stdout) != desired:
        raise RuntimeError("Local and remote Git history differ. Uploads paused to avoid overwriting "
                           "the remote checkout; automatic Git alignment is disabled. No remote files were changed.")
    if identity(root) != desired:
        raise RuntimeError("Local Git history changed during the check; retry.")
    print(json.dumps({"changed": False, "identity": desired}))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(error.stderr.decode() if isinstance(error, subprocess.CalledProcessError) else str(error), file=sys.stderr)
        sys.exit(1)
