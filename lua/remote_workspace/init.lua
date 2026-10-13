local M = {}

--- Register commands. No connections are opened until :RemoteStart/:UploadStart.
--- See README.md for the public configuration options.
function M.setup(opts)
  assert(vim.fn.has("nvim-0.11") == 1, "remote-workspace.nvim requires Neovim 0.11+")
  opts = require("remote_workspace.config").setup(opts)
  require("remote_workspace.upload").setup(opts)
  require("remote_workspace.remote").setup(opts)
end

function M.start(reset)
  return require("remote_workspace.remote").start(reset)
end

function M.is_project()
  return require("remote_workspace.remote").is_project()
end

function M.owns_buffer(buf)
  return require("remote_workspace.remote").owns_buffer(buf)
end

function M.local_clangd_root(buf, on_dir)
  return require("remote_workspace.remote").local_clangd_root(buf, on_dir)
end

return M
