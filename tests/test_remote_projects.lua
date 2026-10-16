vim.opt.rtp:prepend(vim.fn.getcwd())
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/selected project/.git", "p")
vim.fn.mkdir(tmp .. "/empty", "p")
tmp = vim.uv.fs_realpath(tmp)
local root, empty = tmp .. "/selected project", tmp .. "/empty"
require("farwork").setup({ state_dir = tmp .. "/state", projects = {
  [root] = { host = "fixture", remote = "/workspace", lsp = false },
} })
local remote = require("farwork.remote")
local upload = require("farwork.upload")
local transfer, discovery
upload.drain = function() return "idle" end
upload.start = function(opts) transfer = opts end
vim.system = function(cmd, _, callback)
  assert(cmd[1] == "ssh")
  discovery = callback
  return {}
end
vim.notify = function() end
vim.cmd.cd(vim.fn.fnameescape(empty))
local buffer = vim.api.nvim_get_current_buf()
local function choose(cancel)
  vim.ui.select = function(items, _, callback)
    assert(#items == 1 and items[1] == root)
    callback(not cancel and root or nil)
  end
  vim.cmd.RemoteProjects()
end
choose(true)
assert(not discovery and vim.fn.getcwd() == empty, "Cancel must preserve cwd")
choose(false)
assert(vim.fn.getcwd() == empty and remote.status().connecting)
discovery({ code = 1, stderr = "Connection failed" })
assert(vim.wait(1000, function() return not remote.status().connecting end))
assert(not transfer and vim.fn.getcwd() == empty, "Failed discovery must preserve cwd")
local function discover()
  discovery({ code = 0, stdout = vim.json.encode({ remote = "/workspace", builds = {}, roots = {} }) })
  assert(vim.wait(1000, function() return transfer ~= nil end))
end
choose(false)
discover()
assert(vim.fn.getcwd() == empty, "Must wait for initial upload, including failed uploads awaiting retry")
assert(not remote.status().ready)
transfer.on_initial_sync()
assert(vim.fn.getcwd() == root and remote.status().ready, "Successful initial upload must switch to the selected root")
assert(vim.api.nvim_get_current_buf() == buffer, "Project selection must preserve buffers")
vim.cmd.cd(vim.fn.fnameescape(empty))
transfer.on_initial_sync()
assert(vim.fn.getcwd() == empty, "Later full syncs must not change cwd again")
transfer = nil
remote.start({ root = root })
discover()
transfer.on_initial_sync()
assert(vim.fn.getcwd() == empty, "Ordinary start must preserve cwd")
vim.cmd.cd("/")
vim.fn.delete(tmp, "rf")
print("PASS: project picker changes cwd only after successful setup/upload, once; cancel/failure/start preserve cwd")
vim.cmd("qa!")
