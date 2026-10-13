# remote-workspace.nvim

Edit locally in Neovim with remote clangd, CMake builds, and upload-on-save over
SSH (including Coder). Install this standalone plugin by local path or from a Git repository. No dotfiles modules, Telescope,
Mason, or completion plugin are required.

## Install

Requires Neovim 0.11+, Python 3, Git, SSH, and rsync 3+ locally. The remote needs
Python 3, Git, rsync, clangd, and the project's configured CMake build environment.
SSH authentication must work noninteractively. This plugin does not install tools.
The supported local platforms are Linux and macOS; the remote must provide
Bash and a Unix-style filesystem. Coder is optional: an ordinary SSH config
alias works. Configure users, ports, keys and proxies in `~/.ssh/config`.

With lazy.nvim, use your actual path to this plugin:

```lua
{
  dir = "/absolute/path/to/remote-workspace.nvim",
  lazy = false,
  config = function()
    require("remote_workspace").setup({ keymaps = true })
  end,
}
```

Or add the plugin directory to `runtimepath` and call
`require("remote_workspace").setup()`. Keymaps are **off by default**; commands
are always registered. Setup does not open an SSH connection. Run
`:checkhealth remote_workspace` to check local prerequisites.

The optional keymaps are `<leader>rs` (start), `<leader>rb` (build),
`<leader>rd` (remote diff), `<leader>us` (upload only), and `<leader>ui` (upload status).

## Configuration

All options are optional. The defaults are:

```lua
require("remote_workspace").setup({
  keymaps = false,
  rsync = "rsync", -- executable name or absolute local path
  clangd_args = { "--background-index", "--clang-tidy" },
  build_command = function(project)
    return { "cmake", "--build", project.build }
  end,
  upload_exclude = function(relative_path) return false end,
  state_dir = nil, -- defaults to vim.fn.stdpath("state")
  cache_dir = nil, -- defaults to vim.fn.stdpath("cache")
})
```

`clangd_args` replaces the default flag list. The plugin adds the discovered
compilation database and path mappings; do not supply conflicting mapping or
compile-directory flags. Configure LSP capabilities in `vim.lsp.config.clangd`.

`build_command(project)` runs in the remote project directory and must return
an argument list, not a shell string. Arguments are shell-escaped automatically.
The project table includes `host`, `remote`, `build`, and `environment`.
For a specific target and parallelism, for example:

```lua
build_command = function(project)
  return { "cmake", "--build", project.build, "--target", "my_app", "-j", "8" }
end,
```

`upload_exclude(path)` adds exclusions to the built-in protections for Git,
venvs, dependencies and build outputs; it cannot disable those protections.
It affects uploads only, not the initial download of missing files. For example:

```lua
upload_exclude = function(path)
  return path == "private" or path:match("^private/") ~= nil
end,
```

Set a custom remote environment such as `source /opt/project-venv/bin/activate`
using `:RemoteStart!`. It is remembered per local project. Custom keymaps can be
configured with normal `vim.keymap.set` calls instead of `keymaps = true`.

After hosting this repository, lazy.nvim users can replace the `dir` entry
with their actual `owner/remote-workspace.nvim` repository path. This checkout
has no published URL yet.

## Local clangd integration

If you also enable a local clangd, use this root callback to prevent it from
starting in remembered remote projects:

```lua
vim.lsp.config("clangd", {
  root_dir = require("remote_workspace").local_clangd_root,
})
```

Remote clangd inherits your `vim.lsp.config.clangd` capabilities and settings,
then supplies the remote command, root, path mappings, and full-text sync.
Standard LSP keymaps/completion can be configured through your usual LspAttach
callback. This plugin does not install `gd`, hover, or completion bindings.
`require("remote_workspace").is_project()` is available for file-picker routing;
`owns_buffer(bufnr)` tests whether a buffer belongs to the active remote project.

## State and limitations

Saved destinations remain in `stdpath("state")/remote-projects.json` and
`upload-projects.json`, preserving existing dotfiles settings. Remote header
caches remain in `stdpath("cache")/remote-headers/`. Upload queues are in memory.
Only one active remote project per Neovim instance is supported. Git checks are
read-only: this plugin does not stash, reset, switch remote branches, or reconcile
rebased history. Uploads overwrite matching remote files with local contents.

## Local Neovim with remote C++ analysis and builds

Run Neovim from any local C/C++ project root, then `:RemoteStart`.
On first use, enter an SSH alias and project path (`build-host:/absolute/project/`)
and optionally a remote Bash environment command such as
`source /opt/toolchain/env.sh`. These settings stay in Neovim's local state
directory and are reused on the next `:RemoteStart`. `:RemoteStart!` changes them.
Remembered remote projects do not automatically start a local clangd fallback.
Run `:RemoteStart` in each new session. `:RemoteStatus` shows the host, build
directory, and language servers attached to the current buffer; C/C++ buffers
should show `remote_clangd (initialized)` once connected.
Successful file uploads notify clangd after the remote write finishes. If
diagnostics still appear stale, use `:RemoteRefresh` once uploads are idle to
restart remote clangd without downloading or uploading the whole project.
When reconnecting with pending uploads, `:RemoteStart` retries the existing
queue and waits for it to finish before starting discovery or downloading files.
If the retry fails, inspect `:UploadStatus` and use `:UploadRetry` after resolving
the connection problem; the reconnect continues once the queue drains.
`:UploadStop` discards pending uploads and cancels that deferred reconnect, but
does not delete saved local files.

The remote environment must already have Python 3, clangd, rsync, CMake, the
project dependencies, and a configured compilation database. Enable
`CMAKE_EXPORT_COMPILE_COMMANDS=ON` in the project's existing CMake configuration
if needed. Discovery searches the project (up to six directory levels), resolves
compilation-database symlinks, and remembers the selected build directory. If
there are multiple databases, choose one; external build directories can be
entered manually. Custom compiler probing (`--query-driver`) isn't configured.

For a local directory without Git metadata, starting first downloads missing
remote source files, preserving existing local files and excluding dependencies,
build outputs, and Git metadata. Existing local Git checkouts skip this download
so deleted files are not restored from an older remote branch. It then uploads the local project and connects
to remote clangd over SSH. Use your preferred file picker to search these local files.
This also supports starting from an empty local directory for an existing remote
project. Downloads fill missing files; they do not refresh existing local copies.

Uploads use a read-only Git
check: matching local/remote HEAD and branch permit file uploads; differing
history or an unfinished Git operation pauses uploads. No stash, checkout,
reset, or history transfer runs on the remote.
`:UploadRetry` reruns the check and resumes queued uploads when history matches.
Do not run Git operations concurrently with uploads. Standalone `:UploadStart`
does not use this Git guard.

Existing recovery refs from the previous implementation remain under
`refs/nvim/backups/<id>/head`, `/branch`, and `/worktree`. Inspect them with
`git for-each-ref refs/nvim/backups` and
`git stash show -p --include-untracked <backup>/worktree`. They are not deleted
automatically. The uploader still does not propagate uncommitted deletions.

If the local directory has no `.git`, setup first clones the remote checkout's
Git history and initializes a local index without overwriting source files.
Use the repository root on both sides. Plain local `git diff`, `git status`,
and `git log` then work, including offline. The Git remote is named `workspace` for new local clones.
Existing local Git metadata is preserved on reconnect; branches, staging,
commits, and repository configuration are not automatically synchronized.
Local diffs compare against the local index, while `:RemoteDiff` compares
against the remote index. Excluded tracked files may appear locally deleted.
Your LSP completion, diagnostics, navigation, references, and rename use the
remote C++ environment. Local typing and motions stay local. Remote-only headers
open read-only; fetching a header can wait up to 15 seconds for SSH. LSP requests
and remote builds still have network latency. Project compilation databases and
the chosen build directory are excluded from uploads.

`:RemoteBuild` runs `cmake --build` in a terminal split after saves
and uploads finish. It refuses to build while project buffers are unsaved or
uploads are pending. Project-specific presets, targets, tests, or configure
commands can still be run through the normal SSH terminal. Use one remote
project per Neovim instance; this integration supports C/C++ via clangd, not
arbitrary language servers. It does not recreate unavailable dependencies on
the Mac or automatically configure a new remote build environment.

`:RemoteDiff` shows the remote checkout's unstaged Git diff in a
read-only split; `:RemoteDiff!` shows staged changes. Save your buffers and finish
uploads first. Press `q` to close the diff. This requires a connection and a
remote Git checkout; untracked files aren't included. The view is a snapshot:
rerun the command to refresh it. Local Git metadata is not required.

## File uploads without remote language analysis

Install modern rsync on the Mac (`brew install rsync`) and in the remote
workspace (`sudo apt-get install rsync` on Debian/Ubuntu). Confirm the SSH
hostname works with ordinary `ssh` and create the destination directory first.
Keep the local checkout as the source of truth; uploads overwrite matching
remote files but do not delete remote-only files or copy `.git`.

Open Neovim from the local project root and run `:UploadStart`.
Enter a destination such as `build-host:/home/user/my-project/`.
The module remembers this destination per local directory. Later sessions need
only `:UploadStart`; use `:UploadStart another-host:/absolute/path/` to change it.

Starting uploads the existing project asynchronously, then each save queues
that file behind any active transfer. Startup uploads skip symlinks and exclude
`.git`, `.env*`, `.venv`, `venv`, `node_modules`, top-level `build/`, `__pycache__`, and
`.DS_Store`; the same exclusions apply on save. `.gitignore` is not interpreted.
Empty directories are not transferred. Configure other exclusions through
`require("remote_workspace.upload").start({root=..., destination=..., exclude=function(path)
... end})`; `initial_sync=false` selects save-only mode.

Use `:UploadStatus`, `:UploadWait`, and `:UploadRetry` to monitor
or recover failed uploads. Wait for `idle; 0 upload(s) queued` before remote
builds or quitting: queues are in memory and aren't recovered after exit.
`:UploadStop` disables uploads and discards queued work once the current
transfer finishes. Use one uploading Neovim session per destination.
Local language servers still need local project dependencies. Standalone
`:UploadStart` only uploads files; the read-only Git guard is part of `:RemoteStart`.
Uncommitted renames/deletions are not synchronized as Git operations.

## Tests

From this plugin directory:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tests/test_remote_git.py
nvim --headless -u NONE -i NONE -l tests/test_setup.lua
nvim --headless -u NONE -i NONE -l tests/test_upload.lua
nvim --headless -u NONE -i NONE -l tests/test_remote.lua
```

The integration test additionally needs clangd, rsync 3+, Python 3, Git and Bash
on PATH. Tests use disposable local repositories and replace SSH with a local
transport; they never connect to your workspace.
