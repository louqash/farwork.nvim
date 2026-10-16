local M = {}

function M.ssh(config, script)
  local body = "set -e; "
  if config.environment and config.environment ~= "" then body = body .. config.environment .. "\n" end
  return { "ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
    config.host, "bash -lc " .. vim.fn.shellescape(body .. script) }
end

return M
