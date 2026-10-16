local M = {}
local generation = 0
local reviewing = false
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
  assert(contents, "Project config was not trusted/readable: " .. path .. ". Use :FarworkTrust to review and trust the config, then :FarworkStart to retry.")
  local project = vim.json.decode(contents)
  return require("farwork.config").validate_project(project)
end

local function registry_path()
  return require("farwork.config").state_dir() .. "/project-roots.json"
end

-- Locations only: always reread the config and recheck trust on connection.
function M.known_roots()
  local path = registry_path()
  if vim.fn.filereadable(path) == 0 then return {} end
  local roots = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  assert(type(roots) == "table" and vim.islist(roots), "Invalid project-roots.json")
  local found = {}
  for _, root in ipairs(roots) do
    assert(type(root) == "string", "Invalid project root")
    if vim.fn.isdirectory(root) == 1 and vim.fn.filereadable(root .. "/" .. marker) == 1 then
      found[root] = true
    end
  end
  return found
end

function M.remember(root)
  if vim.fn.filereadable(root .. "/" .. marker) == 0 then return end
  local roots = M.known_roots()
  roots[root] = true
  local list = vim.tbl_keys(roots)
  table.sort(list)
  vim.fn.mkdir(require("farwork.config").state_dir(), "p")
  assert(vim.fn.writefile({ vim.json.encode(list) }, registry_path()) == 0, "Cannot save project-roots.json")
end

local function notify(message, level)
  vim.notify("Farwork: " .. message, level or vim.log.levels.INFO)
end

function M.trust(revoke)
  if reviewing then notify("Finish the current trust review first"); return end
  local name = vim.api.nvim_buf_get_name(0)
  local root = (name ~= "" and M.file_root(name)) or M.file_root(vim.fn.getcwd())
  if not root then notify("No .farwork.json found for the current file or directory", vim.log.levels.WARN); return end
  local path = root .. "/" .. marker
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then notify("Project config is not a readable file: " .. path, vim.log.levels.ERROR); return end
  local function update(opts)
    local ok, success, result = pcall(vim.secure.trust, opts)
    if not ok or not success then
      notify("Could not update trust: " .. tostring(ok and result or success), vim.log.levels.ERROR)
      return false
    end
    return true
  end
  if revoke then
    if update({ action = "remove", path = path }) then
      notify("Trust decision removed for " .. path .. ". Active connections are unchanged; the next connection requires review.")
    end
    return
  end
  reviewing = true
  local opened, err = pcall(vim.cmd.sview, vim.fn.fnameescape(path))
  if not opened then reviewing = false; notify(tostring(err), vim.log.levels.ERROR); return end
  local buf = vim.api.nvim_get_current_buf()
  local realpath, tick = vim.uv.fs_realpath(path), vim.api.nvim_buf_get_changedtick(buf)
  vim.cmd.redraw()
  local action = "Trust this config"
  local ok, failure = pcall(vim.ui.select, { "Cancel", action }, {
    prompt = "Review " .. path .. " — its environment field can run remote commands:",
  }, function(choice)
    reviewing = false
    if choice ~= action then return end
    if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].modified
      or vim.api.nvim_buf_get_changedtick(buf) ~= tick
      or vim.uv.fs_realpath(vim.api.nvim_buf_get_name(buf)) ~= realpath then
      notify("Config changed during review. Save it and run :FarworkTrust again.", vim.log.levels.WARN)
      return
    end
    -- Trust the reviewed buffer, never unseen disk contents. Neovim compares
    -- its hash again on the next read, including changes made outside Neovim.
    if update({ action = "allow", bufnr = buf }) then
      notify("Config trusted. Run :FarworkStart to connect.")
    end
  end)
  if not ok then reviewing = false; notify(tostring(failure), vim.log.levels.ERROR) end
end

function M.setup(opts)
  vim.api.nvim_create_user_command("FarworkTrust", function(args) M.trust(args.bang) end,
    { bang = true, force = true, desc = "Review project config trust; ! removes its trust decision" })
  generation = generation + 1
  local current = generation
  local group = vim.api.nvim_create_augroup("FarworkAutoConnect", { clear = true })
  if not opts.auto_connect then return end
  local attempted, scheduled = {}, false
  local function check()
    if reviewing or scheduled then return end
    scheduled = true
    vim.schedule(function()
      scheduled = false
      if reviewing or generation ~= current or not require("farwork.config").options.auto_connect then return end
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
