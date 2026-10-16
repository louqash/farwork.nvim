local M = {}
local generation = 0
local marker = ".farwork.json"

-- Also handles newly named files which do not exist yet.
function M.directory(path)
  path = vim.fn.fnamemodify(vim.fn.expand(path), ":p"):gsub("/+$", "")
  if path == "" then path = "/" end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "directory" then path = vim.fs.dirname(path) end
  return vim.uv.fs_realpath(path)
end

function M.file_root(path)
  local directory = M.directory(path)
  while directory do
    if vim.uv.fs_stat(directory .. "/" .. marker) then return directory end
    -- Don't adopt another repository's config above this checkout.
    if vim.uv.fs_stat(directory .. "/.git") then return nil end
    local parent = vim.fs.dirname(directory)
    if parent == directory then return nil end
    directory = parent
  end
end

function M.read(root)
  local path = root .. "/" .. marker
  if not vim.uv.fs_stat(path) then return nil end
  local contents = vim.secure.read(path)
  assert(contents, "Project config was not trusted/readable: " .. path .. ". Use :trust to manage trust, then :RemoteStart to retry.")
  local project = vim.json.decode(contents)
  return require("farwork.config").validate_project(project)
end

function M.setup(opts)
  generation = generation + 1
  local current = generation
  local group = vim.api.nvim_create_augroup("FarworkAutoConnect", { clear = true })
  if not opts.auto_connect then return end
  local attempted, scheduled = {}, false
  local function check()
    if scheduled then return end
    scheduled = true
    vim.schedule(function()
      scheduled = false
      if generation ~= current or not require("farwork.config").options.auto_connect then return end
      local remote = require("farwork.remote")
      local status = remote.status()
      -- One active project per instance; switching/retrying stays explicit.
      if status.connecting or status.root or status.upload.enabled then return end
      if vim.bo.buftype ~= "" then return end
      local name = vim.api.nvim_buf_get_name(0)
      local root = remote.configured_root(name ~= "" and name or vim.fn.getcwd())
      if not root or attempted[root] then return end
      attempted[root] = true
      remote.start({ root = root })
    end)
  end
  vim.api.nvim_create_autocmd({ "VimEnter", "BufEnter", "DirChanged" }, { group = group, callback = check })
  check()
end

return M
