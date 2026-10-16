-- Integration test: real rsync, Python discovery and clangd, with SSH transport
-- replaced by local execution against a separate simulated remote directory.
-- Requires clangd, python3 and rsync 3+ on PATH.
-- Run: nvim --headless -u NONE -l tests/test_remote.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. "/local", "p")
temp = vim.uv.fs_realpath(temp)
local root, remote, dependency = temp .. "/local", temp .. "/remote", temp .. "/dependency"
vim.fn.mkdir(temp .. "/bin", "p")
vim.fn.writefile({ "#!/bin/bash", 'exec bash -c "${!#}"' }, temp .. "/bin/ssh")
vim.fn.setfperm(temp .. "/bin/ssh", "rwx------")
vim.fn.writefile({ "#!/bin/sh", 'printf "%s\\n" "$@"' }, temp .. "/bin/record-build")
vim.fn.setfperm(temp .. "/bin/record-build", "rwx------")
vim.fn.mkdir(remote .. "/build", "p")
vim.fn.mkdir(dependency, "p")
vim.fn.writefile({ "inline int answer() { return 42; }" }, dependency .. "/answer.h")
vim.fn.writefile({ '#include "' .. dependency .. '/answer.h"', "int main() { return answer(); }" }, root .. "/main.cpp")
vim.fn.writefile({ "do not upload" }, root .. "/compile_commands.json")
vim.fn.writefile({ "private" }, root .. "/local-only")
vim.fn.writefile({ "preserve" }, remote .. "/remote-only")
vim.fn.mkdir(remote .. "/src", "p")
vim.fn.writefile({ "download this source" }, remote .. "/src/remote.cpp")
vim.fn.writefile({ "remote secret" }, remote .. "/.env")
vim.fn.writefile({ "older remote source" }, remote .. "/main.cpp")
local recipe = ".integration-tree/elements/components/build/aker.bst"
vim.fn.mkdir(remote .. "/.integration-tree/elements/components/build", "p")
vim.fn.writefile({ "kind: cmake" }, remote .. "/" .. recipe)
vim.fn.writefile({ vim.json.encode({ {
  directory = remote, file = remote .. "/main.cpp",
  arguments = { "clang++", "-std=c++17", "-c", remote .. "/main.cpp" },
} }) }, remote .. "/build/compile_commands.json")
local real_system, real_start, real_stdpath = vim.system, vim.lsp.start, vim.fn.stdpath
local real_buf_attach = vim.api.nvim_buf_attach
local drop_native_changes = false
vim.api.nvim_buf_attach = function(buffer, send_buffer, opts)
  if opts.on_lines and debug.getinfo(opts.on_lines, "S").source:match("/vim/lsp%.lua$") then
    local on_lines = opts.on_lines
    opts.on_lines = function(...)
      if not drop_native_changes then return on_lines(...) end
    end
  end
  return real_buf_attach(buffer, send_buffer, opts)
end
local function git(...)
  local command = { "git", "-C", remote, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
    "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false" }
  vim.list_extend(command, { ... })
  local result = real_system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git("init")
git("add", "main.cpp", recipe)
git("commit", "-m", "Fixture baseline")
local notices, starts = {}, {}
vim.notify = function(msg) table.insert(notices, msg) end
vim.fn.stdpath = function(kind)
  if kind == "state" or kind == "cache" then return temp .. "/" .. kind end
  return real_stdpath(kind)
end
vim.system = function(cmd, opts, callback)
  cmd = vim.deepcopy(cmd)
  if cmd[1] == "python3" and cmd[2]:match("remote_git%.py$") then
    opts = vim.tbl_extend("force", opts or {}, { env = { PATH = temp .. "/bin:" .. vim.env.PATH } })
  end
  if cmd[1] == "ssh" then
    assert(cmd[7] == "coder.test", "Expected remembered Coder hostname")
    cmd = { "bash", "-c", cmd[#cmd] }
  elseif cmd[1]:match("rsync$") then
    for i, arg in ipairs(cmd) do cmd[i] = arg:gsub("^coder%.test:", "") end
  elseif cmd[1] == "git" and cmd[2] == "clone" then
    for i, arg in ipairs(cmd) do cmd[i] = arg:gsub("^coder%.test:", "") end
  end
  return real_system(cmd, opts, callback)
end
vim.lsp.start = function(config, opts)
  table.insert(starts, vim.deepcopy(config))
  config = vim.deepcopy(config)
  config.cmd = { "bash", "-c", config.cmd[#config.cmd] }
  return real_start(config, opts)
end
vim.lsp.config("clangd", { capabilities = { offsetEncoding = { "utf-16" } } })
vim.cmd.cd(vim.fn.fnameescape(root))
vim.cmd.edit("main.cpp")
vim.bo.filetype = "cpp"
local buf = vim.api.nvim_get_current_buf()
local prompts = 0
vim.ui.input = function(_, callback)
  prompts = prompts + 1
  callback(prompts == 1 and ("coder.test:" .. remote) or "")
end
local mod = require("farwork.remote")
require("farwork.config").setup({
  rsync = vim.fn.exepath("rsync"),
  clangd_args = { "--background-index" },
  upload_exclude = function(path) return path == "local-only" end,
  build_command = function(project) return { temp .. "/bin/record-build", "--build", project.build, "--target", "example" } end,
})
mod.setup()
vim.cmd.RemoteStart()
local client
assert(vim.wait(20000, function()
  client = vim.lsp.get_clients({ bufnr = buf, name = "remote_clangd" })[1]
  return client and client.initialized
end, 30), table.concat(notices, "\n"))
assert(prompts == 2)
assert(vim.fn.filereadable(remote .. "/main.cpp") == 1)
assert(vim.fn.filereadable(remote .. "/local-only") == 0, "Custom upload exclusion must be applied")
assert(not starts[1].cmd[#starts[1].cmd]:find("--clang-tidy", 1, true), "Custom clangd flags must replace defaults")
assert(vim.fn.readfile(root .. "/src/remote.cpp")[1] == "download this source")
assert(vim.fn.filereadable(root .. "/.env") == 0)
assert(vim.fn.filereadable(root .. "/build/compile_commands.json") == 0)
assert(vim.fn.readfile(root .. "/main.cpp")[1]:find("#include", 1, true), "Download must preserve local edits")
assert(mod.is_project())
assert(vim.fn.readfile(root .. "/" .. recipe)[1] == "kind: cmake", "Nested build source must download")
assert(not require("farwork.upload").default_exclude(recipe))
assert(require("farwork.upload").default_exclude("build/generated.o"))
local recipe_status = real_system({ "git", "-C", root, "status", "--porcelain", "--", recipe }, { text = true }):wait()
assert(recipe_status.code == 0 and recipe_status.stdout == "", "Downloaded tracked recipe must not appear deleted")
assert(vim.fn.isdirectory(root .. "/.git") == 1, "Must create a real local checkout")
local local_diff = real_system({ "git", "-C", root, "diff", "--", "main.cpp" }, { text = true }):wait()
assert(local_diff.code == 0 and local_diff.stdout:find("-older remote source", 1, true), vim.inspect(local_diff))
local local_head = real_system({ "git", "-C", root, "rev-parse", "HEAD" }, { text = true }):wait().stdout
assert(vim.fn.filereadable(remote .. "/compile_commands.json") == 0)
assert(vim.fn.readfile(remote .. "/remote-only")[1] == "preserve")
local def = client:request_sync("textDocument/definition", {
  textDocument = { uri = vim.uri_from_fname(root .. "/main.cpp") },
  position = { line = 1, character = 21 },
}, 15000, buf)
assert(def and not def.err and def.result and #def.result > 0, vim.inspect(def))
local uri = def.result[1].uri or def.result[1].targetUri
local file = vim.uri_to_fname(uri)
assert(file:find(temp .. "/cache/remote-headers/", 1, true), "Definition path must map into header cache: " .. file)
vim.cmd.edit(vim.fn.fnameescape(file))
assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("answer", 1, true))
assert(vim.bo.readonly and not vim.bo.modifiable)
vim.cmd.edit(vim.fn.fnameescape(root .. "/main.cpp"))
vim.api.nvim_buf_set_lines(0, 1, 2, false, { "int main() { return answer() + 1; }" })
local uploaded_notification = false
local notify_rpc = client.notify
client.notify = function(self, method, params)
  if method == "workspace/didChangeWatchedFiles" then
    assert(vim.fn.readfile(remote .. "/main.cpp")[2]:find("+ 1", 1, true), "Notify only after remote write")
    uploaded_notification = true
  end
  return notify_rpc(self, method, params)
end
vim.cmd.write()
assert(vim.wait(5000, function() return require("farwork.upload").idle(root) end, 20))
assert(vim.fn.readfile(remote .. "/main.cpp")[2]:find("+ 1", 1, true))
assert(uploaded_notification, "Clangd must be notified after completed uploads")
local old_id = client.id
vim.cmd.RemoteRefresh()
assert(vim.wait(10000, function()
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf, name = "remote_clangd" })) do
    if c.id ~= old_id and c.initialized then return true end
  end
  return false
end, 20), "Refresh must replace remote clangd")
vim.cmd.RemoteDiff()
assert(vim.wait(5000, function() return vim.b.remote_git_diff == true end, 20))
assert(vim.bo.filetype == "diff" and not vim.bo.modifiable)
local diff = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(diff:find("-older remote source", 1, true))
assert(diff:find("+int main() { return answer() + 1; }", 1, true))
vim.cmd.close()
git("add", "main.cpp")
vim.cmd("RemoteDiff!")
assert(vim.wait(5000, function() return vim.b.remote_git_diff == true end, 20))
assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("+int main()", 1, true))
vim.cmd.close()
local recorded
vim.fn.jobstart = function(cmd, opts) recorded = { cmd = cmd, opts = opts }; return 1 end
vim.cmd("RemoteBuild -j 2")
assert(vim.wait(10000, function() return recorded ~= nil end, 20), table.concat(notices, "\n"))
assert(recorded and recorded.opts.term and recorded.cmd[#recorded.cmd]:find("--build", 1, true))
assert(recorded.cmd[#recorded.cmd]:find("example", 1, true), "Custom build target must reach the remote command")
local build_result = real_system({ "bash", "-c", recorded.cmd[#recorded.cmd] }, { text = true }):wait()
assert(build_result.code == 0 and build_result.stdout == "--build\n" .. remote .. "/build\n--target\nexample\n-j\n2\n",
  "Command arguments must survive remote shell quoting: " .. vim.inspect(build_result))
local snapshot = mod.status()
assert(snapshot.ready and snapshot.lsp_connected and snapshot.upload.queued == 0)
assert(snapshot.root == root and snapshot.host == "coder.test")
assert(real_system({ "git", "-C", root, "add", "main.cpp" }, { text = true }):wait().code == 0)
local local_index = real_system({ "git", "-C", root, "write-tree" }, { text = true }):wait().stdout
vim.cmd.cd(vim.fn.fnameescape(root .. "/src"))
assert(mod.project_root() == root, "Nested directories must resolve the saved project")
vim.cmd.RemoteStart()
assert(vim.wait(10000, function()
  local count = 0
  for _, notice in ipairs(notices) do
    if notice:find("Remote: Ready:", 1, true) then count = count + 1 end
  end
  return count == 2 and require("farwork.upload").idle(root)
end, 20), table.concat(notices, "\n"))
assert(prompts == 2, "Reconnect must reuse saved project settings")
-- A fresh module instance simulates restarting Neovim without RemoteStart.
package.loaded["farwork.remote"] = nil
local fresh = require("farwork.remote")
local local_started = false
fresh.local_clangd_root(buf, function() local_started = true end)
assert(not local_started, "Remembered remote project must not fall back to Mac clangd")
local outside = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(outside, temp .. "/ordinary/local.cpp")
fresh.local_clangd_root(outside, function() local_started = true end)
assert(local_started, "Unrelated local projects must still use local clangd")
package.loaded["farwork.remote"] = mod
assert(real_system({ "git", "-C", root, "rev-parse", "HEAD" }, { text = true }):wait().stdout == local_head,
  "Reconnect must preserve existing local Git metadata")
assert(real_system({ "git", "-C", root, "write-tree" }, { text = true }):wait().stdout == local_index,
  "Reconnect must preserve local staging")
-- Editing while disconnected can remove Neovim's native on_lines callback.
-- Reattaching must still deliver subsequent unsaved edits to the same server.
for _, c in ipairs(vim.lsp.get_clients()) do c:stop(true) end
assert(vim.wait(5000, function() return #vim.lsp.get_clients() == 0 end, 20))
vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "int main() { return answer() + 2; }" })
vim.cmd.RemoteRefresh()
assert(vim.wait(10000, function()
  client = vim.lsp.get_clients({ bufnr = buf, name = "remote_clangd" })[1]
  return client and client.initialized
end, 20))
local recovery_id = client.id
-- Fault injection: reproduce the observed buffer revision advancing while
-- the native LSP revision stays frozen, independently of disconnect timing.
drop_native_changes = true
local function has_missing_name()
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if d.message:find("missing_after_reconnect", 1, true) then return true end
  end
  return false
end
vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "int main() { return missing_after_reconnect; }" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
assert(vim.wait(10000, has_missing_name, 20), "Unsaved edits after reconnect must reach clangd")
vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "int main() { return answer(); }" })
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
assert(vim.wait(10000, function() return not has_missing_name() end, 20), "Fixed diagnostics must clear without refresh")
assert(client.id == recovery_id and not client:is_stopped(), "Recovery must not restart clangd")
assert(vim.lsp.util.buf_versions[buf] == vim.api.nvim_buf_get_changedtick(buf))
-- A configured profile must also connect with no saved state or prompts.
vim.fn.delete(temp .. "/state/remote-projects.json")
require("farwork.config").options.projects[root] = {
  host = "coder.test", remote = remote, build = remote .. "/build", environment = "",
}
vim.ui.input = function() error("Configured profiles must not prompt") end
local previous_client = client
mod.start({ root = root })
assert(vim.wait(10000, function()
  local count = 0
  for _, notice in ipairs(notices) do if notice:find("Remote: Ready:", 1, true) then count = count + 1 end end
  return count == 3 and require("farwork.upload").idle(root)
end, 20), table.concat(notices, "\n"))
assert(vim.wait(5000, function() return mod.status().lsp_connected end, 20))
local sync_client
-- Only the new client may survive the explicit reconnect.
for _, candidate in ipairs(vim.lsp.get_clients({ bufnr = buf, name = "remote_clangd" })) do
  if candidate.id ~= previous_client.id and not candidate:is_stopped() then sync_client = candidate end
end
assert(sync_client and sync_client.id ~= previous_client.id, "Reconnect must not reuse a retiring client")
vim.cmd.RemoteSync()
assert(vim.wait(10000, function() return require("farwork.upload").idle(root) end, 20))
assert(not sync_client:is_stopped(), "Manual file sync must not restart the LSP")
-- A trusted project file connects with no saved or Lua profile and no prompts.
vim.fn.delete(temp .. "/state/remote-projects.json")
local project_file = root .. "/.farwork.json"
vim.fn.writefile({ vim.json.encode(require("farwork.config").options.projects[root]) }, project_file)
require("farwork.config").options.projects = {}
local secure_read = vim.secure.read
vim.secure.read = function(path)
  assert(path == project_file)
  return table.concat(vim.fn.readfile(path), "\n")
end
mod.start({ root = root .. "/src" })
assert(vim.wait(10000, function()
  local count = 0
  for _, notice in ipairs(notices) do if notice:find("Remote: Ready:", 1, true) then count = count + 1 end end
  return count == 4 and require("farwork.upload").idle(root)
end, 20), table.concat(notices, "\n"))
vim.secure.read = secure_read
vim.api.nvim_buf_attach = real_buf_attach
for _, c in ipairs(vim.lsp.get_clients()) do c:stop(true) end
vim.system, vim.lsp.start, vim.fn.stdpath = real_system, real_start, real_stdpath
vim.cmd.cd("/")
vim.fn.delete(temp, "rf")
print("PASS: discovery, initial sync, live clangd definition/path mapping, remote header loading, save upload, build dispatch and saved settings")
vim.cmd("qa!")
