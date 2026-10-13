local M = {}
local defaults = {
  keymaps = false,
  rsync = "rsync",
  clangd_args = { "--background-index", "--clang-tidy" },
  build_command = function(project) return { "cmake", "--build", project.build } end,
  upload_exclude = function(_) return false end,
}
M.options = vim.deepcopy(defaults)

function M.setup(opts)
  opts = opts or {}
  local allowed = { keymaps = true, rsync = true, clangd_args = true,
    build_command = true, upload_exclude = true, state_dir = true, cache_dir = true }
  for key in pairs(opts) do assert(allowed[key], "Unknown remote_workspace option: " .. key) end
  local options = vim.tbl_extend("force", vim.deepcopy(defaults), opts)
  assert(type(options.keymaps) == "boolean", "keymaps must be boolean")
  assert(type(options.rsync) == "string" and options.rsync ~= "", "rsync must be an executable name or path")
  assert(type(options.clangd_args) == "table" and vim.islist(options.clangd_args), "clangd_args must be a list")
  for _, arg in ipairs(options.clangd_args) do assert(type(arg) == "string", "clangd_args entries must be strings") end
  assert(type(options.build_command) == "function", "build_command must be a function")
  assert(type(options.upload_exclude) == "function", "upload_exclude must be a function")
  for _, key in ipairs({ "state_dir", "cache_dir" }) do
    if options[key] ~= nil then
      assert(type(options[key]) == "string" and options[key] ~= "", key .. " must be a directory path")
      options[key] = vim.fn.fnamemodify(vim.fn.expand(options[key]), ":p"):gsub("/+$", "")
    end
  end
  M.options = options
  return options
end

function M.state_dir() return M.options.state_dir or vim.fn.stdpath("state") end
function M.cache_dir() return M.options.cache_dir or vim.fn.stdpath("cache") end

return M
