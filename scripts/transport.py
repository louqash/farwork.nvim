"""Local SSH transport shared by Git, recovery and check helpers."""
import os
import signal
import shlex
import subprocess


def run_ssh(host, command, *, environment="", input=None, stderr=subprocess.PIPE):
    body = "set -e\n" + environment + "\nexec " + command
    args = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3",
            host, "bash -lc " + shlex.quote(body)]
    timeout = float(os.environ.get("FARWORK_TIMEOUT", "120"))
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=stderr, start_new_session=True)

    def terminate(signum=None, frame=None):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if signum is not None:
            raise RuntimeError("Remote operation cancelled")

    previous = signal.signal(signal.SIGTERM, terminate)
    try:
        try:
            stdout, errors = process.communicate(input, timeout=timeout)
        except subprocess.TimeoutExpired:
            terminate()
            process.communicate()
            raise RuntimeError("Remote operation timed out after %g seconds" % timeout)
        if process.returncode:
            raise RuntimeError((errors or b"SSH command failed").decode(errors="replace"))
        return subprocess.CompletedProcess(args, process.returncode, stdout, errors)
    finally:
        terminate()
        process.wait()
        signal.signal(signal.SIGTERM, previous)
