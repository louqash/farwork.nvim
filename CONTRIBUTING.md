# Contributing

Install Neovim 0.11+, Python 3, Git, Bash, clangd, and rsync 3+ on PATH, then run
`make test` from the repository root. Tests use disposable local repositories
and a local substitute for SSH; they do not connect to a user's workspace.

The modules under `lua/farwork/` own configuration, SSH project setup,
upload queuing, LSP edit recovery, and Git checks. `scripts/remote_git.py` checks repository alignment and implements the
opt-in, verified metadata fast-forward. Add public options in `config.lua` and document them in both
README.md and `doc/farwork.txt`.

Preserve these boundaries:

- Never stash, reset, checkout, clean, or delete remote user files automatically.
- Never upload `.git` or virtual environments, even if they are not Git-ignored.
- Keep failed uploads queued; do not discard them on connection errors.
- Quote remote arguments and keep environment commands user-supplied.
- Exercise actual Git/filesystem behavior in temporary fixtures for changes
  affecting working trees, retries, or exclusions.

The project is MIT licensed. Include a reproduction and validation results with
bug reports and changes. Redact private hostnames and source code from logs.
