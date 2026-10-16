-- Run from the repository root with: nvim --headless -u NONE -l tests/test_upload.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src", "p")
root = vim.uv.fs_realpath(root)
vim.fn.mkdir(root .. "/build", "p")
vim.fn.mkdir(root .. "/.git", "p")
for _, name in ipairs({ "src/a.txt", "src/b.txt", "src/with space.txt", ".env", "build/output", ".git/config" }) do
  vim.fn.writefile({ name }, root .. "/" .. name)
end
local protected = { ".venv/lib/python3.12/site-packages/pip/_internal/operations/build/metadata.py",
  "nested/venv/bin/pip", "nested/.venv/pyvenv.cfg" }
for _, name in ipairs(protected) do
  vim.fn.mkdir(vim.fn.fnamemodify(root .. "/" .. name, ":h"), "p")
  vim.fn.writefile({ "environment must stay local" }, root .. "/" .. name)
end
vim.uv.fs_symlink(root .. "/src/a.txt", root .. "/link.txt")
local calls, notices = {}, {}
vim.notify = function(message) table.insert(notices, message) end
vim.system = function(cmd, opts, callback)
  table.insert(calls, { cmd = cmd, opts = opts, callback = callback })
  return {}
end
local upload = require("farwork.upload")
local function wait_for(count)
  assert(vim.wait(2000, function() return #calls == count end), "Timed out waiting for upload")
end
local function complete(index, code)
  calls[index].callback({ code = code, stderr = code == 0 and "" or "test failure" })
  vim.wait(30, function() return false end, 5)
end
local function save(name)
  vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. name))
  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = 0 })
end
upload.start({ root = root, destination = "coder.test:/tmp/project/", rsync = "/usr/bin/true",
  exclude = function(path) return path == ".env" or path:match("^build/") end })
-- Saves during initial scanning must wait behind the full upload.
save("src/a.txt")
save("src/a.txt")
save(".env")
wait_for(1)
local manifest = calls[1].opts.stdin
assert(manifest:find("src/a.txt\0", 1, true))
assert(manifest:find("src/with space.txt\0", 1, true))
for _, excluded in ipairs({ ".env", "build/", ".git/", "link.txt", ".venv/", "venv/" }) do
  assert(not manifest:find(excluded, 1, true), excluded .. " should be excluded")
end
assert(not vim.tbl_contains(calls[1].cmd, "--delete"))
complete(1, 1)
assert(#calls == 1, "Initial failure must pause saves")
local drained
assert(upload.drain(root .. "/other", function() error("Must not drain another project") end) == "different")
assert(#calls == 1, "Wrong-project reconnect must not start any transfers")
assert(upload.drain(root, function(done) drained = done end) == "waiting")
wait_for(2)
assert(calls[2].opts.stdin, "Retry initial sync before saves")
complete(2, 0)
wait_for(3)
assert(calls[3].cmd[#calls[3].cmd - 1] == "./src/a.txt")
save("src/a.txt")
save("src/b.txt")
assert(#calls == 3, "Uploads must be serialized")
assert(drained == nil, "Reconnect must wait for every queued file")
complete(3, 0)
wait_for(4)
assert(calls[4].cmd[#calls[4].cmd - 1] == "./src/a.txt")
complete(4, 0)
wait_for(5)
assert(calls[5].cmd[#calls[5].cmd - 1] == "./src/b.txt")
complete(5, 0)
assert(drained == true, "Reconnect should continue only after successful uploads")
vim.cmd.UploadStatus()
assert(notices[#notices]:find("idle; 0 upload", 1, true))
vim.cmd.UploadStop()
upload.start({ root = root, destination = "coder.test:/tmp/project/", initial_sync = false })
for _, name in ipairs(protected) do save(name) end
vim.wait(30, function() return false end, 5)
assert(#calls == 5, "Save-only mode must never upload virtual environment files")
vim.cmd.UploadStop()

-- Isolate persisted configuration while testing the interactive commands.
local stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind) return kind == "state" and (root .. "/state") or stdpath(kind) end
vim.cmd.cd(vim.fn.fnameescape(root))
upload.setup()
local prompts = 0
vim.ui.input = function(_, cb) prompts = prompts + 1; cb("coder.test:/tmp/project/") end
vim.cmd.UploadStart()
wait_for(6)
assert(prompts == 1)
complete(6, 0)
vim.cmd.UploadStop()
vim.cmd.UploadStart()
wait_for(7)
assert(prompts == 1, "Destination must be remembered")
complete(7, 0)
vim.cmd.UploadStop()
upload.start({ root = root, destination = "coder.test:/tmp/project/", initial_sync = false })
save("src/a.txt")
wait_for(8)
local cancelled
assert(upload.drain(root, function(done) cancelled = done end) == "waiting")
complete(8, 1)
assert(cancelled == nil, "Failure must retain the deferred reconnect")
vim.cmd.UploadStop()
vim.wait(30, function() return cancelled ~= nil end, 5)
assert(cancelled == false, "Stopping must cancel the deferred reconnect")
local prepare
upload.start({ root = root, destination = "coder.test:/tmp/project/", initial_sync = false,
  before_transfer = function(done) prepare = done end })
save("src/a.txt")
assert(#calls == 8, "No upload may start before the Git check")
prepare("rebase in progress")
vim.wait(30, function() return false end, 5)
assert(#calls == 8, "Git failures must pause the upload queue")
vim.cmd.UploadRetry()
prepare()
wait_for(9)
assert(calls[9].cmd[#calls[9].cmd - 1] == "./src/a.txt", "A passed guard must resume the queued file")
complete(9, 1)
vim.cmd.UploadRetry()
prepare()
wait_for(10)
assert(calls[10].cmd[#calls[10].cmd - 1] == "./src/a.txt", "Failed uploads must retry the same file")
complete(10, 0)
local synced
upload.sync(root, function(done) synced = done end)
prepare()
wait_for(11)
assert(calls[11].opts.stdin:find("src/b.txt\0", 1, true), "Explicit project sync must include all files")
complete(11, 0)
assert(synced == true, "Project sync must release its completion callback")
vim.cmd.UploadStop()
upload.start({ root = root, destination = "coder.test:/tmp/project/", initial_sync = false })
local resume = assert(upload.hold(root))
save("src/a.txt")
assert(upload.status().paused and #calls == 11, "Saves during recovery must queue without sending")
vim.cmd.UploadRetry()
assert(#calls == 11, "Retry must not bypass the recovery hold")
assert(upload.drain(root, function() end) == "paused")
assert(not pcall(upload.start, { root = root, destination = "coder.test:/other/" }))
resume(false)
assert(not upload.status().paused and upload.status().error and #calls == 11)
resume = assert(upload.hold(root))
resume(true)
wait_for(12)
complete(12, 0)
assert(upload.idle(root))
vim.cmd.UploadStop()
-- Built-in exclusions apply even to direct callers with no filter or a
-- permissive custom filter, for both initial sync and subsequent saves.
for _, options in ipairs({ {}, { exclude = function() return false end } }) do
  local count = #calls + 1
  options.root, options.destination = root, "coder.test:/tmp/project/"
  upload.start(options)
  wait_for(count)
  for _, name in ipairs(protected) do
    assert(not calls[count].opts.stdin:find(name, 1, true), "Manifest leaked " .. name)
  end
  complete(count, 0)
  for _, name in ipairs(protected) do save(name) end
  vim.wait(30, function() return false end, 5)
  assert(#calls == count, "Saving virtual environment files must not upload them")
  vim.cmd.UploadStop()
end
local guard, killed
upload.start({ root = root, destination = "coder.test:/tmp/project/", initial_sync = false,
  before_transfer = function(done)
    guard = done
    return { kill = function(_, signal) killed = signal end }
  end })
local count = #calls
save("src/a.txt")
assert(upload.status().busy)
vim.cmd.UploadStop()
assert(killed == 15 and not upload.status().enabled, "Stop must cancel a stalled guard")
guard(nil)
vim.wait(30, function() return false end, 5)
assert(#calls == count, "A late guard callback must not upload after stop")
upload.start({ root = root, destination = "coder.test:/tmp/project/", initial_sync = false })
save("src/a.txt")
wait_for(count + 1)
vim.cmd.UploadStop()
complete(count + 1, 0)
assert(not upload.status().enabled, "Late transfer completion must not revive stopped session")
vim.fn.stdpath = stdpath
vim.cmd.cd("/")
vim.fn.delete(root, "rf")
print("PASS: startup manifest/exclusions, serialization, retries, save-only mode, interactive setup and persistence")
vim.cmd("qa!")
