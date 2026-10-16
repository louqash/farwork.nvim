-- Local editing with SSH-hosted clangd and CMake. One active project per
-- Neovim instance; project settings are remembered outside the repository.
local M = {}
local plugin_config = require("farwork.config")
local active, connecting
local retiring_clients = {}
local q = vim.fn.shellescape
local types = require("farwork.clangd").filetypes
local function tell(message, level)
  vim.notify("Remote: " .. message, level or vim.log.levels.INFO)
end
local function inside(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end
local ssh = require("farwork.transport").ssh
local function config_file()
  return plugin_config.state_dir() .. "/remote-projects.json"
end
local function read_settings()
  if vim.fn.filereadable(config_file()) == 0 then return {} end
  local data = vim.json.decode(table.concat(vim.fn.readfile(config_file()), "\n"))
  assert(type(data) == "table", "Invalid remote-projects.json")
  return data
end
local function remember(root, config)
  -- Project files are authoritative; don't recreate removed per-project state.
  if require("farwork.projects").file_root(root) == root then return end
  local settings = read_settings()
  settings[root] = config
  vim.fn.mkdir(plugin_config.state_dir(), "p")
  assert(vim.fn.writefile({ vim.json.encode(settings) }, config_file()) == 0)
end

-- This runs on the host, so no Mac dependency paths are used for discovery.
local probe = [=[
import json, os, shutil, subprocess, sys
root = os.path.realpath(sys.argv[1])
if not os.path.isdir(root): raise SystemExit("Remote project directory does not exist")
use_clangd = sys.argv[3] != "none"
clangd = shutil.which("clangd") if use_clangd else None
if use_clangd and not clangd: raise SystemExit("clangd is missing from the remote environment PATH")
builds = set()
for directory, dirs, files in (os.walk(root) if use_clangd else []):
    dirs[:] = [d for d in dirs if d not in ('.git', '.venv', 'venv', 'node_modules')]
    if os.path.relpath(directory, root).count(os.sep) >= 6: dirs[:] = []
    if 'compile_commands.json' in files:
        builds.add(os.path.dirname(os.path.realpath(os.path.join(directory, 'compile_commands.json'))))
if use_clangd and len(sys.argv) > 2 and sys.argv[2] and os.path.isfile(os.path.join(sys.argv[2], 'compile_commands.json')):
    builds.add(sys.argv[2])
roots = sorted('/' + name for name in os.listdir('/') if os.path.isdir('/' + name))
git_root = None
if shutil.which('git'):
    result = subprocess.run(['git', '-C', root, 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    if result.returncode == 0: git_root = os.path.realpath(result.stdout.strip())
print(json.dumps(dict(remote=root, clangd=clangd, builds=sorted(builds), roots=roots, git_root=git_root)))
]=]

function M.owns_buffer(buf)
  if not active then return false end
  local name = vim.api.nvim_buf_get_name(buf)
  return inside(name, active.root) or inside(name, active.cache)
end

function M.owns_lsp_buffer(buf)
  return active ~= nil and active.lsp ~= nil and M.owns_buffer(buf)
end

function M.is_project()
  return active ~= nil and inside(vim.fn.getcwd(), active.root)
end

local reminded = {}
function M.local_clangd_root(buf, on_dir)
  if active and active.lsp and M.owns_buffer(buf) then return end
  local path = vim.api.nvim_buf_get_name(buf)
  local ok, settings = pcall(read_settings)
  if not ok then
    tell("Cannot read remote project settings; refusing local clangd fallback", vim.log.levels.ERROR)
    return
  end
  local file_root = require("farwork.projects").file_root(path)
  if file_root then
    -- Inspect only the declarative LSP switch here; connecting still requires trust.
    local trusted, project = pcall(function()
      local value = vim.json.decode(table.concat(vim.fn.readfile(file_root .. "/.farwork.json"), "\n"))
      return vim.tbl_extend("force", value, plugin_config.options.projects[file_root] or {})
    end)
    if not trusted or project.lsp ~= false then return end
  end
  for root, project in pairs(vim.tbl_extend("force", settings, plugin_config.options.projects)) do
    if root ~= file_root and project.lsp ~= false and inside(path, root) then
      if not reminded[root] then
        reminded[root] = true
        tell("This project uses remote clangd. Run :RemoteStart to connect.")
      end
      return
    end
  end
  on_dir(vim.fs.root(buf, { ".clangd", ".clang-tidy", ".clang-format", "compile_commands.json",
    "compile_flags.txt", "configure.ac", ".git" }) or vim.fs.dirname(path))
end

local function attach(buf)
  if not active or not active.lsp or not active.ready or not vim.api.nvim_buf_is_loaded(buf)
    or not types[vim.bo[buf].filetype] or not M.owns_buffer(buf) then return end
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf, name = "clangd" })) do
    vim.lsp.buf_detach_client(buf, client.id)
  end
  local id = vim.lsp.start(active.lsp, {
    bufnr = buf,
    reuse_client = function(client, config)
      return not retiring_clients[client.id] and client.name == config.name
        and client.config.root_dir == config.root_dir
    end,
  })
  if id then active.client = id else tell("Could not start remote clangd", vim.log.levels.ERROR) end
end

-- BufReadCmd runs synchronously so definition jumps see the right line count.
-- Only remote-only file opens wait for SSH; ordinary local editing stays local.
local function fetch(buf, remote, required)
  local s = active
  local result = vim.system(ssh(s.config, "cat -- " .. q(remote)), { text = true, timeout = 15000 }):wait()
  if result.code ~= 0 then
    if required then error("Cannot read remote header: " .. (result.stderr or remote)) end
    return false
  end
  local lines = vim.split(result.stdout or "", "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modifiable = false
  vim.b[buf].remote_header = true
  local ft = vim.filetype.match({ filename = remote, buf = buf })
  if ft then vim.bo[buf].filetype = ft end
  return true
end

local function activate(root, config)
  local upload = require("farwork.upload")
  local cache = plugin_config.cache_dir() .. "/remote-headers/" .. vim.fn.sha256(root .. config.host):sub(1, 16)
  local s = { root = root, config = config, cache = cache }
  s.lsp = config.lsp ~= false and require("farwork.clangd").config(root, config, cache) or nil
  -- Reserve the upload session before replacing an existing remote LSP session.
  upload.start({ root = root, destination = config.host .. ":" .. config.remote .. "/",
    before_transfer = require("farwork.git").prepare(root, config),
    rsync = plugin_config.options.rsync,
    exclude = function(path)
      local remote_path = config.remote .. "/" .. path:gsub("/$", "")
      return upload.default_exclude(path) or plugin_config.options.upload_exclude(path) or path == "compile_commands.json"
        or (config.build ~= config.remote and inside(remote_path, config.build))
    end,
    on_initial_sync = function()
      if active ~= s then return end
      if s.ready then
        local client = s.client and vim.lsp.get_client_by_id(s.client)
        if client and client.initialized then
          local changes = {}
          for buf in pairs(client.attached_buffers) do
            table.insert(changes, { uri = vim.uri_from_bufnr(buf), type = 2 })
          end
          client:notify("workspace/didChangeWatchedFiles", { changes = changes })
        end
        return
      end
      s.ready = true
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do attach(buf) end
      tell("Ready: " .. config.host .. " · " .. config.build)
    end,
    on_uploaded = function(relative)
      if active ~= s or not s.client then return end
      local client = vim.lsp.get_client_by_id(s.client)
      if not client or not client.initialized then return end
      -- The editor's original didSave can arrive before rsync updates remote
      -- disk. Signal the completed write so dependent files can be reparsed.
      local uri = vim.uri_from_fname(root .. "/" .. relative)
      client:notify("workspace/didChangeWatchedFiles", { changes = { { uri = uri, type = 2 } } })
      for buf in pairs(client.attached_buffers) do
        if vim.api.nvim_buf_get_name(buf) == root .. "/" .. relative then
          client:notify("textDocument/didSave", { textDocument = { uri = uri } })
        end
      end
    end,
  })
  if active and active.client then
    local previous = vim.lsp.get_client_by_id(active.client)
    if previous then
      retiring_clients[previous.id] = true
      previous:stop()
    end
  end
  active = s
  local group = vim.api.nvim_create_augroup("FarworkRemoteProject", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
    group = group, callback = function(event) attach(event.buf) end,
  })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(event)
      local client = vim.lsp.get_client_by_id(event.data.client_id)
      if s.lsp and client and client.name == "clangd" and M.owns_buffer(event.buf) then
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(event.buf) then vim.lsp.buf_detach_client(event.buf, client.id) end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group, pattern = vim.fn.fnameescape(cache) .. "/*",
    callback = function(event)
      local path = vim.api.nvim_buf_get_name(event.buf)
      assert(inside(path, cache), "Header path outside cache")
      fetch(event.buf, path:sub(#cache + 1), true)
    end,
  })
  vim.api.nvim_create_autocmd("BufNewFile", {
    group = group,
    callback = function(event)
      local path = vim.api.nvim_buf_get_name(event.buf)
      if inside(path, root) then fetch(event.buf, config.remote .. path:sub(#root + 1), false) end
    end,
  })
  remember(root, config)
end

local function ensure_local_git(root, config, callback)
  if vim.uv.fs_lstat(root .. "/.git") then callback(); return end
  if not config.git_root then
    tell("Remote directory is not a Git checkout; local Git is unavailable", vim.log.levels.WARN)
    callback(); return
  end
  if config.git_root ~= config.remote then
    callback("For local Git support, open the repository root locally and use remote path " .. config.git_root)
    return
  end
  -- Clone via Git's protocol, not rsync. Build the index in a disposable clone,
  -- then move only its metadata into place without checking out any files.
  local staging = root .. "/.remote-git-init-" .. vim.fn.fnamemodify(vim.fn.tempname(), ":t")
  if vim.uv.fs_lstat(staging) then callback("Temporary Git directory already exists: " .. staging); return end
  tell("Initializing local Git history; existing source files will be preserved…")
  vim.system({ "git", "clone", "--no-checkout", "--no-local", "--origin", "workspace",
    "--", config.host .. ":" .. config.remote, staging },
    { text = true, timeout = plugin_config.options.operation_timeout * 1000, env = { GIT_TERMINAL_PROMPT = "0", GIT_SSH_COMMAND = "ssh -o BatchMode=yes -o ConnectTimeout=10" } },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        vim.fn.delete(staging, "rf")
        callback(result.stderr or "Git clone failed"); return
      end
      vim.system({ "git", "-C", staging, "read-tree", "HEAD" }, { text = true }, vim.schedule_wrap(function(index)
        if index.code ~= 0 then
          vim.fn.delete(staging, "rf")
          callback(index.stderr or "Cannot initialize Git index"); return
        end
        if vim.uv.fs_lstat(root .. "/.git") then
          vim.fn.delete(staging, "rf")
          callback("Local .git appeared during setup; restart to preserve it"); return
        end
        local marked, result = pcall(vim.fn.writefile,
          { vim.json.encode({ host = config.host, remote = config.remote }) }, staging .. "/.git/farwork-bootstrap.json")
        if not marked or result ~= 0 then
          vim.fn.delete(staging, "rf")
          callback("Cannot record initial download state"); return
        end
        local moved, err = vim.uv.fs_rename(staging .. "/.git", root .. "/.git")
        vim.fn.delete(staging, "rf")
        if not moved then callback(err or "Cannot install local Git metadata"); return end
        callback()
      end))
    end))
end

local function populate(root, config, callback)
  -- Fetch missing source files before uploads; existing local edits win.
  local cmd = { plugin_config.options.rsync, "--recursive", "--times", "--perms",
    "--protect-args", "--ignore-existing", "--timeout=30", "-e",
    "ssh -o BatchMode=yes -o ConnectTimeout=10" }
  for _, pattern in ipairs({ ".git", ".env*", ".venv", "venv", "node_modules",
    "/build/", "__pycache__", ".DS_Store", "compile_commands.json" }) do
    table.insert(cmd, "--exclude=" .. pattern)
  end
  if config.build ~= config.remote and inside(config.build, config.remote) then
    local relative = config.build:sub(#config.remote + 2)
    relative = relative:gsub("([\\*?%[])", "\\%1")
    table.insert(cmd, "--exclude=/" .. relative .. "/")
  end
  vim.list_extend(cmd, { "--", config.host .. ":" .. config.remote .. "/", root .. "/" })
  tell("Downloading missing project files before starting uploads…")
  vim.system(cmd, { text = true, timeout = plugin_config.options.operation_timeout * 1000 }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then callback(result.stderr or "Initial download failed")
    else callback() end
  end))
end

function M.project_root(path)
  path = require("farwork.projects").directory(path or vim.fn.getcwd())
  if not path then return nil end
  local ok, saved = pcall(read_settings)
  if not ok then saved = {} end
  local best
  for _, projects in ipairs({ saved, plugin_config.options.projects }) do
    for root in pairs(projects) do
      if inside(path, root) and (not best or #root > #best) then best = root end
    end
  end
  local file_root = require("farwork.projects").file_root(path)
  if file_root and (not best or #file_root >= #best) then best = file_root end
  return best or vim.fs.root(path, ".git") or path
end

function M.configured_root(path)
  local root = M.project_root(path)
  if not root then return nil end
  if vim.uv.fs_stat(root .. "/.farwork.json") or plugin_config.options.projects[root] then return root end
  local ok, saved = pcall(read_settings)
  if ok and saved[root] then return root end
end

function M.status()
  local client = active and active.client and vim.lsp.get_client_by_id(active.client)
  return {
    connecting = connecting == true,
    ready = active ~= nil and active.ready == true,
    root = active and active.root or nil,
    host = active and active.config.host or nil,
    remote = active and active.config.remote or nil,
    build = active and active.config.build or nil,
    lsp_connected = client ~= nil and client.initialized and not client:is_stopped() or false,
    upload = require("farwork.upload").status(),
  }
end

function M.start(options)
  if type(options) == "boolean" then options = { reset = options } end
  options = options or {}
  local reset = options.reset
  if connecting then tell("Connection setup already in progress"); return end
  local root = M.project_root(options.root or vim.fn.getcwd())
  if not root then tell("Local project directory does not exist", vim.log.levels.ERROR); return end
  local draining = require("farwork.upload").drain(root, function(completed)
    connecting = false
    if completed then M.start(options)
    else tell("Reconnect cancelled because the upload queue was stopped. Run :RemoteStart again when ready.") end
  end)
  if draining == "waiting" then
    connecting = true
    tell("Finishing pending uploads before reconnecting. Failed uploads are being retried; use :UploadStatus for details.")
    return
  elseif draining == "paused" then
    tell("Finish or cancel the recovery dialog before reconnecting"); return
  elseif draining == "different" then
    tell("Another project's uploads are pending. Use :UploadRetry and :UploadWait there, or :UploadStop to discard its queue.", vim.log.levels.WARN)
    return
  end
  local ok, settings = pcall(read_settings)
  if not ok then tell(tostring(settings), vim.log.levels.ERROR); return end
  local saved = vim.tbl_extend("force", settings[root] or {}, plugin_config.options.projects[root] or {})
  local trusted, project = pcall(require("farwork.projects").read, root)
  if not trusted then tell(tostring(project), vim.log.levels.ERROR); return end
  -- A file is a complete profile: never inherit stale environment/build fields.
  if project then saved = vim.tbl_extend("force", project, plugin_config.options.projects[root] or {}) end
  if options.build then saved.build = options.build end
  if options.environment ~= nil then saved.environment = options.environment end
  local function discover(destination, environment)
    local host, remote = destination:match("^([%w_.%-]+):(/.+)$")
    if not host then connecting = false; tell("Use build-host:/absolute/project/path", vim.log.levels.ERROR); return end
    connecting = true
    local config = { host = host, remote = remote:gsub("/+$", ""), environment = environment, lsp = saved.lsp }
    tell(config.lsp == false and "Connecting to remote workspace…" or "Discovering remote clangd and compilation databases…")
    vim.system(ssh(config, "python3 -c " .. q(probe) .. " " .. q(config.remote) .. " " .. q(saved.build or "") .. " " .. q(config.lsp == false and "none" or "clangd")),
      { text = true, timeout = 30000 }, vim.schedule_wrap(function(result)
        if result.code ~= 0 then connecting = false; tell(result.stderr or "Discovery failed", vim.log.levels.ERROR); return end
        local parsed, data = pcall(vim.json.decode, result.stdout or "")
        if not parsed or type(data) ~= "table" or not data.remote or (config.lsp ~= false and not data.clangd) or not data.builds or not data.roots then
          connecting = false; tell("Invalid discovery output; shell startup must not print to stdout", vim.log.levels.ERROR); return
        end
        config.remote, config.clangd, config.roots = data.remote, data.clangd, data.roots
        config.git_root = type(data.git_root) == "string" and data.git_root or nil
        local function connect()
          local had_git = vim.uv.fs_lstat(root .. "/.git") ~= nil
          local marker = root .. "/.git/farwork-bootstrap.json"
          local pending = vim.fn.filereadable(marker) == 1
          if pending then
            local valid, previous = pcall(vim.json.decode, table.concat(vim.fn.readfile(marker), "\n"))
            if not valid or type(previous) ~= "table" or previous.host ~= config.host or previous.remote ~= config.remote then
              connecting = false
              tell("Incomplete setup belongs to a different remote. Finish that setup first.", vim.log.levels.ERROR)
              return
            end
          end
          ensure_local_git(root, config, function(git_error)
            if git_error then connecting = false; tell(git_error, vim.log.levels.ERROR); return end
            local function prepared(download_error)
              connecting = false
              if download_error then tell(download_error, vim.log.levels.ERROR); return end
              if vim.fn.filereadable(marker) == 1 then vim.fn.delete(marker) end
              local success, err = pcall(activate, root, config)
              if not success then tell(tostring(err), vim.log.levels.ERROR) end
            end
            -- Existing checkouts own their deletions. Downloading missing
            -- files from an old remote HEAD would undo a local rebase.
            if had_git and not pending then prepared() else populate(root, config, prepared) end
          end)
        end
        local function choose(build)
          if not build or build == "" then connecting = false; return end
          if build:sub(1, 1) ~= "/" then connecting = false; tell("Use an absolute remote build directory", vim.log.levels.ERROR); return end
          config.build = build
          connecting = true
          vim.system(ssh(config, "test -r " .. q(build .. "/compile_commands.json")),
            { text = true, timeout = 15000 }, vim.schedule_wrap(function(check)
              if check.code ~= 0 then
                connecting = false
                tell("Cannot read " .. build .. "/compile_commands.json; configure CMake with CMAKE_EXPORT_COMPILE_COMMANDS=ON", vim.log.levels.ERROR)
                return
              end
              connect()
            end))
        end
        if config.lsp == false then
          config.build = saved.build or config.remote
          connect()
          return
        end
        if not reset and saved.build and vim.tbl_contains(data.builds, saved.build) then choose(saved.build)
        elseif #data.builds == 1 then choose(data.builds[1])
        elseif #data.builds > 1 then vim.ui.select(data.builds, { prompt = "Remote compilation database:" }, choose)
        else
          vim.ui.input({ prompt = "Remote directory containing compile_commands.json (configure CMake first): ",
            default = saved.build or "" }, choose)
        end
      end))
  end
  if options.destination then discover(options.destination, saved.environment or ""); return end
  if saved.host and not reset then
    discover(saved.host .. ":" .. saved.remote, saved.environment)
    return
  end
  connecting = true
  vim.ui.input({ prompt = "SSH destination (host:/absolute/project/path): ",
    default = saved.host and (saved.host .. ":" .. saved.remote) or "" }, function(destination)
    if not destination or destination == "" then connecting = false; return end
    vim.ui.input({ prompt = "Remote environment command (optional, e.g. source /opt/toolchain/env.sh): ",
      default = saved.environment or "" }, function(environment)
      if environment ~= nil then discover(destination, environment) else connecting = false end
    end)
  end)
end

function M.setup(opts)
  opts = opts or {}
  require("farwork.sync").setup()
  vim.api.nvim_create_user_command("RemoteRefresh", function()
    if not active or not active.ready then tell("Run :RemoteStart first"); return end
    if not active.lsp then tell("No remote language server configured"); return end
    if not require("farwork.upload").idle(active.root) then tell("Wait for uploads; use :UploadStatus"); return end
    local client = active.client and vim.lsp.get_client_by_id(active.client)
    if client then
      retiring_clients[client.id] = true
      client:stop(false)
      -- A dead connection may never acknowledge shutdown. Allow it time to
      -- close cleanly before falling back to termination.
      vim.defer_fn(function()
        if not client:is_stopped() then client:stop(true) end
      end, 5000)
    end
    active.client = nil
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do attach(buf) end
    tell("Restarted remote clangd to refresh diagnostics")
  end, { force = true, desc = "Restart remote clangd without resyncing the project" })
  vim.api.nvim_create_user_command("RemoteStatus", function()
    local clients = {}
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
      table.insert(clients, client.name .. (client.initialized and " (initialized)" or " (starting)"))
    end
    local message = active and (active.config.host .. ":" .. active.config.remote
      .. "\nBuild: " .. active.config.build .. "\n" .. (active.ready and "Initial sync complete" or "Waiting for initial sync"))
      or "Not connected. Run :RemoteStart from the local project root."
    tell(message .. "\nCurrent buffer LSP: " .. (#clients > 0 and table.concat(clients, ", ") or "none")
      .. "\nUploads: " .. require("farwork.upload").status().message)
  end, { force = true, desc = "Show remote context and language servers for the current buffer" })
  vim.api.nvim_create_user_command("RemoteStart", function(args)
    M.start({ reset = args.bang, destination = args.args ~= "" and args.args or nil })
  end, { nargs = "?", bang = true, force = true, desc = "Connect using saved settings or host:/path; ! reconfigures" })
  vim.api.nvim_create_user_command("RemoteProjects", function()
    local ok, saved = pcall(read_settings)
    if not ok then tell(tostring(saved), vim.log.levels.ERROR); return end
    local profiles = vim.tbl_extend("force", saved, plugin_config.options.projects)
    local roots = vim.tbl_keys(profiles)
    table.sort(roots)
    if #roots == 0 then tell("No saved projects. Run :RemoteStart from a local project first."); return end
    vim.ui.select(roots, { prompt = "Connect to project:", format_item = function(root)
      return root .. " → " .. profiles[root].host .. ":" .. profiles[root].remote
    end }, function(root) if root then M.start({ root = root }) end end)
  end, { force = true, desc = "Choose a saved or configured remote project" })
  vim.api.nvim_create_user_command("RemoteSync", function()
    if not active then tell("Run :RemoteStart first"); return end
    require("farwork.upload").sync(active.root, function(completed)
      if completed then tell("Saved project files synchronized") end
    end)
  end, { force = true, desc = "Sync saved files and retry queued uploads without restarting clangd" })
  vim.api.nvim_create_user_command("RemoteDoctor", function()
    if active then require("farwork.recovery").start(active.root, vim.deepcopy(active.config)); return end
    local root = M.project_root()
    if not root then tell("Open a local project first"); return end
    local ok, config = pcall(function()
      local file = require("farwork.projects").read(root)
      return vim.tbl_extend("force", file or read_settings()[root] or {}, plugin_config.options.projects[root] or {})
    end)
    if not ok then tell(tostring(config), vim.log.levels.ERROR); return end
    if not config.host or not config.remote then tell("Configure this project with :RemoteStart first"); return end
    require("farwork.recovery").start(root, config)
  end, { force = true, desc = "Explain sync problems and review a safe recovery plan" })
  vim.api.nvim_create_user_command("RemoteCheck", function(args)
    if not active or not active.ready then tell("Run :RemoteStart first"); return end
    require("farwork.check").start(active.root, vim.deepcopy(active.config), args.bang)
  end, { bang = true, force = true, desc = "Check staged snapshot remotely and return fixes; ! checks all index files" })
  vim.api.nvim_create_user_command("RemoteBuild", function(args)
    if not active or not active.ready then tell("Run :RemoteStart first"); return end
    if not require("farwork.upload").idle(active.root) then tell("Wait for uploads; use :UploadStatus"); return end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if M.owns_buffer(buf) and vim.bo[buf].modified then tell("Save project buffers before building"); return end
    end
    local s = active
    local ok, command = pcall(plugin_config.options.build_command, vim.deepcopy(s.config))
    if not ok or type(command) ~= "table" or not vim.islist(command) or #command == 0 then
      tell("build_command must return a nonempty argument list", vim.log.levels.ERROR); return
    end
    command = vim.deepcopy(command)
    vim.list_extend(command, args.fargs)
    for i, arg in ipairs(command) do
      if type(arg) ~= "string" then tell("Build arguments must be strings", vim.log.levels.ERROR); return end
      command[i] = q(arg)
    end
    require("farwork.upload").sync(s.root, function(completed)
      if not completed or active ~= s then return end
      vim.cmd("botright split | enew")
      vim.fn.jobstart(ssh(s.config, "cd -- " .. q(s.config.remote)
        .. "; " .. table.concat(command, " ")), { term = true })
    end)
  end, { nargs = "*", force = true, desc = "Sync and build remotely; optional arguments are appended" })
  vim.api.nvim_create_user_command("RemoteDiff", function(args)
    if not active or not active.ready then tell("Run :RemoteStart first"); return end
    if not require("farwork.upload").idle(active.root) then tell("Wait for uploads; use :UploadStatus"); return end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if M.owns_buffer(buf) and vim.bo[buf].modified then tell("Save project buffers before viewing the remote diff"); return end
    end
    local s = active
    local command = "cd -- " .. q(s.config.remote)
      .. "; git --no-pager diff --no-ext-diff --no-textconv --color=never"
      .. (args.bang and " --cached" or "") .. " -- ."
    tell("Reading " .. (args.bang and "staged" or "unstaged") .. " remote Git diff…")
    vim.system(ssh(s.config, command), { text = true, timeout = 30000 }, vim.schedule_wrap(function(result)
      if active ~= s then return end
      if result.code ~= 0 then tell(result.stderr or "Git diff failed", vim.log.levels.ERROR); return end
      if not result.stdout or result.stdout == "" then
        tell("No " .. (args.bang and "staged" or "unstaged") .. " tracked changes (untracked files are not included)")
        return
      end
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result.stdout, "\n", { plain = true }))
      vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nofile", "wipe"
      vim.bo[buf].filetype = "diff"
      vim.bo[buf].modifiable, vim.bo[buf].readonly = false, true
      vim.b[buf].remote_git_diff = true
      vim.cmd("botright split")
      vim.api.nvim_win_set_buf(0, buf)
      vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, desc = "Close remote diff" })
    end))
  end, { bang = true, force = true, desc = "View remote Git diff; ! shows staged changes" })
  if opts.keymaps then
    vim.keymap.set("n", "<leader>rs", "<cmd>RemoteStart<CR>", { desc = "Start remote C++ project" })
    vim.keymap.set("n", "<leader>rb", "<cmd>RemoteBuild<CR>", { desc = "Build remote project" })
    vim.keymap.set("n", "<leader>rd", "<cmd>RemoteDiff<CR>", { desc = "View remote Git diff" })
  end
end

return M
