local M = {}
local busy = false
local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h") .. "/scripts/remote_recovery.py"

function M.start(root, config)
  if busy then vim.notify("Recovery review is already running"); return end
  local upload = require("farwork.upload")
  local release, reason = upload.hold(root)
  if not release then vim.notify(reason, vim.log.levels.WARN); return end
  busy = true
  local options = require("farwork.config")
  local directory = options.cache_dir() .. "/recovery/" .. tostring(vim.uv.hrtime())
  vim.fn.mkdir(directory, "p")
  local plan_file = directory .. "/plan.json"
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nofile", "hide"
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf })
  local function render(lines)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(table.concat(lines, "\n"), "\n", { plain = true }))
    vim.bo[buf].modifiable = false
  end
  local function finish(resume) busy = false; release(resume) end
  local function run(mode, callback)
    local ok, err = pcall(require("farwork.process").run, { "python3", script, mode, root, config.host, config.remote, plan_file, config.environment or "" },
      { text = true }, vim.schedule_wrap(function(result)
        if result.code ~= 0 then
          render({ "Recovery stopped; uploads remain paused.", result.stderr or "Unknown error",
            "Review git status locally/remotely as indicated above, then run :RemoteDoctor again.", "Plan: " .. plan_file })
          finish(false); return
        end
        local parsed, data = pcall(vim.json.decode, result.stdout or "")
        if not parsed then render({ "Cannot read recovery response", result.stdout or "" }); finish(false); return end
        callback(data)
      end))
    if not ok then render({ tostring(err) }); finish(false) end
  end
  render({ "Inspecting local and remote Git state…", "Uploads are held while you review.", "No repair runs without confirmation." })
  run("diagnose", function(report)
    -- Honor user upload exclusions as well as the helper's protected paths.
    for _, item in ipairs(report.paths) do
      local path = config.remote .. "/" .. item.path
      if options.options.upload_exclude(item.path)
        or (config.build and config.build ~= config.remote and (path == config.build or path:sub(1, #config.build + 1) == config.build .. "/")) then
        report.allowed = false
        table.insert(report.reasons, "Excluded/build path requires manual review: " .. item.path)
      end
    end
    local lines = {
      "Local:  " .. report.target.head:sub(1, 12) .. " (" .. report.target.branch .. ")",
      "Remote: " .. report.current.head:sub(1, 12) .. " (" .. report.current.branch .. ")",
      "Destination: " .. config.host .. ":" .. config.remote,
      "", report.aligned and "Git histories match." or "Remote history differs from your local checkout.",
    }
    for _, item in ipairs(report.paths) do
      local label = ({ pending_upload = "COPY local committed version", already_uploaded = "KEEP already matching file", blocked = "REVIEW" })[item.state]
      table.insert(lines, label .. ": " .. item.path)
    end
    if not report.allowed then
      table.insert(lines, "\nAutomatic recovery is blocked:")
      vim.list_extend(lines, report.reasons)
      table.insert(lines, "\nReview remote edits with :RemoteDiff or git diff in the remote terminal.")
      table.insert(lines, "Preserve/merge wanted changes locally; do not stash or clean the remote venv.")
      table.insert(lines, "Once resolved, run :RemoteDoctor again. Saved plan: " .. plan_file)
      render(lines); finish(false); return
    end
    local needs_repair = not report.aligned or #report.paths > 0
    if needs_repair then
      table.insert(lines, "\nRepair uses the LOCAL COMMIT as the source of truth, including after a rebase.")
      table.insert(lines, "The old remote commit and target will be retained in recovery backup refs.")
      table.insert(lines, "Only listed verified tracked files and remote Git metadata change. Venv/build/untracked files are preserved.")
    else table.insert(lines, "The old upload error can be cleared by retrying the queue.") end
    table.insert(lines, "\nSaved plan: " .. plan_file)
    render(lines)
    local action = needs_repair and "Repair remote from local commit, then resume uploads" or "Resume uploads"
    vim.ui.select({ "Cancel; keep uploads paused", action }, { prompt = "Review the recovery plan in the split:" }, function(choice)
      if choice ~= action then finish(false); return end
      if not needs_repair then
        table.insert(lines, "\nUploads resumed. If uploading was stopped, run :RemoteStart.")
        render(lines); finish(true); return
      end
      table.insert(lines, "\nRechecking and applying the reviewed plan…")
      render(lines)
      run("apply", function(result)
        table.insert(lines, "\nRecovery complete. Backup: " .. result.backup)
        table.insert(lines, "Uploads resumed. If uploading was stopped, run :RemoteStart.")
        render(lines); finish(true)
      end)
    end)
  end)
end
return M
