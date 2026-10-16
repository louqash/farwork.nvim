local M = {}
local source = debug.getinfo(1, "S").source:sub(2)
local script = vim.fn.fnamemodify(source, ":h:h:h") .. "/scripts/remote_git.py"

function M.prepare(root, config)
  return function(done)
    if not config.git_root then done(); return end
    local mode = require("farwork.config").options.git.auto_fast_forward and "check-commit" or "check"
    local cmd = { "python3", script, mode, root, config.host, config.remote, config.environment or "" }
    return require("farwork.process").run(cmd, { text = true }, vim.schedule_wrap(function(result)
      done(result.code ~= 0 and ((result.stderr or "Git history check failed"):gsub("%s+$", "") .. "\nRun :FarworkDoctor for an explanation and guided recovery.") or nil)
    end))
  end
end

return M
