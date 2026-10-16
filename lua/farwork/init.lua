local M = {}

--- Register commands; automatic connections are opt-in.
--- See README.md for the public configuration options.
function M.setup(opts)
  assert(vim.fn.has("nvim-0.11") == 1, "farwork.nvim requires Neovim 0.11+")
  opts = require("farwork.config").setup(opts)
  require("farwork.upload").setup(opts)
  require("farwork.remote").setup(opts)
  require("farwork.projects").setup(opts)
  require("farwork.lsp").setup(opts)
end

function M.start(options)
  return require("farwork.remote").start(options)
end

function M.status() return require("farwork.remote").status() end
function M.project_root(path) return require("farwork.remote").project_root(path) end

function M.is_project()
  return require("farwork.remote").is_project()
end

function M.owns_buffer(buf)
  return require("farwork.remote").owns_buffer(buf)
end

function M.local_clangd_root(buf, on_dir)
  return require("farwork.remote").local_clangd_root(buf, on_dir)
end

function M.switch_source_header(bufnr)
  return require("farwork.lsp").switch_source_header(bufnr)
end

return M
