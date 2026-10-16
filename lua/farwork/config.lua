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
  git = { auto_fast_forward = false },
  operation_timeout = 120,
  check_timeout = 600,
  check_args = "pre-commit",
  check_command = { "pre-commit", "run", "--hook-stage", "pre-commit" },
}
M.options = vim.deepcopy(defaults)

function M.validate_project(project)
  assert(type(project) == "table", "Project config must be an object")
  assert(type(project.host) == "string" and project.host:match("^[%w_.%-]+$"), "Project host must be an SSH alias")
  assert(type(project.remote) == "string" and project.remote:sub(1, 1) == "/", "Project remote path must be absolute")
  for key, value in pairs(project) do
    assert(vim.tbl_contains({ "host", "remote", "build", "environment", "lsp" }, key), "Unknown project field: " .. key)
    if key == "lsp" then
      assert(value == false or value == "clangd", "Project lsp must be clangd or false")
    else assert(type(value) == "string", "Project fields must be strings") end
  end
  if project.build then assert(project.build:sub(1, 1) == "/", "Project build path must be absolute") end
  return project
end

function M.setup(opts)
  opts = opts or {}
  assert(opts.auto_commit == nil, "auto_commit was renamed to git.auto_fast_forward")
  local allowed = { keymaps = true, rsync = true, clangd_args = true,
    build_command = true, upload_exclude = true, state_dir = true, cache_dir = true,
    projects = true, notify_uploads = true, auto_connect = true, git = true, operation_timeout = true, check_timeout = true, check_args = true, check_command = true }
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
  assert(type(options.git) == "table", "git must be a table")
  for key in pairs(options.git) do assert(key == "auto_fast_forward", "Unknown git option: " .. key) end
  options.git = vim.tbl_extend("force", defaults.git, options.git)
  assert(type(options.git.auto_fast_forward) == "boolean", "git.auto_fast_forward must be boolean")
  for _, key in ipairs({ "operation_timeout", "check_timeout" }) do
    assert(type(options[key]) == "number" and options[key] > 0 and options[key] < math.huge,
      key .. " must be a positive finite number of seconds")
  end
  assert(options.check_args == "pre-commit" or options.check_args == "none",
    "check_args must be pre-commit or none")
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
