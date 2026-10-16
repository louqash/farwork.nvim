local M = {}
local running = false
local process
local source = debug.getinfo(1, "S").source:sub(2)
local script = vim.fn.fnamemodify(source, ":h:h:h") .. "/scripts/remote_check.py"
local function notify(message, level) vim.notify("Remote check: " .. message, level or vim.log.levels.INFO) end

local function matches(buf, path)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == path then return true end
  local real = vim.uv.fs_realpath(path)
  return real ~= nil and vim.uv.fs_realpath(name) == real
end

function M.start(root, config, all_files)
  if running then notify("A check is already running"); return end
  local options = require("farwork.config")
  local directory = options.cache_dir() .. "/checks/" .. vim.fn.sha256(root):sub(1, 12)
    .. "-" .. tostring(vim.uv.hrtime())
  vim.fn.mkdir(directory, "p")
  running = true
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nofile", "hide"
  vim.bo[buf].swapfile = false
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf })
  local log = "Preparing local staged snapshot…\nResults: " .. directory .. "\n"
  local completed, cancelled = false, false
  vim.api.nvim_create_user_command("FarworkCheckStop", function()
    if running and process then
      cancelled = true
      process:kill(15)
      notify("Cancelling remote check; returned fixes will not be applied")
    end
  end, { force = true, desc = "Cancel the current remote check" })
  local function render(text)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.bo[buf].modifiable = true
    -- Every API item must be a single line, including multiline error messages.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
    vim.bo[buf].modifiable = false
  end
  render(log)
  local function progress(err, data)
    vim.schedule(function()
      if completed then return end
      log = log .. (data or err or "")
      render(log)
    end)
  end
  local function finished(result)
    running, completed, process = false, true, nil
    if cancelled then render(log .. "\nCheck cancelled; no fixes applied."); return end
    if result.code ~= 0 then
      render(log .. "\nCheck failed (exit " .. result.code .. "): " .. (result.stderr or "see output above")
        .. "\nResults: " .. directory)
      notify("Check failed; see output split", vim.log.levels.ERROR)
      return
    end
    local ok, result = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(directory .. "/result.json"), "\n"))
    end)
    if not ok then notify("Cannot read check results: " .. directory, vim.log.levels.ERROR); return end
    local blocked
    for _, change in ipairs(result.changes) do
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if matches(buf, root .. "/" .. change.path)
          and vim.bo[buf].modified then blocked = "Unsaved buffer: " .. change.path end
      end
    end
    local applied = false
    if #result.changes > 0 and not blocked then
      -- Synchronous apply keeps Neovim edits from racing the modified-buffer check.
      local response = vim.system({ "python3", script, "apply", root, directory }, { text = true }):wait()
      if response.code ~= 0 then blocked = response.stderr else applied = true end
    end
    if applied then
      for _, change in ipairs(result.changes) do
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if matches(buf, root .. "/" .. change.path) and vim.api.nvim_buf_is_loaded(buf) then
            vim.api.nvim_buf_call(buf, function()
              local autoread = vim.bo[buf].autoread
              vim.bo[buf].autoread = true
              pcall(vim.cmd, "silent checktime")
              vim.bo[buf].autoread = autoread
            end)
          end
        end
      end
      local upload = require("farwork.upload")
      if upload.status().root == root then upload.sync(root, function() end) end
    end
    local lines = vim.split(result.output or "", "\n", { plain = true })
    table.insert(lines, 1, "Remote check exit code: " .. result.code)
    table.insert(lines, "Results and fixes: " .. directory)
    if blocked then
      table.insert(lines, "Fixes were NOT applied: " .. blocked)
      table.insert(lines, "Review before/ and after/ in the result directory; your local edits are preserved.")
    elseif applied then
      table.insert(lines, "Formatter fixes applied locally. Review, git add, and run :FarworkCheck again.")
    end
    render(table.concat(lines, "\n"))
    notify(blocked and "Fixes need review; see check output" or applied and "Fixes applied; review and stage them"
      or result.code == 0 and "Checks passed" or "Checks failed; see output",
      (blocked or result.code ~= 0) and vim.log.levels.WARN or vim.log.levels.INFO)
  end
  local ok, err = pcall(require("farwork.process").run, { "python3", script, "run", root, config.host,
    config.environment or "", directory, tostring(all_files == true), vim.json.encode(options.options.check_command), options.options.check_args },
    { text = true, stderr = progress }, vim.schedule_wrap(finished), options.options.check_timeout)
  if not ok then running, completed = false, true; render(log .. "\n" .. tostring(err)); notify(tostring(err), vim.log.levels.ERROR)
  else process = err end
end
return M
