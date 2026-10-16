vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("farwork")
local projects = require("farwork.projects")
local remote = require("farwork.remote")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/repo/src", "p")
tmp = vim.uv.fs_realpath(tmp)
local root = tmp .. "/repo"
vim.fn.mkdir(root .. "/.git", "p")
local profile = { host = "build-host", remote = "/workspace", environment = "source /venv/bin/activate" }
local function write(path, value) vim.fn.writefile({ vim.json.encode(value) }, path) end
write(tmp .. "/.farwork.json", profile)
plugin.setup({ state_dir = tmp .. "/state" })
assert(not projects.file_root(root .. "/src/new.cpp"), "Discovery must stop at Git boundary")
write(root .. "/.farwork.json", profile)
assert(plugin.project_root(root .. "/src/new.cpp") == root)
assert(remote.configured_root(root .. "/src") == root)
local called = false
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buf, root .. "/src/new.cpp")
remote.local_clangd_root(buf, function() called = true end)
assert(not called, "Project marker must suppress local clangd even before trust")
local real_read = vim.secure.read
local reads = 0
vim.secure.read = function(path)
  reads = reads + 1
  return table.concat(vim.fn.readfile(path), "\n")
end
assert(projects.read(root).environment == profile.environment)
write(root .. "/.farwork.json", { host = "other", remote = "/other" })
assert(projects.read(root).host == "other" and reads == 2, "Recheck trust on every read")
write(root .. "/.farwork.json", { host = "other", remote = "relative" })
assert(not pcall(projects.read, root), "Reject invalid schema")
write(root .. "/.farwork.json", profile)
vim.secure.read = function() return nil end
assert(not pcall(projects.read, root), "Untrusted file must not silently fall back")
vim.system = function() error("Denied config must never connect") end
remote.start({ root = root })
assert(not remote.status().connecting)
vim.secure.read = real_read
-- Test event-driven connection without any network or native trust writes.
local starts = 0
remote.start = function(opts) starts = starts + 1; assert(opts.root == root) end
vim.api.nvim_set_current_buf(buf)
vim.wait(30, function() return false end)
assert(starts == 0, "Default setup must not autoconnect")
plugin.setup({ state_dir = tmp .. "/state", auto_connect = true })
assert(vim.wait(1000, function() return starts == 1 end))
for _ = 1, 4 do vim.api.nvim_exec_autocmds("BufEnter", { buffer = buf }) end
vim.wait(30, function() return false end)
assert(starts == 1, "Failed/cancelled attempts must not loop")
plugin.setup({ state_dir = tmp .. "/state", auto_connect = true })
plugin.setup({ state_dir = tmp .. "/state", auto_connect = false })
vim.wait(30, function() return false end)
assert(starts == 1, "Disabling autoconnect must cancel scheduled work")
vim.fn.delete(root .. "/.farwork.json")
plugin.setup({ state_dir = tmp .. "/state", auto_connect = true, projects = { [root] = profile } })
assert(vim.wait(1000, function() return starts == 2 end), "Lua profiles must autoconnect too")
remote.status = function() return { root = "/another", upload = {} } end
plugin.setup({ state_dir = tmp .. "/state", auto_connect = true, projects = { [root] = profile } })
vim.wait(30, function() return false end)
assert(starts == 2, "Must not automatically switch active projects")
-- The closest profile controls local LSP ownership, not any ancestor profile.
plugin.setup({ state_dir = tmp .. "/state", projects = {
  [root] = profile,
  [root .. "/src"] = { host = "build-host", remote = "/plain", lsp = false },
} })
called = false
remote.local_clangd_root(buf, function() called = true end)
assert(called, "A nested plain project must override a parent's remote clangd")
-- A nested project file likewise overrides saved/configured ancestors.
write(root .. "/src/.farwork.json", { host = "build-host", remote = "/plain", lsp = false })
plugin.setup({ state_dir = tmp .. "/state", projects = { [root] = profile } })
called = false
remote.local_clangd_root(buf, function() called = true end)
assert(called, "A nested plain project file must override an ancestor profile")
-- Lua fields still override the same-root project file.
plugin.setup({ state_dir = tmp .. "/state", projects = { [root .. "/src"] = profile } })
called = false
remote.local_clangd_root(buf, function() called = true end)
assert(called, "Unspecified Lua lsp must preserve the file's explicit false")
plugin.setup({ state_dir = tmp .. "/state", projects = {
  [root .. "/src"] = vim.tbl_extend("force", profile, { lsp = "clangd" }),
} })
called = false
remote.local_clangd_root(buf, function() called = true end)
assert(not called, "Explicit Lua clangd must override the project file")
plugin.setup({ state_dir = tmp .. "/state" })
vim.fn.delete(tmp, "rf")
print("PASS: project files, Git boundaries, trust denial, validation, opt-in auto-connect")
vim.cmd("qa!")
