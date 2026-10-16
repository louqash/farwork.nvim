local M = {}
local defaults = {
  keymaps = false,
  rsync = "rsync",
  clangd_args = { "--background-index", "--clang-tidy" },
  build_command = function(project) return { "cmake", "--build", project.build } end,
  upload_exclude = function(_) return false end,
  projects = {},
  notify_uploads = false,
  auto_connect = false,
  auto_commit = false,
  check_command = { "pre-commit", "run", "--hook-stage", "pre-commit" },
}
M.options = vim.deepcopy(defaults)

function M.validate_project(project)
  assert(type(project) == "table", "Project config must be an object")
  assert(type(project.host) == "string" and project.host:match("^[%w_.%-]+$"), "Project host must be an SSH alias")
  assert(type(project.remote) == "string" and project.remote:sub(1, 1) == "/", "Project remote path must be absolute")
  for key, value in pairs(project) do
    assert(vim.tbl_contains({ "host", "remote", "build", "environment" }, key), "Unknown project field: " .. key)
    assert(type(value) == "string", "Project fields must be strings")
  end
  if project.build then assert(project.build:sub(1, 1) == "/", "Project build path must be absolute") end
  return project
end

function M.setup(opts)
  opts = opts or {}
  local allowed = { keymaps = true, rsync = true, clangd_args = true,
    build_command = true, upload_exclude = true, state_dir = true, cache_dir = true,
    projects = true, notify_uploads = true, auto_connect = true, auto_commit = true, check_command = true }
  for key in pairs(opts) do assert(allowed[key], "Unknown farwork option: " .. key) end
  local options = vim.tbl_extend("force", vim.deepcopy(defaults), opts)
  assert(type(options.keymaps) == "boolean", "keymaps must be boolean")
  assert(type(options.rsync) == "string" and options.rsync ~= "", "rsync must be an executable name or path")
  assert(type(options.clangd_args) == "table" and vim.islist(options.clangd_args), "clangd_args must be a list")
  for _, arg in ipairs(options.clangd_args) do assert(type(arg) == "string", "clangd_args entries must be strings") end
  assert(type(options.check_command) == "table" and vim.islist(options.check_command) and #options.check_command > 0,
    "check_command must be a nonempty argument list")
  for _, arg in ipairs(options.check_command) do assert(type(arg) == "string", "check_command entries must be strings") end
  assert(type(options.build_command) == "function", "build_command must be a function")
  assert(type(options.upload_exclude) == "function", "upload_exclude must be a function")
  assert(type(options.notify_uploads) == "boolean", "notify_uploads must be boolean")
  assert(type(options.auto_commit) == "boolean", "auto_commit must be boolean")
  assert(type(options.auto_connect) == "boolean", "auto_connect must be boolean")
  assert(type(options.projects) == "table", "projects must map local roots to connection settings")
  local projects = {}
  for root, project in pairs(options.projects) do
    assert(type(root) == "string" and root ~= "" and type(project) == "table", "Invalid project profile")
    M.validate_project(project)
    root = vim.fn.fnamemodify(vim.fn.expand(root), ":p"):gsub("/+$", "")
    assert(root ~= "", "A project root cannot be the filesystem root")
    root = vim.uv.fs_realpath(root) or root
    projects[root] = vim.deepcopy(project)
  end
  options.projects = projects
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
