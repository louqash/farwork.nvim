local M = {}

function M.check()
  local rsync = require("farwork.config").options.rsync
  vim.health.start("farwork.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim 0.11+")
  else
    vim.health.error("Neovim 0.11+ is required")
  end
  for _, tool in ipairs({ "ssh", "git", "python3", rsync }) do
    local path = vim.fn.exepath(tool)
    if path == "" then vim.health.error("Missing executable: " .. tool)
    else vim.health.ok(tool .. ": " .. path) end
  end
  if vim.fn.executable(rsync) == 1 then
    local result = vim.system({ rsync, "--version" }, { text = true }):wait()
    local major = tonumber((result.stdout or ""):match("version%s+(%d+)"))
    if result.code ~= 0 or not major or major < 3 then
      vim.health.error("rsync 3+ is required; macOS's bundled rsync may be too old")
    end
  end
  vim.health.info("Remote tools and authentication are checked when connecting, not by this health check")
end

return M
