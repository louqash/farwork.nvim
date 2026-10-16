local M = {}
local plugin_config = require("farwork.config")
local q = vim.fn.shellescape
M.filetypes = { c = true, cpp = true, objc = true, objcpp = true }

function M.config(root, config, cache)
  assert(not (root .. config.remote .. cache):find("[,=]"), "clangd path mappings cannot contain commas or equals signs")
  local base = vim.deepcopy(vim.lsp.config.clangd or {})
  base.name, base.root_dir = "remote_clangd", root
  base.flags = vim.tbl_extend("force", base.flags or {}, { allow_incremental_sync = false })
  base.root_markers, base.before_init = nil, nil
  base.workspace_folders = { { uri = vim.uri_from_fname(root), name = vim.fs.basename(root) } }
  -- clangd matches path-component boundaries, so a mapping from "/" alone
  -- does not match descendants. Map each remote top-level directory instead.
  local mappings = { root .. "=" .. config.remote }
  for _, directory in ipairs(config.roots) do
    assert(not directory:find("[,=]"), "Unsupported remote directory in path mappings")
    table.insert(mappings, cache .. directory .. "=" .. directory)
  end
  local arguments = { config.clangd }
  vim.list_extend(arguments, plugin_config.options.clangd_args)
  vim.list_extend(arguments, {
    "--compile-commands-dir=" .. config.build,
    "--path-mappings=" .. table.concat(mappings, ",") })
  for i, value in ipairs(arguments) do arguments[i] = q(value) end
  base.cmd = require("farwork.transport").ssh(config, "cd -- " .. q(config.remote) .. "; exec " .. table.concat(arguments, " "))
  return base
end

return M
