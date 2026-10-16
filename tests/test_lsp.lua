vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("farwork")
local lsp = require("farwork.lsp")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
tmp = vim.uv.fs_realpath(tmp)
local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(source, tmp .. "/source.cpp")
local target = tmp .. "/header with spaces.h"
vim.fn.writefile({ "// header" }, target)
local calls, notices = {}, {}
vim.notify = function(message) notices[#notices + 1] = message end
local function client(name, id)
  return { name = name, id = id, initialized = true, attached_buffers = { [source] = true },
    stop = function() end,
    is_stopped = function() return false end,
    request = function(self, method, params, callback, bufnr)
      assert(method == "textDocument/switchSourceHeader")
      assert(bufnr == source and params.uri == vim.uri_from_bufnr(source))
      calls[#calls + 1] = { client = self.name, callback = callback }
      return true, #calls
    end }
end
local local_client, remote_client = client("clangd", 1), client("remote_clangd", 2)
local clients = { local_client, remote_client }
vim.lsp.get_clients = function() return clients end
vim.lsp.get_client_by_id = function(id) return id == 1 and local_client or remote_client end
plugin.owns_buffer = function() return true end
plugin.switch_source_header(source)
assert(calls[1].client == "remote_clangd", "Prefer remote clangd over a stray local client")
calls[1].callback(nil, vim.uri_from_fname(target))
assert(vim.api.nvim_buf_get_name(0) == target, "Open the returned URI, including spaces")
clients = { local_client }
plugin.switch_source_header(source)
assert(#calls == 1 and #notices == 1, "Never fall back to local clangd in an active remote buffer")
plugin.owns_buffer = function() return false end
plugin.switch_source_header(source)
assert(calls[2].client == "clangd", "Support ordinary local projects")
calls[2].callback({ message = "server error" })
assert(notices[2] == "server error")
calls[2].callback(nil, "")
assert(vim.api.nvim_buf_get_name(0) == target, "Empty result must not change buffers")
clients = {}
lsp.setup({ keymaps = false })
vim.api.nvim_exec_autocmds("LspAttach", { buffer = source, data = { client_id = 2 } })
assert(vim.fn.maparg("<leader>ch", "n") == "", "Mappings must be opt-in")
lsp.setup({ keymaps = true })
vim.api.nvim_exec_autocmds("LspAttach", { buffer = source, data = { client_id = 2 } })
vim.api.nvim_set_current_buf(source)
local mapping = vim.fn.maparg("<leader>ch", "n", false, true)
assert(mapping.buffer == 1 and type(mapping.callback) == "function")
clients = { remote_client }
mapping.callback()
assert(calls[3].client == "remote_clangd", "Plugin-owned mapping must route to the attached server")
vim.fn.delete(tmp, "rf")
print("PASS: header/source selection, URI handling, errors, and optional buffer mappings")
vim.cmd("qa!")
