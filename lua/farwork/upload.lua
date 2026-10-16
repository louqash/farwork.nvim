-- Opt-in, one-way upload on save. Requires Neovim 0.10+ and rsync 3+.
-- start() uploads the project, then uploads saved files. Set initial_sync=false
-- for save-only mode. Loading this module alone does not enable uploads.
local M = {}
local settings = require("farwork.config")
local session

local function release_waiters(s, completed)
  local waiters = s.waiters or {}
  s.waiters = {}
  for _, callback in ipairs(waiters) do
    vim.schedule(function() callback(completed) end)
  end
end

local function notify(message, level)
  vim.notify("Upload: " .. message, level or vim.log.levels.INFO)
end

local function status()
  if not session then return "disabled" end
  if session.paused then return "paused for recovery review; " .. #session.queue .. " upload(s) queued" end
  if session.failed then return "FAILED: " .. session.failed .. " (" .. #session.queue .. " upload(s) queued)" end
  return (session.busy and "uploading; " or "idle; ")
    .. #session.queue .. " upload(s) queued"
end

function M.status()
  return {
    enabled = session ~= nil,
    paused = session and session.paused or false,
    root = session and session.root or nil,
    busy = session and session.busy or false,
    queued = session and #session.queue or 0,
    error = session and session.failed or nil,
    message = status(),
  }
end

local function register_status()
  vim.api.nvim_create_user_command("UploadStatus", function() notify(status()) end,
    { force = true, desc = "Show upload state, including before connecting" })
end

local function excluded(opts, path, directory)
  if path == ".git" or path:match("^%.git/") then return true end
  return opts.exclude and (opts.exclude(path) or (directory and opts.exclude(path .. "/")))
end

-- Enumerate asynchronously. A file manifest lets the initial upload honor the
-- same Lua exclusion function as on-save uploads, without following symlinks.
local function project_files(s, callback)
  local directories, files = { "" }, {}
  local scan
  scan = function()
    local dir = table.remove(directories)
    if not dir then callback(nil, files); return end
    vim.uv.fs_scandir(s.root .. "/" .. dir, vim.schedule_wrap(function(err, handle)
      if err then callback(err); return end
      local ok, failure = pcall(function()
        while true do
          local name, kind = vim.uv.fs_scandir_next(handle)
          if not name then break end
          local relative = dir .. name
          if not excluded(s.opts, relative, kind == "directory") then
            if kind == "directory" then
              table.insert(directories, relative .. "/")
            elseif kind == "file" then
              table.insert(files, relative)
            end
          end
        end
      end)
      if not ok then callback(tostring(failure)); return end
      scan()
    end))
  end
  scan()
end

local pump
pump = function()
  local s = session
  if not s or s.paused or s.busy or s.failed or #s.queue == 0 then return end
  local relative = table.remove(s.queue, 1)
  local initial = type(relative) == "table"
  local label = initial and "project sync" or relative
  s.pending[relative] = nil
  s.busy = true
  local function finished(result)
    vim.schedule(function()
      s.busy = false
      if result.code ~= 0 then
        if not s.pending[relative] then
          table.insert(s.queue, 1, relative)
          s.pending[relative] = true
        end
        s.failed = label .. ": " .. (result.stderr or "rsync failed")
        notify(s.failed .. " — fix the problem, then :UploadRetry", vim.log.levels.ERROR)
      else
        if initial or settings.options.notify_uploads then notify(label .. " uploaded") end
        if initial and s.opts.on_initial_sync then s.opts.on_initial_sync() end
        if not initial and s.opts.on_uploaded then s.opts.on_uploaded(relative) end
        pump()
        if not s.busy and not s.failed and #s.queue == 0 then release_waiters(s, true) end
      end
    end)
  end
  local function begin_transfer()
    local command = {
      s.rsync, "--relative", "--protect-args", "--times", "--perms",
      -- Each requested save must transfer, even if size and timestamp match.
      -- Coder's proxy may need time to establish a fresh workspace connection.
      initial and "--checksum" or "--ignore-times", "--timeout=120", "-e",
      "ssh -o BatchMode=yes -o ConnectTimeout=60 -o ServerAliveInterval=10 -o ServerAliveCountMax=3",
    }
    local function transfer(files)
      local options = { cwd = s.root, text = true }
      if initial then
        table.insert(command, "--from0")
        table.insert(command, "--files-from=-")
        options.stdin = #files > 0 and (table.concat(files, "\0") .. "\0") or ""
      end
      vim.list_extend(command, { "--", initial and "./" or ("./" .. relative), s.destination })
      local ok, err = pcall(vim.system, command, options, finished)
      if not ok then finished({ code = 1, stderr = tostring(err) }) end
    end
    if initial then
      project_files(s, function(err, files)
        if err then finished({ code = 1, stderr = err }) else transfer(files) end
      end)
    else
      transfer()
    end
  end
  if s.opts.before_transfer then
    s.opts.before_transfer(function(err)
      if err then finished({ code = 1, stderr = err }); return end
      begin_transfer()
    end)
  else
    begin_transfer()
  end
end

function M.start(opts)
  opts = opts or {}
  if session and (session.paused or session.busy or #session.queue > 0) then
    error("Uploads are pending; finish them or use :UploadStop before changing projects")
  end
  local root = assert(vim.uv.fs_realpath(opts.root or vim.fn.getcwd()), "Invalid local root")
  assert(root ~= "/", "Choose a project directory, not /")
  local dest = assert(opts.destination, "Set destination to an SSH alias and absolute path")
  assert(dest:match("^[%w_.%-]+:/"), "Use destination = 'ssh-alias:/absolute/project/path/'")
  local rsync = opts.rsync or settings.options.rsync
  assert(vim.fn.executable(rsync) == 1, "Install rsync first")
  session = {
    root = root, destination = dest:gsub("/*$", "/"), rsync = rsync,
    queue = {}, pending = {}, opts = opts,
  }
  local group = vim.api.nvim_create_augroup("FarworkUpload", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(event)
      if not session or vim.bo[event.buf].buftype ~= "" then return end
      local path = vim.api.nvim_buf_get_name(event.buf)
      local real = vim.uv.fs_realpath(path)
      local prefix = session.root .. "/"
      -- Reject symlinks (including symlinked parent directories) and outside files.
      if not real or real ~= path or real:sub(1, #prefix) ~= prefix then return end
      local relative = real:sub(#prefix + 1)
      if excluded(opts, relative, false) then return end
      if not session.pending[relative] then
        session.pending[relative] = true
        table.insert(session.queue, relative)
      end
      pump()
    end,
  })
  register_status()
  vim.api.nvim_create_user_command("UploadWait", function()
    vim.wait(30000, function()
      return not session or session.paused or session.failed or (not session.busy and #session.queue == 0)
    end, 50)
    notify(status())
  end, { force = true })
  vim.api.nvim_create_user_command("UploadRetry", function()
    if session then session.failed = nil; pump() end
  end, { force = true })
  vim.api.nvim_create_user_command("UploadStop", function()
    if session and session.busy then
      notify("Wait for the current transfer to finish before stopping", vim.log.levels.WARN)
      return
    end
    if session and session.paused then
      notify("Finish or cancel the recovery dialog first", vim.log.levels.WARN); return
    end
    local stopped = session
    session = nil
    if stopped then release_waiters(stopped, false) end
    vim.api.nvim_clear_autocmds({ group = group })
    notify("disabled; queued uploads discarded")
  end, { force = true })
  notify("enabled for " .. root .. " → " .. session.destination)
  if opts.initial_sync ~= false then
    table.insert(session.queue, { initial = true })
    pump()
  end
end

-- Reconnects must finish the existing queue before downloading files or
-- replacing its callbacks. Retry failures without losing any queued saves.
function M.drain(root, callback)
  if session and session.paused then return "paused" end
  if not session or (not session.busy and #session.queue == 0) then return "idle" end
  if session.root ~= root then return "different" end
  session.waiters = session.waiters or {}
  table.insert(session.waiters, callback)
  session.failed = nil
  pump()
  return "waiting"
end

function M.idle(root)
  return session and session.root == root and not session.busy
    and not session.paused and not session.failed and #session.queue == 0
end

function M.sync(root, callback)
  if not session or session.paused or session.root ~= root then callback(false); return end
  session.waiters = session.waiters or {}
  table.insert(session.waiters, callback)
  table.insert(session.queue, { initial = true })
  session.failed = nil
  pump()
end

-- Hold queue execution during recovery; saves still enter the same queue.
function M.hold(root)
  local s = session
  if not s then return function() end end
  if s.root ~= root then return nil, "Another project owns the upload queue" end
  if s.busy then return nil, "An upload is running. Wait for it to finish, then run :RemoteDoctor" end
  if s.paused then return nil, "Recovery review is already open" end
  s.paused = true
  local released = false
  return function(resume)
    if released then return end
    released = true
    if session ~= s then return end
    s.paused = nil
    if resume then s.failed = nil; pump()
    elseif #s.queue > 0 then s.failed = s.failed or "Recovery review ended; use :RemoteDoctor or :UploadRetry" end
  end
end

function M.default_exclude(path)
  -- Only the conventional top-level output directory is excluded. Nested
  -- directories called build can contain tracked source (e.g. .bst recipes).
  if path == "build" or path:match("^build/") then return true end
  for part in path:gmatch("[^/]+") do
    if part == ".git" or part == ".venv" or part == "venv"
      or part == "node_modules" or part == "__pycache__"
      or part == ".DS_Store" or part:match("^%.env") then return true end
  end
  return false
end

-- Interactive entry point. Destinations are stored locally, never in a project.
function M.setup(opts)
  opts = opts or {}
  register_status()
  local state_file = settings.state_dir() .. "/upload-projects.json"
  vim.api.nvim_create_user_command("UploadStart", function(args)
    local root = vim.uv.fs_realpath(vim.fn.getcwd())
    if not root then notify("Cannot resolve current directory", vim.log.levels.ERROR); return end
    if session and (session.paused or session.busy or #session.queue > 0) then
      notify("Uploads pending: " .. status(), vim.log.levels.WARN)
      return
    end
    local projects = {}
    if vim.fn.filereadable(state_file) == 1 then
      local ok, data = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n"))
      end)
      if not ok or type(data) ~= "table" then
        notify("Cannot read " .. state_file, vim.log.levels.ERROR)
        return
      end
      projects = data
    end
    local function enable(destination)
      if not destination or destination == "" then return end
      local ok, err = pcall(M.start, {
        root = root, destination = destination,
        rsync = settings.options.rsync,
        exclude = function(path) return M.default_exclude(path) or settings.options.upload_exclude(path) end,
      })
      if not ok then notify(tostring(err), vim.log.levels.ERROR); return end
      projects[root] = destination
      local saved, failure = pcall(function()
        vim.fn.mkdir(vim.fn.fnamemodify(state_file, ":h"), "p")
        assert(vim.fn.writefile({ vim.json.encode(projects) }, state_file) == 0)
      end)
      if not saved then notify("Could not remember destination: " .. tostring(failure), vim.log.levels.WARN) end
    end
    if args.args ~= "" then
      enable(args.args)
    elseif type(projects[root]) == "string" then
      enable(projects[root])
    else
      vim.ui.input({ prompt = "Upload " .. root .. " to (build-host:/absolute/path/): " }, enable)
    end
  end, { nargs = "?", force = true, desc = "Upload current project, then upload on save" })
  if opts.keymaps then
    vim.keymap.set("n", "<leader>us", "<cmd>UploadStart<CR>", { desc = "Start project upload" })
    vim.keymap.set("n", "<leader>ui", function() notify(status()) end, { desc = "Upload status" })
  end
end

return M
